import Foundation
import Testing

@testable import vInput

/// `AppModel` 的接线不变量，用**扫源码**的方式钉住。
///
/// # 为什么是扫源码而不是跑 AppModel
///
/// `AppModel` 在 `init` 里就要真麦克风、真快捷键注册、真 CGEvent tap，
/// 单元测试里起不来。现有的办法是 `MouseWiringUnderTest`——照抄一份接线
/// 再测那一份。它挡得住「协调器与桥接错了」，**挡不住「AppModel 那一份
/// 和抄本不一样了」**，而 Esc 取消不收抑制（独立验收 2026-08-18）恰恰就是
/// 这一类：抄本里根本没有 Esc 这条路。
///
/// 扫源码只能证明「那行代码还在」，证明不了它是对的——正确性由
/// `RemoteKeySuppressorTests` 那几条纯逻辑断言负责。两者分工：
/// 一个测语义，一个防删除。
@Suite("AppModel 接线不变量")
struct AppModelWiringTests {
    static func appModelSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // vInputTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
        return try String(
            contentsOf: root.appendingPathComponent("Sources/vInput/App/AppModel.swift"),
            encoding: .utf8
        )
    }

    /// 按 Esc 取消时必须当场收掉按键抑制。
    ///
    /// 漏掉的后果不是「少一次清理」：鼠标那档是 `.allExcept([Esc])`，
    /// 用户按 Esc 之后整个键盘只剩 Esc 可用，直到他松开鼠标语音键。
    @Test("Esc 取消的处理里收掉按键抑制")
    func cancelEndsSuppression() throws {
        let source = try Self.appModelSource()
        guard let start = source.range(of: "cancelHotkey.onCancel = {") else {
            Issue.record("找不到 cancelHotkey.onCancel 的接线，这个测试的锚点失效了")
            return
        }
        // 闭包本体只有十几行，取一段足够长的窗口即可，不必真去配对花括号。
        let body = source[start.lowerBound...].prefix(1200)
        #expect(
            body.contains("keySuppressor.endSuppressing()"),
            """
            cancelHotkey.onCancel 里没有 endSuppressing()。
            鼠标档的抑制策略是 .allExcept([Esc])：不收的话，按 Esc 取消之后
            整个键盘只剩 Esc 能用，直到用户松开鼠标语音键。
            """
        )
    }

    /// 会话状态变化时同步抑制器。这是「离开 .listening 就还键盘」那道网。
    @Test("会话状态变化时同步按键抑制器")
    func stateChangeSyncsSuppressor() throws {
        let source = try Self.appModelSource()
        #expect(
            source.contains("keySuppressor.update(for: state)"),
            """
            session.onStateChange 里没有 keySuppressor.update(for: state)。
            离开 .listening 的出口不止一个（松开键、撞时长上限、转写失败、
            Esc 取消），逐个出口去收迟早漏一个——Esc 那条已经漏过一次。
            """
        )
    }
}
