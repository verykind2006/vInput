import Foundation
import IOKit.hid

/// 与 `BLEScanner` 配套的 HID 侧诊断。
///
/// # 为什么 GATT 扫描不够
///
/// macOS **不把 HID over GATT（服务 0x1812）交给 CoreBluetooth**，系统会把
/// 它从 `peripheral.services` 里滤掉。而这支鼠标在 HID 侧暴露了六个
/// collection，其中包括 `{Page=0xFF00,Usage=0}` 厂商自定义页——音频完全
/// 可能就搭着 HID 报文走，那样 GATT 那边会一无所获。
///
/// 真机扫描每跑一轮都要用户坐在电脑前按键，**一轮就是一次往返**。两条路
/// 一起看的成本是这个文件，白按一轮的成本是一天。
///
/// # 它输出什么
///
/// 1. 一份 HID 设备清单（名字 / vendorID / productID / 传输方式）——
///    用户报的名字与 IOKit 看到的未必一致，扫不到时这是唯一线索；
/// 2. 目标设备的**报文描述符**十六进制。这份东西直接写明了 0xFF00 那个
///    collection 有几个 report、每个多长——比任何猜测都准；
/// 3. 按键期间的输入报文，按 report ID 分组、限流（策略与 GATT 通知共用
///    `BLEScanNotificationLog`），原始字节进 `BLEScanFileLog`。
///
/// # 权限
///
/// 需要「输入监控」。**未授予时只记一行日志然后放弃**，不影响听写主路径
/// ——与 `RemoteHIDListener` 同一条约定。
///
/// # 隐私
///
/// manager 的匹配集合是「全部设备」（因为我们不知道鼠标的 vendorID /
/// productID），但**输入报文回调只注册在名字匹配的那台设备上**。别的键盘
/// 鼠标的按键既不会进回调，也不会进日志。
@MainActor
final class HIDReportProbe {
    /// 输入报文缓冲区大小。HID 报文远小于这个数，给足余量即可。
    private static let bufferSize = 1024

    /// 报文描述符的属性键。用字面量而不是 `kIOHIDReportDescriptorKey`：
    /// 该常量在 Swift 的 IOKit overlay 里不总是可见。
    private static let reportDescriptorKey = "ReportDescriptor"

    private let targetName: String
    private let fileLog: BLEScanFileLog?

    private var manager: IOHIDManager?
    private var attachedDevices: [IOHIDDevice] = []
    private var buffers: [UnsafeMutablePointer<UInt8>] = []
    private var reports = BLEScanNotificationLog(
        tag: "HIDPROBE report",
        emptyMessage: "BLESCAN HIDPROBE 一个 HID 报文都没收到"
    )
    private var running = false

    init(targetName: String = BLEScanGate.targetName, fileLog: BLEScanFileLog? = nil) {
        self.targetName = targetName
        self.fileLog = fileLog
    }

    var isRunning: Bool { running }

    func start() {
        guard !running else { return }
        guard RemoteHIDListener.hasInputMonitoringAccess() else {
            log("未授予输入监控权限，HID 侧诊断跳过 —— "
                + "系统设置 → 隐私与安全性 → 输入监控 里加上 vInput，"
                + "**必须完全退出应用再打开**才生效")
            RemoteHIDListener.requestInputMonitoringAccess()
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // nil = 匹配全部设备。我们不知道鼠标的 vendorID/productID，
        // 只能先枚举再按名字挑；输入报文回调只挂在挑中的那台上。
        IOHIDManagerSetDeviceMatching(manager, nil)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            log("HID manager 打开失败 result=\(result)")
            return
        }
        self.manager = manager
        running = true

        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        log("HIDPROBE 设备 \(devices.count) 台，逐台列出（只对名字匹配的那台挂报文回调）")

        var matched = 0
        for device in devices.sorted(by: { Self.name(of: $0) ?? "" < Self.name(of: $1) ?? "" }) {
            let product = Self.name(of: device)
            log("HIDPROBE DEV name=\(product ?? "（无名）")"
                + " vendor=\(Self.hexID(device, kIOHIDVendorIDKey))"
                + " product=\(Self.hexID(device, kIOHIDProductIDKey))"
                + " transport=\(Self.string(device, kIOHIDTransportKey) ?? "?")"
                + " usagePage=\(Self.int(device, kIOHIDPrimaryUsagePageKey).map(String.init) ?? "?")"
                + " usage=\(Self.int(device, kIOHIDPrimaryUsageKey).map(String.init) ?? "?")")
            guard BLEScanTargetMatcher.isTarget(name: product, target: targetName) else { continue }
            attach(device, product: product ?? targetName)
            matched += 1
        }

        if matched == 0 {
            log("HIDPROBE 没有名字匹配「\(targetName)」的 HID 设备 —— "
                + "对着上面那份清单看看它在 IOKit 里叫什么，"
                + "再用 VINPUT_BLE_SCAN_NAME 指定")
        }
    }

    func stop() {
        guard running else { return }
        running = false
        for line in reports.flush(at: Date()) {
            AppLogger.shared.log(line)
            fileLog?.write(line)
        }
        for device in attachedDevices {
            IOHIDDeviceUnscheduleFromRunLoop(
                device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue
            )
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        attachedDevices = []
        for buffer in buffers { buffer.deallocate() }
        buffers = []
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        log("HIDPROBE 已停止")
    }

    // MARK: - 私有

    private func attach(_ device: IOHIDDevice, product: String) {
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            log("HIDPROBE 打开设备失败 name=\(product)")
            return
        }

        // 报文描述符是这份诊断里信息量最大的一条：厂商自定义页
        // （0xFF00）有几个 report、每个多长，全写在里面。
        if let descriptor = Self.data(device, Self.reportDescriptorKey) {
            log("HIDPROBE DESCRIPTOR name=\(product) len=\(descriptor.count)")
            // 主日志只放截断版，完整字节进文件——描述符动辄几百字节。
            AppLogger.shared.log(
                "BLESCAN HIDPROBE DESCRIPTOR hex=\(BLEScanFormatter.hex(descriptor, limit: 64))"
            )
            fileLog?.write(
                "HIDPROBE DESCRIPTOR name=\(product) "
                    + "hex=\(BLEScanFormatter.hex(descriptor, limit: .max))"
            )
        } else {
            log("HIDPROBE 拿不到报文描述符 name=\(product)")
        }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.bufferSize)
        buffers.append(buffer)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            Self.bufferSize,
            { context, _, _, _, reportID, report, reportLength in
                guard let context, reportLength > 0 else { return }
                let probe = Unmanaged<HIDReportProbe>.fromOpaque(context).takeUnretainedValue()
                let data = Data(bytes: report, count: reportLength)
                // IOHID 回调在被调度的 RunLoop 上；显式跳回主线程再改状态。
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        probe.handle(reportID: Int(reportID), data: data)
                    }
                }
            },
            context
        )
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        attachedDevices.append(device)
        log("HIDPROBE 已挂上报文回调 name=\(product)")
    }

    private func handle(reportID: Int, data: Data) {
        fileLog?.write(
            "HIDPROBE RAW reportID=\(reportID) len=\(data.count) "
                + "hex=\(BLEScanFormatter.hex(data, limit: .max))"
        )
        for line in reports.record(channel: "\(reportID)", data: data, at: Date()) {
            AppLogger.shared.log(line)
        }
    }

    private func log(_ message: String) {
        AppLogger.shared.log("BLESCAN \(message)")
        fileLog?.write("BLESCAN \(message)")
    }

    private static func name(of device: IOHIDDevice) -> String? {
        string(device, kIOHIDProductKey)
    }

    private static func string(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func int(_ device: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int
    }

    private static func data(_ device: IOHIDDevice, _ key: String) -> Data? {
        IOHIDDeviceGetProperty(device, key as CFString) as? Data
    }

    private static func hexID(_ device: IOHIDDevice, _ key: String) -> String {
        guard let value = int(device, key) else { return "?" }
        return "0x" + String(value, radix: 16, uppercase: true)
    }
}
