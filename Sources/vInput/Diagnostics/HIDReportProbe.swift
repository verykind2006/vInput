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
///
/// # 失控流自我保护
///
/// 与 `BLEScanner` 同一套判据（`BLEScanStreamGuard`），**因为两者写的是
/// 同一个文件**：`AppModel.startBLEScan` 把同一个 `BLEScanFileLog` 传给
/// 两边，于是「GATT 那条被掐断了」根本不等于「不再落盘」。
/// 原来只有扫描器有守卫，探针一道都没有——独立验收 2026-08-18 指出。
///
/// 目前 HID 侧落的是报文不是音频，但上面那句「音频完全可能就搭着 HID
/// 报文走」是这条诊断存在的全部理由。不给它守卫，等于赌那句话是错的。
///
/// **按 report ID 分开计账**：混在一起算的话，指针报文（动一下鼠标就是
/// 一串）会不停刷新「上一个包」的时刻，任何两条通道交织都变成一整段连续流
/// ——正常用鼠标就撞线，而误伤一轮真机诊断的代价是把用户叫回来重按一轮。
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
    /// 每条 report ID 一份守卫。理由见文件头。
    private var streamGuards: [Int: BLEScanStreamGuard] = [:]
    /// 已经因失控流停过。停了就彻底停，不靠外壳记得来关。
    private(set) var hasStoppedRunawayStream = false

    /// 撞到上限时顺带把另一条诊断路径也停掉。
    ///
    /// **两条路写同一个文件**，只停一条等于没停。由 `AppModel` 接线成
    /// 「探针停 → 扫描器也停」，反向同理。
    var onRunawayStop: (() -> Void)?

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
        streamGuards.removeAll()
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

    /// 处理一个输入报文。
    ///
    /// `internal` 而不是 `private`，且时间从外面传：失控流那道守卫要靠
    /// 模拟时间来测，而真实路径上这个函数只能由 IOKit 回调触发——测不到的
    /// 守卫等于没有守卫，这个项目在这上面栽过（`0x31` 那条保护「全绿」
    /// 但实测有两条绕过路径）。
    func handle(reportID: Int, data: Data, at now: Date = Date()) {
        // 停过就一个字节都不再写。**这一行不是多余的**：`stopRunawayStream`
        // 里调的 `stop()` 会把 `streamGuards` 清空，没有它的话，之后来的报文
        // 会拿到一份崭新的守卫、从零开始计时，于是「已经停了」的路径又开始
        // 落盘——正是这道保护要防的东西。
        guard !hasStoppedRunawayStream else { return }
        // **判在落盘之前。** 一旦决定停，这一个报文就不该再写进文件。
        var guardian = streamGuards[reportID] ?? BLEScanStreamGuard()
        let verdict = guardian.record(at: now)
        streamGuards[reportID] = guardian
        if let verdict {
            stopRunawayStream(reportID: reportID, reason: verdict)
            return
        }

        fileLog?.write(
            "HIDPROBE RAW reportID=\(reportID) len=\(data.count) "
                + "hex=\(BLEScanFormatter.hex(data, limit: .max))"
        )
        for line in reports.record(channel: "\(reportID)", data: data, at: now) {
            AppLogger.shared.log(line)
        }
    }

    /// 某条通道的报文流失控——停掉整条诊断并告警。
    ///
    /// **文案不说「这些没落盘」。** 触发之前的报文（单段最多 90 秒、
    /// 累计最多 180 秒）早就一个不少地写进文件了；说反了会让用户以为
    /// 磁盘上是干净的。扫描器那边同一个坑刚被独立验收指出过。
    private func stopRunawayStream(reportID: Int, reason: BLEScanStreamGuard.Stop) {
        guard !hasStoppedRunawayStream else { return }
        hasStoppedRunawayStream = true

        let cause: String
        switch reason {
        case .burst(let duration):
            cause = "report \(reportID) 已连续来了 \(Int(duration)) 秒报文且没有停下的迹象"
        case .total(let duration, let bursts):
            cause = "report \(reportID) 本轮累计已来了 \(Int(duration)) 秒报文"
                + "（分 \(bursts) 段），触及总量上限"
        }
        log("⚠️ HIDPROBE \(cause)。已停止 HID 侧诊断。")
        if let fileLog {
            log("⚠️ HIDPROBE 停下来**之前**收到的报文已经写进了 \(fileLog.path)"
                + "（这道守卫只挡得住此刻起的新报文）。不想留就删掉那个文件。")
        }
        stop()
        // GATT 那条也要停：两条路写的是同一个文件，只停一条等于没停。
        onRunawayStop?()
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
