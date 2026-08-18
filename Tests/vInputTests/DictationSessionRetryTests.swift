import Testing
@testable import vInput

/// `canRetry` 是菜单栏重试入口的唯一判据（M6 ②）。
///
/// 判据留在会话里而不是 `AppModel` 里，是因为它必须与 `retry()` 自己的
/// 前置条件是同一份：两处各写一份的话，菜单项会出现「点得动但什么都不
/// 发生」或者「有东西可重试却是灰的」——后者等于入口不存在。
@Suite("重试入口的可用性")
@MainActor
struct DictationSessionRetryTests {
    private func makeSession(
        transcript: String = "转写结果"
    ) -> (DictationSession, FakeAudioSource, FakeTranscriber, SpySink) {
        let source = FakeAudioSource()
        let transcriber = FakeTranscriber()
        transcriber.result = transcript
        let sink = SpySink()
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }

        let session = DictationSession(
            audioSource: source, transcriber: transcriber, sink: sink, targetGuard: guardian
        )
        return (session, source, transcriber, sink)
    }

    @Test("什么都没发生时不可重试")
    func idleWithoutAudioCannotRetry() {
        let (session, _, _, _) = makeSession()
        #expect(!session.canRetry)
    }

    @Test("转写失败后可重试")
    func canRetryAfterTranscribeFailure() async throws {
        let (session, source, transcriber, _) = makeSession()
        transcriber.transcribeError = TranscribeError.engineFailed("boom")

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(session.canRetry)
    }

    @Test("空转写结果之后可重试")
    func canRetryAfterEmptyResult() async throws {
        let (session, source, _, _) = makeSession(transcript: "")

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(session.canRetry)
    }

    @Test("重试成功后状态被清掉")
    func retrySuccessClearsFlag() async throws {
        let (session, source, transcriber, _) = makeSession()
        transcriber.transcribeError = TranscribeError.engineFailed("boom")

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()
        #expect(session.canRetry)

        transcriber.transcribeError = nil
        transcriber.result = "第二次成功"
        await session.retry()

        // 不清掉的话菜单会一直亮着一个「重试」，而它重试的是上上次的音频。
        #expect(!session.canRetry)
    }

    @Test("重试再次失败时仍然可重试")
    func retryFailureKeepsFlag() async throws {
        let (session, source, transcriber, _) = makeSession()
        transcriber.transcribeError = TranscribeError.engineFailed("boom")

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()
        await session.retry()

        #expect(session.canRetry)
    }

    @Test("注入成功一轮后不可重试")
    func successfulRoundCannotRetry() async throws {
        let (session, source, _, _) = makeSession()

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(!session.canRetry)
    }

    @Test("注入失败不算可重试：文字已经进了剪贴板，重来一遍只会再失败一次")
    func injectionFailureIsNotRetryable() async throws {
        let (session, source, _, sink) = makeSession()
        sink.error = TextSinkError.accessibilityDenied

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(!session.canRetry)
    }

    @Test("取消会话后不可重试")
    func cancelClearsFlag() async throws {
        let (session, source, transcriber, _) = makeSession()
        transcriber.transcribeError = TranscribeError.engineFailed("boom")

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()
        #expect(session.canRetry)

        // 取消是用户主动放弃，语义上与转写失败保留音频相反。
        try await session.start()
        await session.cancel()

        #expect(!session.canRetry)
    }

    @Test("录音进行中不可重试")
    func listeningCannotRetry() async throws {
        let (session, source, transcriber, _) = makeSession()
        transcriber.transcribeError = TranscribeError.engineFailed("boom")

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()
        try await session.start()

        // retry() 自己在非 idle 时是空操作，菜单项也必须跟着灰掉，
        // 否则用户点了没反应。
        #expect(!session.canRetry)
    }
}
