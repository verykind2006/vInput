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

    // MARK: - 翻译层的挂载走协调器，且只走协调器

    /// 翻译层「挂什么」的状态机搬进了 `TranslationAttachmentCoordinator`
    /// （理由见那边：长在 `AppModel` 里是零覆盖，两条变异实测全绿）。
    ///
    /// 搬走之后要守的是「`AppModel` 真的在调它」——
    /// `TranslationAttachmentCoordinatorTests` 跑的是协调器，那套用例在
    /// 「`AppModel` 压根不调协调器」时照样全绿，正是本仓库栽过七次的
    /// 「看着在检查什么，其实什么都没检查」的翻版。
    @Test("换语言时把偏好交给翻译协调器")
    func applyTranslationGoesThroughCoordinator() throws {
        let source = try Self.appModelSource()
        #expect(
            source.contains("translationCoordinator?.apply()"),
            """
            applyTranslationPreference 里没有 translationCoordinator?.apply()。
            没有这一句的话，用户在菜单里换语言什么都不会发生，
            而 TranslationAttachmentCoordinatorTests 照样全绿。
            """
        )
    }

    /// 会话回到 idle 时要给协调器一次补挂的机会。
    ///
    /// 缺了它的表现是「用户在录音途中换的语言永远不生效」——
    /// `DictationSession` 只在 idle 时接受挂载，那次改动就此丢失，
    /// 而菜单已经写着新语言。
    @Test("会话回到 idle 时给翻译协调器补挂的机会")
    func idleResumesPendingTranslationAttach() throws {
        let source = try Self.appModelSource()
        #expect(
            source.contains("translationCoordinator?.sessionDidBecomeIdle()"),
            """
            onStateChange 的 .idle 分支里没有 sessionDidBecomeIdle()。
            录音途中换的语言会被 DictationSession 拒绝，没人补挂的话
            这次改动永远丢失，而菜单已经写着新语言。
            """
        )
    }

    /// **`AppModel` 里不许再出现第二条挂翻译的路径。**
    ///
    /// 这是「抽出来的那个就是实际跑的那个」最硬的一条：协调器的用例只有在
    /// 它是**唯一**实现时才代表线上行为。哪天有人在 `AppModel` 里就地补一句
    /// `session.attachTranslation(...)`，协调器那套用例一条都不会红，而两条
    /// 路径的松紧从此各走各的。
    ///
    /// 用整份源码做 `contains` 而不是逐行 grep：跨行写法（把参数换行）
    /// 行式匹配看不见——本仓库一天栽过三次这个坑。
    @Test("AppModel 自己不再直接挂翻译流水线")
    func appModelHasNoSecondTranslationAttachPath() throws {
        let source = try Self.appModelSource()
        #expect(
            !source.contains("attachTranslation"),
            """
            AppModel 里又出现了 attachTranslation。翻译层的挂载必须只有
            TranslationAttachmentCoordinator 一条路径，否则那套用例证明不了
            线上跑的是什么。
            """
        )
    }
}
