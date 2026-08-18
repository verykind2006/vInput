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
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
