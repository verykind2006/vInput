import Testing
@testable import vInput

@Suite("WhisperKitTranscriber")
struct WhisperKitTranscriberTests {
    @Test("过短的音频直接拒绝，不加载模型")
    func rejectsShortAudio() async {
        let transcriber = WhisperKitTranscriber()
        // 0.1 秒 = 1600 个样本，低于 0.3 秒门槛
        let samples = [Float](repeating: 0, count: 1_600)

        await #expect(throws: TranscribeError.audioTooShort) {
            try await transcriber.transcribe(samples)
        }
    }

    @Test("恰好达到门槛的音频会越过时长检查")
    func acceptsAudioAtThreshold() async {
        // 0.3 秒 = 4800 个样本。这里不断言转写结果——那需要真实模型；
        // 只断言它不再因时长被拒，即错误类型不是 audioTooShort。
        let transcriber = WhisperKitTranscriber(modelFolder: "/nonexistent")
        let samples = [Float](repeating: 0, count: 4_800)

        do {
            _ = try await transcriber.transcribe(samples)
        } catch let error as TranscribeError {
            #expect(error != .audioTooShort)
        } catch {
            Issue.record("预期 TranscribeError，实际 \(error)")
        }
    }
}

@Suite("WhisperKitTranscriber 预览能力")
struct WhisperKitTranscriberPreviewTests {
    @Test("模型未加载时不产出预览引擎")
    func noPreviewBeforeModelLoads() async {
        // 指向不存在的目录，prepare 必然失败，pipe 保持 nil
        let transcriber = WhisperKitTranscriber(modelFolder: "/nonexistent/model")
        let processor = SourceBackedAudioProcessor()

        let engine = await transcriber.makePreviewEngine(processor: processor)

        #expect(engine == nil)
    }
}
