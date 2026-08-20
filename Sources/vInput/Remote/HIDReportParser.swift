import Foundation

/// 解析小米遥控器的 HID 输入报文。
///
/// 报文格式实测自上游 `RemoteButtons.swift`：报文 ID 必须为 1；若长度为 7
/// 且首字节等于报文 ID 则去掉首字节；其余按小端 `UInt16` 两两读出，
/// 非零者即为当前按下的 usage。
///
/// 本项目只需识别返回键，因此没有移植上游那套按键映射体系——那 1541 行的
/// 体量全在映射、手势识别、多设备档案上，而解析本身只有这十几行。
enum HIDReportParser {
    /// 遥控器的设备匹配标识。
    static let vendorID = 0x2717   // 小米
    static let productID = 0x32B8

    /// 返回键的 HID usage。
    ///
    /// **注意它不是标准的 Escape（0x29）**，因此系统不会把它变成普通按键，
    /// 本项目已有的 Carbon 全局热键接不住，必须自行监听 HID。
    static let backButtonUsage: UInt16 = 0xF1

    /// RC003 实测出的完整按键表（2026-08-15，靠 `RemoteHIDListener` 的
    /// usage 日志逐个按出来的）。上游那 1541 行按键映射没有移植，
    /// 这张表是本项目自己测的，将来要映射新按键直接查这里。
    ///
    /// | usage | 按键 | 系统行为 |
    /// |---|---|---|
    /// | `0x28` | 确认键（中间圆键） | **macOS 已当标准回车投递，无需映射** |
    /// | `0x3E` | 语音键 | F5。macOS 会投递给前台应用，录音期间需要
    ///                     `RemoteKeySuppressor` 吞掉，否则输入框被杂键淹没 |
    /// | `0x4F` / `0x50` / `0x51` / `0x52` | 右 / 左 / 下 / 上 | 标准方向键 |
    /// | `0xF1` | 返回键 | 非标准，系统不投递，本项目用它做取消 |
    /// | `0x66` | 关机键 | 见 `powerButtonUsage` |
    ///
    /// 曾计划把确认键映射成回车，实测发现系统本来就投递了——**没有为一个
    /// 不存在的问题写代码**。

    /// 关机键（Keyboard Page 的 Power）。映射成退格（2026-08-20 用户定的，
    /// 起因是误碰它会弄出系统级动作）。
    ///
    /// 当天真机侦察（三次短按 + 一次长按，逐次对日志）：
    /// - **短按：系统零投递、零副作用**——不产生键盘事件（无 keyCode 行）、
    ///   不关屏。所以映射退格**不需要拦截任何东西**，识别到就注入即可。
    /// - **长按约 3 秒：系统弹「关机/睡眠」确认框。** 报文层面长短按
    ///   一模一样（都只有按下沿一行），按住时长是系统层判的，这条路
    ///   在本监听之外，拦不住也不必拦——误碰都是短按，长按有确认框兜底。
    /// - 原报告「误碰后直接关掉电脑屏幕」当天未能复现（三次短按都没关屏），
    ///   若再出现要记下当时的按法与系统状态。
    static let powerButtonUsage: UInt16 = 0x66

    static func usages(reportID: UInt32, data: Data) -> Set<UInt16>? {
        guard reportID == 1 else { return nil }

        var bytes = Array(data)
        if bytes.count == 7, bytes.first == UInt8(reportID) {
            bytes.removeFirst()
        }
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { return nil }

        var result = Set<UInt16>()
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let usage = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            if usage != 0 { result.insert(usage) }
        }
        return result
    }
}
