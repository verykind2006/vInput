import Foundation

@testable import vInput

/// 记录按键注入而不真的发出去。
///
/// **必须在每个构造 `MouseBluetoothBridge` 的测试里传它。**
/// 桥的 `keyPoster` 默认参数是 `SystemKeyPoster()`，而 `MouseBluetoothBridgeTests`
/// 会喂 `0x27` 控制帧——于是 `swift test` 真的会往当时的前台应用注入回车键。
/// 至今没造成伤害，多半只是因为跑测试的进程没有辅助功能授权：
/// **那是运气，不是设计**（独立验收 2026-08-18 指出）。
///
/// 顺带解决另一个问题：测试与真机写同一个日志文件、日志行完全同形，
/// 用 `控制码 0x27（回车键）` 当真机证据时可能挑到测试那一行。
final class FakeKeyPoster: KeyPoster, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var backspaces = 0

    var returnCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var backspaceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return backspaces
    }

    func postReturn() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func postBackspace() {
        lock.lock()
        backspaces += 1
        lock.unlock()
    }
}
