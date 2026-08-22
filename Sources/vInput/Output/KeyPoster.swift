import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// 把一次按键送给前台应用。
///
/// 抽成协议是为了能测：真发 `CGEvent` 需要辅助功能授权，而测试进程拿不到
/// （TCC 绑 app bundle，与麦克风同一类问题）。生产实现照抄
/// `ClipboardSink.postCommandV` 的路子——那条路在真机上验证过。
protocol KeyPoster: Sendable {
    func postReturn()
    /// 退格。遥控器关机键的映射目标（2026-08-20 侦察后定的，
    /// 见 `HIDReportParser.powerButtonUsage`）。
    func postBackspace()
    /// 空格。遥控器「·」键的映射目标（2026-08-21 用户定的，
    /// 见 `HIDReportParser.graveButtonUsage`）。
    ///
    /// **必须是按键，不是字符。** 用户要的是 Finder 里的 Quick Look，
    /// 那是系统对空格**键**的响应；往输入框塞一个 " " 不会弹出预览。
    /// 所以它走这条 CGEvent 注入的路，不走 `TextSink`。
    func postSpace()
    /// Command+Tab：切到上一个应用。遥控器菜单键的映射目标
    /// （2026-08-21 用户提的，见 `HIDReportParser.contextMenuButtonUsage`）。
    ///
    /// **语义是「按一下切到上一个应用」**，不是「按住 Cmd 循环选择」。
    /// 上面三个键的注入路径**清零修饰键**，这一个恰恰相反——它必须带着
    /// `.maskCommand`。理由与实现见 `SystemKeyPoster.postAppSwitch`。
    func postAppSwitch()
}

struct SystemKeyPoster: KeyPoster {
    /// 三个虚拟键码。**用 `kVK_*` 常量而不是裸数字**（2026-08-21 换的）。
    ///
    /// 原来写的是 `post(key: 49, ...)  // kVK_Space` 这样的字面量加注释。
    /// 问题是**没有任何东西守得住那个数**：真发 CGEvent 需要辅助功能授权，
    /// 测试进程里发不出去也验不了，实测把 49 改成 51 之后 1183 条用例全绿。
    /// 换成 Carbon 常量之后，「这个数对不对」由编译器和系统头文件回答，
    /// 剩下的只是「有没有引错常量」——那由下面三条断言钉住。
    static let returnKey = CGKeyCode(kVK_Return)
    /// Backspace，不是 forward delete。
    static let backspaceKey = CGKeyCode(kVK_Delete)
    static let spaceKey = CGKeyCode(kVK_Space)
    /// Command+Tab 用的两个键码。`kVK_Tab` == 48，`kVK_Command` == 55。
    static let tabKey = CGKeyCode(kVK_Tab)
    static let commandKey = CGKeyCode(kVK_Command)

    /// 上面那三个键投递到哪一层。
    ///
    /// `.cgSessionEventTap` 是登录会话这一层，普通按键从这里进去就够了
    /// ——回车 / 退格 / 空格三条都是这么发的，且都真机验过。
    static let defaultTap: CGEventTapLocation = .cgSessionEventTap

    /// **Command+Tab 投递到哪一层——这一条没有在真机上验证过。**
    ///
    /// Cmd+Tab 不是普通按键：应用切换器由 WindowServer 在比前台应用更高的
    /// 层次上截获，`.cgSessionEventTap` 这一层进去的事件**可能到不了它**。
    /// 通行做法是走 `.cghidEventTap`（HID 层，位置更靠前，等价于「像真键盘
    /// 一样按下去」），所以默认取它。
    ///
    /// **真机上若按下菜单键没有切换应用，第一件要试的就是把这一行改成
    /// `.cgSessionEventTap`**（`AppSwitchKeyTests` 里那条钉断言要一起改）。
    /// 判据在日志：只要看到「菜单键按下，注入 Command+Tab」而应用没切，
    /// 就是这一层的问题，不必怀疑识别与吞键那两段。
    ///
    /// 为什么不在进程内证明它：注入 CGEvent 需要辅助功能授权，测试进程拿
    /// 不到（TCC 绑 app bundle）；就算发出去了，「应用有没有切」这件事也
    /// 只有真机能看。所以这里做的是**让换层的成本降到改一行**。
    static let appSwitchTap: CGEventTapLocation = .cghidEventTap

    /// nonisolated + Sendable：`CGEvent` 的发送是线程安全的。
    func postReturn() {
        post(key: Self.returnKey, name: "回车")
    }

    func postBackspace() {
        post(key: Self.backspaceKey, name: "退格")
    }

    /// 空格键。**下面 `post` 里清零修饰键这一步对它尤其要紧**：
    /// 用户按遥控器时另一只手常搭在键盘上，而 ⌘Space 是切换输入法、
    /// ⌃Space 也是，⇧Space 在部分输入法里是半/全角切换——任何一个都不是
    /// Quick Look。
    func postSpace() {
        post(key: Self.spaceKey, name: "空格")
    }

    /// Command+Tab。**它不能复用 `post(key:name:)`**：那条路径显式清零修饰键，
    /// 而这里恰恰需要 Command 是按下的。所以写成一个兄弟函数，不去动那条
    /// 已经真机验过的路——清零那一步对回车 / 退格 / 空格是**关键行为**，
    /// 理由见下面的注释。
    ///
    /// **为什么发四个事件而不是「一个带 Command 标志的 Tab」。**
    /// 应用切换器不是普通快捷键：它靠的是「Command 处于按下状态」这个
    /// **修饰键状态**，而不是某个事件上的标志位。只发一个带 `.maskCommand`
    /// 的 Tab，系统这边的修饰键状态从头到尾没变过，切换器可能根本不认。
    /// 所以按真键盘的顺序补全：
    ///
    /// 1. `flagsChanged`，Command 按下（键码 55，标志 `.maskCommand`）；
    /// 2. Tab 按下，带 `.maskCommand`；
    /// 3. Tab 松开，带 `.maskCommand`；
    /// 4. `flagsChanged`，Command 松开（标志清空）。
    ///
    /// 第 4 步立刻发出去，正是「按一下 = 切到上一个应用」这个语义的来源：
    /// Command 一松，切换器当场落定，不会停在选择界面上等用户。
    ///
    /// `CGEvent` 造不出 `flagsChanged`，只能先造键盘事件再改 `type`
    /// ——这是这类注入的通行写法。
    func postAppSwitch() {
        guard
            let commandDown = CGEvent(
                keyboardEventSource: nil, virtualKey: Self.commandKey, keyDown: true),
            let tabDown = CGEvent(
                keyboardEventSource: nil, virtualKey: Self.tabKey, keyDown: true),
            let tabUp = CGEvent(
                keyboardEventSource: nil, virtualKey: Self.tabKey, keyDown: false),
            let commandUp = CGEvent(
                keyboardEventSource: nil, virtualKey: Self.commandKey, keyDown: false)
        else {
            AppLogger.shared.log("Command+Tab 注入失败：建不出 CGEvent")
            return
        }
        commandDown.type = .flagsChanged
        commandUp.type = .flagsChanged
        commandDown.flags = .maskCommand
        tabDown.flags = .maskCommand
        tabUp.flags = .maskCommand
        // 最后一个显式清空：不清的话系统会留在「Command 还按着」的状态里，
        // 之后用户敲什么都变成快捷键。
        commandUp.flags = []
        for event in [commandDown, tabDown, tabUp, commandUp] {
            event.post(tap: Self.appSwitchTap)
        }
    }

    private func post(key: CGKeyCode, name: String) {
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        else {
            AppLogger.shared.log("\(name)注入失败：建不出 CGEvent")
            return
        }
        // **必须显式清零修饰键。**
        //
        // `CGEvent(keyboardEventSource: nil, ...)` 会继承当前的组合修饰键
        // 状态：用户按着 Shift 或 Cmd 时，注入出去的就是 Shift+Return /
        // Cmd+Return——在聊天应用里语义完全不同（一个换行、一个发送）。
        // 而按鼠标上的回车键时，另一只手正搭在键盘上是常态。
        //
        // `ClipboardSink.postCommandV` 显式赋 `.maskCommand` 也是同一个
        // 道理，只是它要的是「加上」，这里要的是「清空」。独立验收
        // 2026-08-18 指出本文件自称抄袭那条路径却漏了这一步。
        //
        // **2026-08-22 补：这一步是这条路径独有的，不要顺手抽成参数。**
        // 同日加的 `postAppSwitch` 需要 Command 是按下的，它另写了一个
        // 兄弟函数，没有动这里——把 flags 变成参数、让调用方各传各的，
        // 等于把这段注释里的「必须」降级成「默认」。
        down.flags = []
        up.flags = []
        down.post(tap: Self.defaultTap)
        up.post(tap: Self.defaultTap)
    }
}
