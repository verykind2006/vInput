import WhisperKit
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

@Suite("结尾无语音分段过滤")
struct TrailingNonSpeechFilterTests {
    private func segment(_ text: String, noSpeech: Float, id: Int = 0) -> TranscriptionSegment {
        TranscriptionSegment(
            id: id, seek: 0, start: 0, end: 1, text: text,
            tokens: [], tokenLogProbs: [], temperature: 0,
            avgLogprob: 0, compressionRatio: 1, noSpeechProb: noSpeech
        )
    }

    @Test("剥掉结尾判为无语音的分段")
    func dropsTrailingHallucination() {
        let segments = [
            segment("今天下午三点开会", noSpeech: 0.05),
            segment("谢谢大家", noSpeech: 0.92),
        ]
        #expect(WhisperKitTranscriber.textDroppingTrailingNonSpeech(segments) == "今天下午三点开会")
    }

    @Test("连续多段无语音一并剥掉")
    func dropsMultipleTrailing() {
        let segments = [
            segment("正文", noSpeech: 0.1),
            segment("谢谢观看", noSpeech: 0.8),
            segment("请点赞订阅", noSpeech: 0.95),
        ]
        #expect(WhisperKitTranscriber.textDroppingTrailingNonSpeech(segments) == "正文")
    }

    @Test("句子中间被判无语音的分段不动")
    func keepsMidSentenceSegments() {
        // 中间某段被判无语音多半是模型判断失误，删掉就是真的丢字
        let segments = [
            segment("前半句", noSpeech: 0.1),
            segment("中间这段", noSpeech: 0.9),
            segment("后半句", noSpeech: 0.1),
        ]
        #expect(WhisperKitTranscriber.textDroppingTrailingNonSpeech(segments) == "前半句中间这段后半句")
    }

    @Test("全部是语音时一段不少")
    func keepsAllWhenAllSpeech() {
        let segments = [
            segment("第一段", noSpeech: 0.1),
            segment("第二段", noSpeech: 0.2),
        ]
        #expect(WhisperKitTranscriber.textDroppingTrailingNonSpeech(segments) == "第一段第二段")
    }

    @Test("恰好等于阈值的分段被剥掉")
    func atThresholdIsDropped() {
        let segments = [
            segment("正文", noSpeech: 0.1),
            segment("套话", noSpeech: WhisperKitTranscriber.nonSpeechProbability),
        ]
        #expect(WhisperKitTranscriber.textDroppingTrailingNonSpeech(segments) == "正文")
    }

    @Test("全部被判无语音时返回空串而非崩溃")
    func allNonSpeechYieldsEmpty() {
        let segments = [segment("谢谢观看", noSpeech: 0.99)]
        #expect(WhisperKitTranscriber.textDroppingTrailingNonSpeech(segments).isEmpty)
    }

    @Test("空分段安全")
    func emptySegmentsAreSafe() {
        #expect(WhisperKitTranscriber.textDroppingTrailingNonSpeech([]).isEmpty)
    }
}
