import Testing
@testable import vInput

@Suite("DictationSession 预览")
@MainActor
struct DictationSessionPreviewTests {

    private func makeSession(
        transcript: String = "最终文本",
        preview: FakePreviewEngine = FakePreviewEngine()
    ) -> (DictationSession, FakeAudioSource, FakeTranscriber, SpySink, FakePreviewEngine) {
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
            previewEngine: preview
        )
        return (session, source, transcriber, sink, preview)
    }

    // MARK: - 生命周期

    @Test("start 会启动预览")
    func startBeginsPreview() async throws {
        let (session, _, _, _, preview) = makeSession()

        try await session.start()

        #expect(preview.startCallCount == 1)
    }

    @Test("预览文本经 onPreview 推给上层")
    func previewIsForwarded() async throws {
        let (session, _, _, _, preview) = makeSession()
        var received: PreviewText?
        session.onPreview = { received = $0 }

        try await session.start()
        preview.emit(confirmed: "已确认", unconfirmed: "未确认")
        // onPreview 经由 Task { @MainActor } 转发，让出一次让它执行
        try await Task.sleep(for: .milliseconds(20))

        #expect(received?.confirmed == "已确认")
        #expect(received?.unconfirmed == "未确认")
    }

    @Test("finish 时先停预览再转写")
    func stopsPreviewBeforeTranscribing() async throws {
        FakePreviewEngine.orderCounter.reset()
        let (session, source, transcriber, _, preview) = makeSession()

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        // 共享解码器实例，重叠会产生数据竞争。停在前是硬要求。
        //
        // 必须比较**先后顺序**而非调用次数：只断言两者各发生一次的话，
        // 把 stop 挪到 transcribe 之后测试照样通过——这条回归测试就白写了。
        let stopOrder = try #require(preview.stopOrder)
        let transcribeOrder = try #require(transcriber.firstTranscribeOrder)
        #expect(stopOrder < transcribeOrder)
    }

    @Test("完整一轮后文本仍然正常注入")
    func fullRoundTripStillWorks() async throws {
        let (session, source, _, sink, _) = makeSession(transcript: "你好世界")

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(sink.received == ["你好世界"])
        #expect(session.state == .idle)
    }

    // MARK: - 规则二：预览失败不得影响主路径

    @Test("预览启动失败时录音照常开始")
    func previewStartFailureDoesNotBlockRecording() async throws {
        let preview = FakePreviewEngine()
        preview.startError = PreviewEngineError.notReady
        let (session, source, _, sink, _) = makeSession(preview: preview)

        try await session.start()

        #expect(session.state == .listening)

        source.emitSilence(seconds: 1)
        await session.finish()

        // 关键：主路径完全不受影响
        #expect(sink.received == ["最终文本"])
    }

    @Test("没有预览引擎时一切照常")
    func worksWithoutPreviewEngine() async throws {
        let source = FakeAudioSource()
        let transcriber = FakeTranscriber()
        transcriber.result = "无预览也能用"
        let sink = SpySink()
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }
        let session = DictationSession(
            audioSource: source,
            transcriber: transcriber,
            sink: sink,
            targetGuard: guardian,
            previewEngine: nil
        )

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(sink.received == ["无预览也能用"])
    }

    @Test("预览启动失败不会上报为会话错误")
    func previewFailureIsNotSessionError() async throws {
        let preview = FakePreviewEngine()
        preview.startError = PreviewEngineError.streamFailed("boom")
        let (session, _, _, _, _) = makeSession(preview: preview)
        var reported: Error?
        session.onError = { reported = $0 }

        try await session.start()

        // 预览是锦上添花，其失败不该让用户看到错误状态
        #expect(reported == nil)
        #expect(session.state == .listening)
    }

    // MARK: - cancel()

    @Test("cancel 不注入任何文字")
    func cancelInjectsNothing() async throws {
        let (session, source, transcriber, sink, _) = makeSession()

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.cancel()

        #expect(sink.received.isEmpty)
        #expect(transcriber.receivedSamples.isEmpty)
        #expect(session.state == .idle)
    }

    @Test("cancel 会停止预览")
    func cancelStopsPreview() async throws {
        let (session, source, _, _, preview) = makeSession()

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.cancel()

        #expect(preview.stopCallCount == 1)
    }

    @Test("cancel 清空保留音频")
    func cancelClearsRetainedAudio() async throws {
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
            targetGuard: guardian,
            previewEngine: FakePreviewEngine()
        )

        // 先制造一次转写失败，让音频被保留
        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()
        #expect(session.retainedSampleCount == 16_000)

        // 再开一轮然后取消——取消是用户主动放弃，不该留存
        try await session.start()
        source.emitSilence(seconds: 1)
        await session.cancel()

        #expect(session.retainedSampleCount == 0)
    }

    @Test("idle 状态下 cancel 是空操作")
    func cancelWhenIdleIsNoop() async {
        let (session, _, _, _, preview) = makeSession()

        await session.cancel()

        #expect(session.state == .idle)
        #expect(preview.stopCallCount == 0)
    }
}
