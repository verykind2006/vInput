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
        down.flags = []
        up.flags = []
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
