import Testing
@testable import vInput

@Suite("DictationSession")
@MainActor
struct DictationSessionTests {

    /// 组装一套全替身的会话。
    private func makeSession(
        transcript: String = "转写结果",
        frontmost: @escaping () -> String? = { "com.apple.Notes" }
    ) -> (DictationSession, FakeAudioSource, FakeTranscriber, SpySink) {
        let source = FakeAudioSource()
        let transcriber = FakeTranscriber()
        transcriber.result = transcript
        let sink = SpySink()
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = frontmost

        let session = DictationSession(
            audioSource: source,
            transcriber: transcriber,
            sink: sink,
            targetGuard: guardian
        )
        return (session, source, transcriber, sink)
    }

    // MARK: - 正常路径

    @Test("初始状态为 idle")
    func startsIdle() {
        let (session, _, _, _) = makeSession()
        #expect(session.state == .idle)
    }

    @Test("start 后进入 listening 并启动音频源")
    func startBeginsListening() async throws {
        let (session, source, _, _) = makeSession()

        try await session.start()

        #expect(session.state == .listening)
        #expect(source.startCallCount == 1)
    }

    @Test("完整一轮后文本被送到 sink 且回到 idle")
    func fullRoundTripDeliversText() async throws {
        let (session, source, _, sink) = makeSession(transcript: "你好世界")

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(sink.received == ["你好世界"])
        #expect(session.state == .idle)
    }

    @Test("转写收到的样本数与采集到的一致")
    func transcriberReceivesAllSamples() async throws {
        let (session, source, transcriber, _) = makeSession()

        try await session.start()
        source.emit([0.1, 0.2, 0.3])
        source.emit([0.4, 0.5])
        await session.finish()

        #expect(transcriber.receivedSamples.count == 1)
        #expect(transcriber.receivedSamples[0] == [0.1, 0.2, 0.3, 0.4, 0.5])
    }

    @Test("空转写结果不触发注入")
    func emptyTranscriptSkipsInjection() async throws {
        let (session, source, _, sink) = makeSession(transcript: "")

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(sink.received.isEmpty)
        #expect(session.state == .idle)
    }

    @Test("只含空白的转写结果同样不触发注入")
    func whitespaceOnlyTranscriptSkipsInjection() async throws {
        let (session, source, _, sink) = makeSession(transcript: "  \n  ")

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(sink.received.isEmpty)
    }

    @Test("状态变化按顺序上报")
    func stateTransitionsAreReported() async throws {
        let (session, source, _, _) = makeSession()
        var observed: [DictationSession.State] = []
        session.onStateChange = { observed.append($0) }

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(observed == [.listening, .transcribing, .injecting, .idle])
    }

    // MARK: - 规则二：永不丢字

    @Test("转写失败时保留音频并报错，状态回到 idle")
    func transcriptionFailureKeepsAudio() async throws {
        let source = FakeAudioSource()
        let transcriber = FakeTranscriber()
        transcriber.transcribeError = TranscribeError.engineFailed("boom")
        let sink = SpySink()
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }
        let session = DictationSession(
            audioSource: source,
            transcriber: transcriber,
            sink: sink,
            targetGuard: guardian
        )
        var reported: Error?
        session.onError = { reported = $0 }

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(sink.received.isEmpty)
        #expect(session.state == .idle)
        #expect(reported != nil)
        // 音频保留，供重试
        #expect(session.retainedSampleCount == 16_000)
    }

    @Test("retry 用保留的音频重新走一遍")
    func retryReusesRetainedAudio() async throws {
        let source = FakeAudioSource()
        let transcriber = FakeTranscriber()
        transcriber.transcribeError = TranscribeError.engineFailed("boom")
        let sink = SpySink()
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }
        let session = DictationSession(
            audioSource: source,
            transcriber: transcriber,
            sink: sink,
            targetGuard: guardian
        )

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        // 修好引擎再重试
        transcriber.transcribeError = nil
        transcriber.result = "第二次成功"
        await session.retry()

        #expect(sink.received == ["第二次成功"])
    }

    @Test("成功一轮后不残留音频")
    func successClearsRetainedAudio() async throws {
        let (session, source, _, _) = makeSession()

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(session.retainedSampleCount == 0)
    }

    @Test("没有保留音频时 retry 是空操作")
    func retryWithoutRetainedAudioIsNoop() async {
        let (session, _, transcriber, _) = makeSession()

        await session.retry()

        #expect(transcriber.receivedSamples.isEmpty)
    }

    @Test("注入失败时报错但不崩溃")
    func injectionFailureIsReported() async throws {
        let (session, source, _, sink) = makeSession()
        sink.error = TextSinkError.accessibilityDenied
        var reported: Error?
        session.onError = { reported = $0 }

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(reported != nil)
        #expect(session.state == .idle)
    }

    @Test("音频源报错时终止会话并上报")
    func audioSourceFailureEndsSession() async throws {
        let (session, source, _, _) = makeSession()
        var reported: Error?
        session.onError = { reported = $0 }

        try await session.start()
        source.fail(with: AudioSourceError.engineFailedToStart("device lost"))

        #expect(session.state == .idle)
        #expect(reported != nil)
    }

    @Test("音频源启动失败时状态不进入 listening")
    func startFailureStaysIdle() async {
        let (session, source, _, _) = makeSession()
        source.startError = AudioSourceError.microphonePermissionDenied

        await #expect(throws: AudioSourceError.microphonePermissionDenied) {
            try await session.start()
        }
        #expect(session.state == .idle)
    }

    // MARK: - 规则三：目标应用校验

    @Test("目标应用改变时不注入并上报")
    func targetChangeBlocksInjection() async throws {
        var current = "com.apple.Notes"
        let (session, source, _, sink) = makeSession(frontmost: { current })
        var reported: Error?
        session.onError = { reported = $0 }

        try await session.start()
        source.emitSilence(seconds: 1)
        current = "com.tencent.xinWeChat"
        await session.finish()

        #expect(sink.received.isEmpty)
        #expect(reported != nil)
    }

    // MARK: - 重入保护

    @Test("listening 期间再次 start 不产生第二个会话")
    func doubleStartIsIgnored() async throws {
        let (session, source, _, _) = makeSession()

        try await session.start()
        try await session.start()

        #expect(source.startCallCount == 1)
    }

    @Test("idle 状态下 finish 是空操作")
    func finishWhenIdleIsNoop() async {
        let (session, _, transcriber, _) = makeSession()

        await session.finish()

        #expect(transcriber.receivedSamples.isEmpty)
        #expect(session.state == .idle)
    }

    @Test("没有采集到样本时直接回到 idle")
    func noSamplesReturnsToIdle() async throws {
        let (session, _, transcriber, sink) = makeSession()

        try await session.start()
        await session.finish()

        #expect(transcriber.receivedSamples.isEmpty)
        #expect(sink.received.isEmpty)
        #expect(session.state == .idle)
    }

    // MARK: - 回归：审查发现的三个缺陷

    @Test("启动失败不得丢掉上一次保留的音频")
    func failedStartPreservesRetainedAudio() async throws {
        let source = FakeAudioSource()
        let transcriber = FakeTranscriber()
        transcriber.transcribeError = TranscribeError.engineFailed("boom")
        let sink = SpySink()
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }
        let session = DictationSession(
            audioSource: source,
            transcriber: transcriber,
            sink: sink,
            targetGuard: guardian
        )

        // 第一轮转写失败，音频被保留
        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()
        #expect(session.retainedSampleCount == 16_000)

        // 第二轮启动失败（麦克风被占用等），这与上一轮内容毫无关系
        source.startError = AudioSourceError.microphonePermissionDenied
        await #expect(throws: AudioSourceError.microphonePermissionDenied) {
            try await session.start()
        }

        // 规则二：上一轮的音频不能因此丢失，retry 仍须可用
        #expect(session.retainedSampleCount == 16_000)
        transcriber.transcribeError = nil
        transcriber.result = "找回来了"
        await session.retry()
        #expect(sink.received == ["找回来了"])
    }

    @Test("转写期间音频源报错不得中断已在处理的内容")
    func audioErrorDuringTranscriptionDoesNotAbort() async throws {
        let source = FakeAudioSource()
        let transcriber = FakeTranscriber()
        transcriber.result = "这段话必须落地"
        let sink = SpySink()
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }
        let session = DictationSession(
            audioSource: source,
            transcriber: transcriber,
            sink: sink,
            targetGuard: guardian
        )
        var reported: Error?
        session.onError = { reported = $0 }

        // 给转写制造一个挂起窗口，好让错误在 .transcribing 期间到达。
        transcriber.delay = .milliseconds(80)

        try await session.start()
        source.emitSilence(seconds: 1)

        let finishTask = Task { await session.finish() }
        // 等 finish() 真正进入 .transcribing 并挂在转写上
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.state == .transcribing)

        // 模拟设备在音频已采集完、正在转写时才报错
        // （M3 蓝牙断连的真实时序）。此时音频已在手，中止就是丢字。
        source.fail(with: AudioSourceError.engineFailedToStart("device lost"))
        await finishTask.value

        #expect(sink.received == ["这段话必须落地"])
        #expect(reported == nil)
        #expect(session.state == .idle)
    }

    @Test("终态回调触发时状态已回到 idle，可直接开始下一轮")
    func callbacksFireAfterReturningToIdle() async throws {
        let (session, source, _, sink) = makeSession(transcript: "第一段")
        var stateAtCallback: DictationSession.State?
        session.onText = { _ in stateAtCallback = session.state }

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(stateAtCallback == .idle)
        #expect(sink.received == ["第一段"])

        // 状态已是 idle，调用方可以在回调里直接启动下一轮
        try await session.start()
        #expect(session.state == .listening)
    }

    @Test("注入失败的回调触发时状态同样已回到 idle")
    func errorCallbackAlsoFiresAtIdle() async throws {
        let (session, source, _, sink) = makeSession()
        sink.error = TextSinkError.accessibilityDenied
        var stateAtCallback: DictationSession.State?
        session.onError = { _ in stateAtCallback = session.state }

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(stateAtCallback == .idle)
    }

    @Test("第二轮会话不会带入上一轮的音频")
    func secondSessionStartsClean() async throws {
        let (session, source, transcriber, _) = makeSession()

        try await session.start()
        source.emit([0.1, 0.2])
        await session.finish()

        try await session.start()
        source.emit([0.9])
        await session.finish()

        #expect(transcriber.receivedSamples.count == 2)
        #expect(transcriber.receivedSamples[1] == [0.9])
    }
}
