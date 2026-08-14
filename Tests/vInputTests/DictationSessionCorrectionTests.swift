import Foundation
import Testing

@testable import vInput

/// 可编程的假校正器。
private final class StubCorrector: Corrector, @unchecked Sendable {
    let stubEdits: [CorrectionEdit]
    let shouldThrow: Bool

    init(edits: [CorrectionEdit] = [], shouldThrow: Bool = false) {
        self.stubEdits = edits
        self.shouldThrow = shouldThrow
    }

    func prepare() async throws {
        if shouldThrow { throw CorrectorError.modelNotReady }
    }

    func edits(for text: String) async throws -> [CorrectionEdit] {
        if shouldThrow { throw CorrectorError.modelNotReady }
        return stubEdits
    }
}

@Suite("会话中的校正")
@MainActor
struct DictationSessionCorrectionTests {
    private func makeSession(
        transcript: String,
        corrector: Corrector?,
        previewEngine: FakePreviewEngine? = nil
    ) -> (DictationSession, FakeAudioSource, SpySink) {
        let source = FakeAudioSource()
        let transcriber = FakeTranscriber()
        transcriber.result = transcript
        let sink = SpySink()
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }

        let session = DictationSession(
            audioSource: source,
            transcriber: transcriber,
            sink: sink,
            targetGuard: guardian,
            previewEngine: previewEngine,
            correctionPipeline: corrector.map { CorrectionPipeline(corrector: $0) }
        )
        return (session, source, sink)
    }

    private func runSession(_ session: DictationSession, _ source: FakeAudioSource) async throws {
        try await session.start()
        source.emit(Array(repeating: 0.1, count: 16_000))
        await session.finish()
    }

    @Test("校正后的文本被注入")
    func injectsCorrectedText() async throws {
        let (session, source, sink) = makeSession(
            transcript: "小米耀空气",
            corrector: StubCorrector(edits: [
                CorrectionEdit(original: "耀空气", replacement: "遥控器")
            ])
        )
        try await runSession(session, source)
        #expect(sink.received == ["小米遥控器"])
    }

    /// 规则二在本里程碑的具体形态：校正失败不得让用户说的话消失。
    @Test("校正失败仍注入原始转写")
    func injectsOriginalWhenCorrectionFails() async throws {
        let (session, source, sink) = makeSession(
            transcript: "小米耀空气",
            corrector: StubCorrector(shouldThrow: true)
        )
        try await runSession(session, source)
        #expect(sink.received == ["小米耀空气"])
    }

    /// 校正失败不是会话错误：用户拿到了文字，没有任何需要他处理的事。
    @Test("校正失败不上报为会话错误")
    func correctionFailureIsNotSessionError() async throws {
        let (session, source, _) = makeSession(
            transcript: "小米耀空气",
            corrector: StubCorrector(shouldThrow: true)
        )
        var errors: [Error] = []
        session.onError = { errors.append($0) }
        try await runSession(session, source)
        #expect(errors.isEmpty)
    }

    @Test("未配置校正器时行为不变")
    func worksWithoutCorrector() async throws {
        let (session, source, sink) = makeSession(transcript: "小米耀空气", corrector: nil)
        try await runSession(session, source)
        #expect(sink.received == ["小米耀空气"])
    }

    /// 校正需要完整句子才有上下文，对半句话做同音纠错只会添乱。
    /// 预览的定位是「让用户知道系统在听」，不是最终结果。
    @Test("实时预览不经过校正")
    func previewBypassesCorrection() async throws {
        let engine = FakePreviewEngine()
        // 本条只走预览通道，不喂音频也不 finish，故忽略音频源
        let (session, _, _) = makeSession(
            transcript: "小米耀空气",
            corrector: StubCorrector(edits: [
                CorrectionEdit(original: "耀空气", replacement: "遥控器")
            ]),
            previewEngine: engine
        )
        var previews: [String] = []
        session.onPreview = { previews.append($0.confirmed + $0.unconfirmed) }

        try await session.start()
        engine.emit(confirmed: "小米耀空气")
        // onPreview 经由 Task { @MainActor } 转发，让出一次以便它执行
        await Task.yield()

        #expect(previews.contains("小米耀空气"), "预览不该被校正改写，实际：\(previews)")
    }

    @Test("取消的会话不做校正也不注入")
    func cancelSkipsCorrection() async throws {
        let (session, source, sink) = makeSession(
            transcript: "小米耀空气",
            corrector: StubCorrector(edits: [
                CorrectionEdit(original: "耀空气", replacement: "遥控器")
            ])
        )
        try await session.start()
        source.emit(Array(repeating: 0.1, count: 16_000))
        await session.cancel()
        #expect(sink.received.isEmpty)
    }
}
