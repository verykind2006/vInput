import AppKit
import Foundation

/// 确保文本注入到会话开始时那个应用，而不是中途抢占焦点的应用。
///
/// 防范的是最严重的失败模式：用户在编辑器里口述，
/// 中途聊天软件弹窗抢占焦点，内容被送进了错误的窗口。
struct TargetAppGuard {
    /// 可注入，便于测试。
    var frontmostBundleID: () -> String? = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// 会话开始时调用，记录目标应用。
    func capture() -> String? {
        frontmostBundleID()
    }

    /// 注入前调用。目标应用已变则抛出。
    ///
    /// 若 `token` 为 nil（捕获时没有前台应用，例如从 Finder 桌面触发），
    /// 则跳过校验——没有基准可比，阻断注入只会让功能不可用。
    func verify(_ token: String?) throws {
        guard let token else { return }
        let current = frontmostBundleID()
        guard current == token else {
            throw TextSinkError.targetApplicationChanged(expected: token, actual: current)
        }
    }
}
