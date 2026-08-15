import Foundation
import Testing

@testable import vInput

@MainActor
@Suite("校正偏好的延迟生效")
struct CorrectionPendingApplyTests {
    /// 会话进行中挂载会被 DictationSession 拒绝（它只在 idle 时接受），
    /// 因此必须有人记住这件事并在回到 idle 后补挂。
    /// 否则用户在录音中打开校正，本次启动内再也不会生效，而菜单显示「开」。
    ///
    /// 本测试钉住的是 DictationSession 这一侧的契约——AppModel 的补挂逻辑
    /// 正建立在它之上。
    @Test("非 idle 时挂载被拒，idle 时挂载生效")
    func attachOnlyTakesEffectWhenIdle() async throws {
        let source = FakeAudioSource()
        let transcriber = FakeTranscriber()
        transcriber.result = "小米耀空气"
        let sink = SpySink()
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }

        let session = DictationSession(
            audioSource: source,
            transcriber: transcriber,
            sink: sink,
            targetGuard: guardian
        )

        // 会话进行中挂载，应被拒绝
        try await session.start()
        session.attachCorrectionPipeline(
            CorrectionPipeline(corrector: AlwaysFixCorrector())
        )
        source.emit(Array(repeating: 0.1, count: 16_000))
        await session.finish()
        #expect(sink.received == ["小米耀空气"], "本次会话不该被校正")

        // 回到 idle 后挂载，下一次会话应当生效
        session.attachCorrectionPipeline(
            CorrectionPipeline(corrector: AlwaysFixCorrector())
        )
        try await session.start()
        source.emit(Array(repeating: 0.1, count: 16_000))
        await session.finish()
        #expect(sink.received == ["小米耀空气", "小米遥控器"], "补挂后应当生效")
    }
}

/// 固定把「耀空气」改成「遥控器」的假校正器。
private final class AlwaysFixCorrector: Corrector, @unchecked Sendable {
    func prepare() async throws {}
    func edits(for text: String) async throws -> [CorrectionEdit] {
        [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
    }
}
