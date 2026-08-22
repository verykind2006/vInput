import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// 应用切换器会话里的一步。
///
/// **切换器不是一次按键，是一段按住 Command 的会话**：Command 按下 →
/// 一个或多个 Tab → Command 抬起，抬起那一刻切换才落地。攒会话的逻辑在
/// `AppSwitcher`，这里只负责把某一步真的发出去。
///
/// 拆成三步而不是一个 `postAppSwitch()`，是 2026-08-22 真机验收之后改的：
/// 原来那版一次按键就把 Command 松开，macOS 随即重排 MRU，用户只能在两个
/// 应用之间来回，翻不到第三个。
enum AppSwitchStep: String, Sendable, CaseIterable {
    /// 按住 Command（`flagsChanged`）。浮层由它唤出。
    case commandDown
    /// 按一次 Tab，Command 保持按住。选中项前进一格。
    case tab
    /// 抬起 Command（`flagsChanged`）。**切换在这一刻才提交。**
    case commandUp
}

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
    /// 应用切换器会话的一步。遥控器菜单键的映射目标（2026-08-21 用户提的，
    /// 见 `HIDReportParser.contextMenuButtonUsage`）。
    ///
    /// **哪一步在什么时候发，由 `AppSwitcher` 决定，不由这里决定。**
    /// 上面三个键的注入路径**清零修饰键**，这一路恰恰相反——它要让 Command
    /// 跨越多次按键一直按着。理由与实现见 `SystemKeyPoster.postAppSwitch`。
    func postAppSwitch(_ step: AppSwitchStep)
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
    /// **2026-08-22 真机验收：这一层是对的，不用改。** 短按确实切到了上一个
    /// 应用——注入这条链（HID 层 + `kVK_ContextualMenu` == 110）整条通了。
    /// 原先「未验证、不生效就改这一行」的说明到此作废，留着这段是为了下次
    /// 有人怀疑注入层时不必再验一遍。
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

    /// 应用切换器会话的一步。**它不能复用 `post(key:name:)`**：那条路径
    /// 显式清零修饰键，而这一路恰恰需要 Command 是按下的。所以写成一个
    /// 兄弟函数，不去动那条已经真机验过的路——清零那一步对回车 / 退格 /
    /// 空格是**关键行为**，理由见下面 `post` 里的注释。
    ///
    /// **为什么 Command 要用 `flagsChanged` 而不是普通按键事件。**
    /// 应用切换器靠的是「Command 处于按下状态」这个**修饰键状态**，
    /// 不是某个事件上的标志位。`CGEvent` 造不出 `flagsChanged`，
    /// 只能先造键盘事件再改 `type`——这是这类注入的通行写法。
    ///
    /// **为什么三步分开发（2026-08-22 真机验收后改的）。**
    /// 原来是「按一下发全四个事件」，Command 当场松开。macOS 一提交切换就
    /// 重排 MRU，于是下一次按又从头开始，用户只能在两个应用之间来回。
    /// 现在 Command 由 `AppSwitcher` 按住跨越多次按键，中间只补 Tab，
    /// 停手才抬起。**哪一步在什么时候发，这里不判断。**
    func postAppSwitch(_ step: AppSwitchStep) {
        switch step {
        case .commandDown:
            postCommandFlag(down: true)
        case .commandUp:
            // 抬起那一刻切换才提交；同时它是「卡住的修饰键」那条风险的出口，
            // 所以 `flags` 显式清空——不清的话系统会留在「Command 还按着」
            // 的状态里，之后用户敲什么都变成快捷键。
            postCommandFlag(down: false)
        case .tab:
            guard
                let down = CGEvent(
                    keyboardEventSource: nil, virtualKey: Self.tabKey, keyDown: true),
                let up = CGEvent(
                    keyboardEventSource: nil, virtualKey: Self.tabKey, keyDown: false)
            else {
                AppLogger.shared.log("应用切换器 Tab 注入失败：建不出 CGEvent")
                return
            }
            // 带着 Command 标志：切换器认的是「Command 按着时按下的 Tab」。
            down.flags = .maskCommand
            up.flags = .maskCommand
            down.post(tap: Self.appSwitchTap)
            up.post(tap: Self.appSwitchTap)
        }
    }

    private func postCommandFlag(down: Bool) {
        guard let event = CGEvent(
            keyboardEventSource: nil, virtualKey: Self.commandKey, keyDown: down)
        else {
            AppLogger.shared.log("应用切换器 Command \(down ? "按下" : "抬起")注入失败：建不出 CGEvent")
            return
        }
        event.type = .flagsChanged
        event.flags = down ? .maskCommand : []
        event.post(tap: Self.appSwitchTap)
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
