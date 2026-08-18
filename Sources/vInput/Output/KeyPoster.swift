import CoreGraphics
import Foundation

/// 把一次按键送给前台应用。
///
/// 抽成协议是为了能测：真发 `CGEvent` 需要辅助功能授权，而测试进程拿不到
/// （TCC 绑 app bundle，与麦克风同一类问题）。生产实现照抄
/// `ClipboardSink.postCommandV` 的路子——那条路在真机上验证过。
protocol KeyPoster: Sendable {
    func postReturn()
}

struct SystemKeyPoster: KeyPoster {
    /// nonisolated + Sendable：`CGEvent` 的发送是线程安全的。
    func postReturn() {
        let returnKey: CGKeyCode = 36  // kVK_Return
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: returnKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: returnKey, keyDown: false)
        else {
            AppLogger.shared.log("回车注入失败：建不出 CGEvent")
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
