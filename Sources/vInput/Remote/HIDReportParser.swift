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
    /// | `0x35` | 「·」键 | 标准 Grave/Tilde。**系统照常投递**，见 `graveButtonUsage` |
    /// | `0x4A` | Home 键 | 标准 Keyboard Home。**观测到但未映射**，见下 |
    /// | `0x65` | 菜单键 | Keyboard Application。**系统照常投递**（弹右键菜单），
    ///                    见 `contextMenuButtonUsage` |
    /// | `0xF1` | 返回键 | 非标准，系统不投递，本项目用它做取消 |
    /// | `0x66` | 关机键 | 见 `powerButtonUsage` |
    ///
    /// 2026-08-21 补了 `0x35` 一行——原表只有 8 个 usage，把这个键漏了。
    /// 2026-08-22 补了 `0x65` 与 `0x4A` 两行：用户为找「映射 Command+Tab 的
    /// 那个键」连按了九下菜单键（18:26–18:27 的 `遥控器按键 usage=0x65`），
    /// 同一轮里顺手把 Home 键也按了三下（18:26:41 的三行 `usage=0x4A`）。
    ///
    /// **`0x4A`（Home）目前没有映射，是遥控器上下一个可用的空键。**
    /// 留在表里是为了下次再要加键时不用再让用户按一轮——它是唯一一个
    /// 已认出编号、又没被占用的键。要用它时注意先查系统投不投递：Home 是
    /// 标准键码，多半和 `0x35`/`0x65` 一样需要吞回声。
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

    /// 遥控器上那个会打出「·」的键（Keyboard Grave Accent/Tilde）。
    /// 映射成**空格**（2026-08-21 用户定的）。
    ///
    /// **诉求是 Quick Look，不是打一个空格字符。** 用户的原话：在 Finder 里
    /// 选中一张图片，按这个键要像按下键盘空格键那样弹出预览。所以只往输入框
    /// 塞一个 " " 是不合格的——必须投递真正的空格**按键**，系统与应用的
    /// 快捷键才会响应。这就是它走 `KeyPoster.postSpace()`（CGEvent 注入
    /// `kVK_Space`）而不是走任何 `TextSink` 的原因。
    ///
    /// **0x35 是实测出来的**：2026-08-21 用户连按三次，
    /// `RemoteHIDListener` 的 usage 日志记下 16:42:17.620 / 16:42:20.185 /
    /// 16:42:22.525 三行 `遥控器按键 usage=0x35`。0x35 是标准的
    /// Grave Accent，中文输入法下打出「·」——正是用户今天看到的现象。
    ///
    /// **与关机键的关键差别：系统会投递它。** `0x66` 短按零投递，识别到直接
    /// 注入即可；这个键既然能打出「·」，就说明它一路走到了前台应用，因此
    /// 必须**两件事都做**：吞掉原始按键（`RemoteEchoSwallower`）＋ 注入真空格。
    /// 少做前一件，用户会同时得到「·」和一个空格。
    static let graveButtonUsage: UInt16 = 0x35

    /// 遥控器上那个菜单键（Keyboard Application）。映射成 **Command+Tab**
    /// （2026-08-21 用户提的，2026-08-22 认的键）。
    ///
    /// **诉求是「按一下切到上一个应用」**，不是「按住 Cmd 循环选择」。
    /// 用户原话：「小米遥控器上还有多余的按键，其中有一个键，我想让它
    /// 按下去之后，起到 Command + Tab 的效果。」语义当天确认过：单次切换。
    ///
    /// **0x65 是实测出来的**：2026-08-22 用户连按九下，`RemoteHIDListener`
    /// 的 usage 日志记下 18:26:28.413 / 18:26:34.249 / 18:26:45.409 /
    /// 18:26:46.100 / 18:26:51.124 / 18:26:52.189 / 18:27:05.975 /
    /// 18:27:07.130 / 18:27:08.001 九行 `遥控器按键 usage=0x65`
    /// （另有 18:27:10.056 一行，共十次按下沿）。0x65 在 HID 键盘页里是
    /// **Keyboard Application**，也就是 PC 键盘上那个「菜单键」。
    ///
    /// **系统会投递它**：用户的描述是「现在是唤醒菜单」——弹出右键菜单
    /// 就是它一路走到了前台应用的证据。所以和「·」键同型，必须**两件事
    /// 都做**：吞掉原始按键（`RemoteEchoSwallower`）＋ 注入 Command+Tab
    /// （`KeyPoster.postAppSwitch`）。少做前一件，用户会「切了应用」和
    /// 「弹出右键菜单」同时得到。
    ///
    /// macOS 侧的虚拟键码见 `RemoteEchoSwallower.Key.contextualMenu`
    /// ——那一条是**推断**，兜底诊断日志也在那儿说明。
    static let contextMenuButtonUsage: UInt16 = 0x65

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
