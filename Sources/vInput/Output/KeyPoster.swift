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
}

struct SystemKeyPoster: KeyPoster {
    /// nonisolated + Sendable：`CGEvent` 的发送是线程安全的。
    func postReturn() {
        post(key: 36, name: "回车")  // kVK_Return
    }

    func postBackspace() {
        post(key: 51, name: "退格")  // kVK_Delete（Backspace，不是 forward delete）
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
