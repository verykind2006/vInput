import Testing
import WhisperKit
@testable import vInput

@Suite("StreamingPreviewEngine 状态转换")
struct StreamingPreviewEngineTests {
    private func segment(_ text: String, id: Int = 0) -> TranscriptionSegment {
        TranscriptionSegment(
            id: id, seek: 0, start: 0, end: 1, text: text,
            tokens: [], tokenLogProbs: [], temperature: 0,
            avgLogprob: 0, compressionRatio: 1, noSpeechProb: 0
        )
    }

    @Test("已确认与未确认分别拼接")
    func splitsConfirmedAndUnconfirmed() {
        let preview = StreamingPreviewEngine.makePreview(
            confirmedSegments: [segment("已经确定的"), segment("这一段")],
            unconfirmedSegments: [segment("还可能改")],
            bufferEnergy: []
        )

        #expect(preview.confirmed == "已经确定的这一段")
        #expect(preview.unconfirmed == "还可能改")
    }

    @Test("能量数据原样带出")
    func carriesEnergy() {
        let preview = StreamingPreviewEngine.makePreview(
            confirmedSegments: [],
            unconfirmedSegments: [],
            bufferEnergy: [0.1, 0.5, 0.9]
        )

        #expect(preview.energy == [0.1, 0.5, 0.9])
    }

    @Test("预览文本同样转成简体")
    func convertsToSimplified() {
        let preview = StreamingPreviewEngine.makePreview(
            confirmedSegments: [segment("測試繁體")],
            unconfirmedSegments: [],
            bufferEnergy: []
        )

        // 与最终文本保持一致，否则松手瞬间会看到字形跳变
        #expect(preview.confirmed == "测试繁体")
    }

    @Test("空状态产出空预览")
    func emptyStateYieldsEmptyPreview() {
        let preview = StreamingPreviewEngine.makePreview(
            confirmedSegments: [],
            unconfirmedSegments: [],
            bufferEnergy: []
        )

        #expect(preview.confirmed.isEmpty)
        #expect(preview.unconfirmed.isEmpty)
        #expect(preview.energy.isEmpty)
    }
}

@Suite("特殊标记剥除")
struct SpecialTokenStrippingTests {
    @Test("剥除语言与时间戳标记")
    func stripsLanguageAndTimestamps() {
        let raw = "<|zh|><|0.00|>帮我改一下依赖数组<|5.14|>"
        #expect(TranscriptCleaner.stripSpecialTokens(raw) == "帮我改一下依赖数组")
    }

    @Test("剥除任务与结束标记")
    func stripsTaskAndEndTokens() {
        let raw = "<|startoftranscript|><|transcribe|>正文<|endoftext|>"
        #expect(TranscriptCleaner.stripSpecialTokens(raw) == "正文")
    }

    @Test("普通文本不受影响")
    func plainTextUnchanged() {
        let text = "把 useEffect 里的依赖数组改一下"
        #expect(TranscriptCleaner.stripSpecialTokens(text) == text)
    }

    @Test("用户真说的尖括号内容不被误删")
    func keepsGenuineAngleBrackets() {
        // 只匹配 <|...|> 这种形式，普通尖括号保留
        let text = "把 <div> 改成 <span>"
        #expect(TranscriptCleaner.stripSpecialTokens(text) == text)
    }

    @Test("空字符串安全")
    func emptyIsSafe() {
        #expect(TranscriptCleaner.stripSpecialTokens("") == "")
    }
}


/// 记录启停调用的流式转写器替身。
final class FakeStreamTranscriber: StreamTranscribing, @unchecked Sendable {
    let id: Int
    private let counter: OrderCounter

    init(id: Int, counter: OrderCounter) {
        self.id = id
        self.counter = counter
    }

    func startStreamTranscription() async throws {
        // 真实实现会阻塞在推理循环里直到 stop；这里立即返回即可
    }

    func stopStreamTranscription() async {
        _ = counter.next()
    }
}

@Suite("每次会话新建转写器")
struct FreshTranscriberPerSessionTests {

    private func makeEngine() -> (StreamingPreviewEngine, () -> Int) {
        let counter = OrderCounter()
        let builtIDs = OrderCounter()
        let engine = StreamingPreviewEngine(
            processor: SourceBackedAudioProcessor()
        ) { _ in
            FakeStreamTranscriber(id: builtIDs.next(), counter: counter)
        }
        return (engine, { builtIDs.next() - 1 })
    }

    @Test("两次会话构造两个转写器，不复用同一个")
    func eachSessionBuildsFreshTranscriber() async throws {
        // AudioStreamTranscriber 的 state 私有且无重置入口。复用同一个实例
        // 会让上一轮的 confirmedSegments 残留到下一轮——真机复现过：第二次
        // 录音时 HUD 显示的还是上次说的话；同时 lastConfirmedSegmentEndSeconds
        // 会被当作 clipTimestamps 裁掉新一轮音频的开头。
        let (engine, _) = makeEngine()

        try await engine.start()
        await engine.stop()
        #expect(engine.builtTranscriberCount == 1)

        try await engine.start()
        await engine.stop()
        #expect(engine.builtTranscriberCount == 2)
    }

    @Test("start 时先推一次空预览，清掉上一轮残留")
    func startEmitsEmptyPreview() async throws {
        let (engine, _) = makeEngine()
        let received = PreviewBox()
        engine.onUpdate = { received.value = $0 }

        try await engine.start()

        // 新会话开头不该闪一下旧内容
        #expect(received.value == PreviewText.empty)
        await engine.stop()
    }

    @Test("stop 后释放当前转写器，不残留引用")
    func stopReleasesTranscriber() async throws {
        let (engine, _) = makeEngine()

        try await engine.start()
        await engine.stop()
        // 再次 stop 应是安全的空操作（当前实例已被取走）
        await engine.stop()
    }
}
