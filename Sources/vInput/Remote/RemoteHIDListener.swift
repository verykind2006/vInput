import Foundation
import IOKit.hid

/// 监听小米遥控器的返回键，用作取消。
///
/// **为什么必须监听 HID：** 返回键的 usage 是 0xF1，不是标准 Escape（0x29），
/// 系统不会把它变成普通按键，本项目已有的 Carbon 全局热键接不住。
///
/// **为什么自写而不移植：** 上游的 HID 子系统共 1541 行，体量全在按键映射、
/// 手势识别、多设备档案上。本项目只需识别一个 usage，不值当。
@MainActor
final class RemoteHIDListener {
    /// 返回键被按下时触发。
    var onCancelPressed: (() -> Void)?
    /// 关机键被按下时触发（映射成退格，接线与「录音中忽略」的判断在
    /// `AppModel`——这一层只认 usage，不该知道注入与会话）。
    var onPowerPressed: (() -> Void)?

    private var manager: IOHIDManager?
    private var pressedUsages: Set<UInt16> = []

    /// 「输入监控」权限是否已授予。
    ///
    /// 未授予时听写**照常工作**——语音走 BLE，只需蓝牙权限。
    /// 仅返回键取消不可用。取消是锦上添花，听写是主路径。
    static func hasInputMonitoringAccess() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// 请求「输入监控」权限。系统会弹出授权面板。
    @discardableResult
    static func requestInputMonitoringAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func start() {
        guard manager == nil else { return }
        guard Self.hasInputMonitoringAccess() else {
            AppLogger.shared.log("未授予输入监控权限，遥控器返回键取消不可用")
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey as String: HIDReportParser.vendorID,
            kIOHIDProductIDKey as String: HIDReportParser.productID,
        ] as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputReportCallback(
            manager,
            { context, _, _, _, reportID, report, reportLength in
                guard let context else { return }
                let listener = Unmanaged<RemoteHIDListener>.fromOpaque(context).takeUnretainedValue()
                let data = Data(bytes: report, count: reportLength)
                // IOHID 回调在被调度的 RunLoop 上；显式跳回主线程再改状态。
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        listener.handleReport(reportID: UInt32(reportID), data: data)
                    }
                }
            },
            context
        )
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            AppLogger.shared.log("HID 监听打开失败：\(result)")
            return
        }

        self.manager = manager
        AppLogger.shared.log("HID 监听已启动")
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        pressedUsages = []
    }

    private func handleReport(reportID: UInt32, data: Data) {
        guard let current = HIDReportParser.usages(reportID: reportID, data: data) else { return }
        let previous = pressedUsages
        pressedUsages = current

        // 记录每个刚按下的 usage。上游只移植了返回键，其余按键的 usage
        // 本项目并不知道——要映射新按键（例如把确认键当回车），得先靠
        // 这条日志实测出它的编号，没有别的办法拿到。
        for usage in current.subtracting(previous).sorted() {
            AppLogger.shared.log(
                "遥控器按键 usage=0x\(String(usage, radix: 16, uppercase: true))"
            )
        }

        if Self.didPress(usage: HIDReportParser.backButtonUsage, previous: previous, current: current) {
            onCancelPressed?()
        }
        if Self.didPress(usage: HIDReportParser.powerButtonUsage, previous: previous, current: current) {
            onPowerPressed?()
        }
    }

    /// 判断某个 usage 是否在本次报文中「刚被按下」。
    ///
    /// 抽成纯函数以便单测——真实 HID 设备无法在测试中构造。
    nonisolated static func didPress(
        usage: UInt16,
        previous: Set<UInt16>,
        current: Set<UInt16>
    ) -> Bool {
        current.contains(usage) && !previous.contains(usage)
    }
}
