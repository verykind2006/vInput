import Testing
@testable import vInput

/// 记录兜底调用的替身。
@MainActor
final class SpyRescue: TextRescuing {
    private(set) var rescued: [(text: String, error: Error)] = []

    func rescue(_ text: String, error: Error) async {
        rescued.append((text, error))
    }
}

/// 可编程的假校正器（本文件用来验证「交给兜底的是校正后的文本」）。
private final class StubCorrector: Corrector, @unchecked Sendable {
    let stubEdits: [CorrectionEdit]

    init(edits: [CorrectionEdit]) { stubEdits = edits }

    func prepare() async throws {}
    func edits(for text: String) async throws -> [CorrectionEdit] { stubEdits }
}

@Suite("注入失败时的文本兜底")
@MainActor
struct DictationSessionRescueTests {
    private func makeSession(
        transcript: String = "转写结果",
        sinkError: Error? = nil,
        frontmost: @escaping () -> String? = { "com.apple.Notes" },
        corrector: Corrector? = nil
    ) -> (DictationSession, FakeAudioSource, SpyRescue) {
        let source = FakeAudioSource()
        let transcriber = FakeTranscriber()
        transcriber.result = transcript
        let sink = SpySink()
        sink.error = sinkError
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = frontmost
        let rescue = SpyRescue()

        let session = DictationSession(
            audioSource: source,
            transcriber: transcriber,
            sink: sink,
            targetGuard: guardian,
            correctionPipeline: corrector.map { CorrectionPipeline(corrector: $0) },
            rescue: rescue
        )
        return (session, source, rescue)
    }

    private func runOneRound(_ session: DictationSession, _ source: FakeAudioSource) async throws {
        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()
    }

    @Test("注入失败时文字交给兜底，不再蒸发")
    func rescuesOnInjectionFailure() async throws {
        let (session, source, rescue) = makeSession(
            transcript: "今天下午三点开会", sinkError: TextSinkError.accessibilityDenied
        )

        try await runOneRound(session, source)

        #expect(rescue.rescued.count == 1)
        #expect(rescue.rescued.first?.text == "今天下午三点开会")
        #expect(rescue.rescued.first?.error as? TextSinkError == .accessibilityDenied)
    }

    @Test("目标应用改变时文字交给兜底")
    func rescuesOnTargetChange() async throws {
        var current = "com.apple.Notes"
        let (session, source, rescue) = makeSession(
            transcript: "今天下午三点开会", frontmost: { current }
        )

        try await session.start()
        source.emitSilence(seconds: 1)
        // M4 把「说完就切走」的窗口拉到 4–10 秒，这条从边缘情形变成日常动作。
        current = "com.tencent.xinWeChat"
        await session.finish()

        #expect(rescue.rescued.count == 1)
        #expect(rescue.rescued.first?.text == "今天下午三点开会")
    }

    @Test("注入成功时不触发兜底，不动用户的剪贴板")
    func doesNotRescueOnSuccess() async throws {
        let (session, source, rescue) = makeSession(transcript: "今天下午三点开会")

        try await runOneRound(session, source)

        #expect(rescue.rescued.isEmpty)
    }

    @Test("转写失败不走兜底：那条路留着音频可以重试，剪贴板里没东西可写")
    func doesNotRescueOnTranscribeFailure() async throws {
        let source = FakeAudioSource()
        let transcriber = FakeTranscriber()
        transcriber.transcribeError = TranscribeError.engineFailed("测试")
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }
        let rescue = SpyRescue()
        let session = DictationSession(
            audioSource: source,
            transcriber: transcriber,
            sink: SpySink(),
            targetGuard: guardian,
            rescue: rescue
        )

        try await runOneRound(session, source)

        #expect(rescue.rescued.isEmpty)
        #expect(session.retainedSampleCount > 0)
    }

    @Test("交给兜底的是校正之后的文本")
    func rescuesCorrectedText() async throws {
        let (session, source, rescue) = makeSession(
            transcript: "耀空气很重要",
            sinkError: TextSinkError.accessibilityDenied,
            corrector: StubCorrector(
                edits: [CorrectionEdit(original: "耀空气", replacement: "要空气")]
            )
        )

        try await runOneRound(session, source)

        // 剪贴板里必须是用户最终该拿到的那份，否则「救回来」救的是半成品。
        #expect(rescue.rescued.first?.text == "要空气很重要")
    }

    @Test("兜底跑完后会话仍回到 idle，下一次听写不受影响")
    func returnsToIdleAfterRescue() async throws {
        let (session, source, _) = makeSession(sinkError: TextSinkError.accessibilityDenied)

        try await runOneRound(session, source)

        #expect(session.state == .idle)
    }

    @Test("没挂兜底时行为与从前完全一致")
    func worksWithoutRescue() async throws {
        let source = FakeAudioSource()
        let transcriber = FakeTranscriber()
        transcriber.result = "今天下午三点开会"
        let sink = SpySink()
        sink.error = TextSinkError.accessibilityDenied
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }
        let session = DictationSession(
            audioSource: source, transcriber: transcriber, sink: sink, targetGuard: guardian
        )
        var errors: [Error] = []
        session.onError = { errors.append($0) }

        try await runOneRound(session, source)

        #expect(errors.count == 1)
        #expect(session.state == .idle)
    }
}
