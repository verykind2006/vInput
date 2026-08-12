import Foundation
import WhisperKit

/// 把 WhisperKit 的 `AudioStreamTranscriber` 适配成 `PreviewEngine`。
///
/// 复用 WhisperKit 的流式引擎而非自己写：流式转写的难点不是定时调用，
/// 而是窗口边界的文本拼接去重、以及判断哪部分文本已稳定。自己实现
/// 大概率会在中文分词边界上出问题。
final class StreamingPreviewEngine: PreviewEngine, @unchecked Sendable {
    var onUpdate: (@Sendable (PreviewText) -> Void)?

    private let transcriber: AudioStreamTranscriber
    private let processor: SourceBackedAudioProcessor
    private let lock = NSLock()
    private var streamTask: Task<Void, Error>?

    init(
        audioEncoder: any AudioEncoding,
        featureExtractor: any FeatureExtracting,
        segmentSeeker: any SegmentSeeking,
        textDecoder: any TextDecoding,
        tokenizer: any WhisperTokenizer,
        processor: SourceBackedAudioProcessor,
        decodingOptions: DecodingOptions
    ) {
        self.processor = processor

        // 回调要在 transcriber 构造时传入，而此时 self 还不可用，
        // 因此先建一个盒子，构造完再把真正的转发函数放进去。
        let box = CallbackBox()
        self.transcriber = AudioStreamTranscriber(
            audioEncoder: audioEncoder,
            featureExtractor: featureExtractor,
            segmentSeeker: segmentSeeker,
            textDecoder: textDecoder,
            tokenizer: tokenizer,
            audioProcessor: processor,
            decodingOptions: decodingOptions,
            stateChangeCallback: { _, newState in
                box.handler?(newState)
            }
        )
        box.handler = { [weak self] state in
            guard let self else { return }
            self.onUpdate?(Self.makePreview(
                confirmedSegments: state.confirmedSegments,
                unconfirmedSegments: state.unconfirmedSegments,
                bufferEnergy: state.bufferEnergy
            ))
        }
    }

    /// 把 WhisperKit 的流式状态转换成 HUD 需要的形状。
    ///
    /// 接收拆分后的字段而非整个 `AudioStreamTranscriber.State`：该类型
    /// 在 WhisperKit 里没有公开的构造器（合成的默认 `init()` 按 Swift
    /// 的访问控制规则是 internal），测试所在的模块无法造出一个 State
    /// 实例。拆开参数后，转换逻辑本身可以用普通值直接测试。
    static func makePreview(
        confirmedSegments: [TranscriptionSegment],
        unconfirmedSegments: [TranscriptionSegment],
        bufferEnergy: [Float]
    ) -> PreviewText {
        let confirmed = confirmedSegments.map(\.text).joined()
        let unconfirmed = unconfirmedSegments.map(\.text).joined()
        return PreviewText(
            confirmed: ChineseScript.toSimplified(confirmed.trimmingCharacters(in: .whitespaces)),
            unconfirmed: ChineseScript.toSimplified(unconfirmed.trimmingCharacters(in: .whitespaces)),
            energy: bufferEnergy
        )
    }

    func start() async throws {
        processor.reset()
        let task = Task { [transcriber] in
            try await transcriber.startStreamTranscription()
        }
        setStreamTask(task)
    }

    /// 停止并**等待推理循环真正退出**。
    ///
    /// `stopStreamTranscription()` 只把 isRecording 置 false，循环会在当前
    /// 这轮转写跑完之后才退出。调用方紧接着就要发起全量转写，而两者共享
    /// 同一套解码器实例——不等就会撞上数据竞争。
    func stop() async {
        await transcriber.stopStreamTranscription()

        let task = takeStreamTask()
        _ = await task?.result
    }

    // NSLock 的 lock()/unlock() 标了 noasync：直接写在 async 函数体里会
    // 触发警告（担心持锁跨越挂起点）。这两个同步小函数把加锁/解锁都锁在
    // 同一个非 async 调用帧内完成，规避该诊断，同时锁的持有时间本就极短。
    private func setStreamTask(_ task: Task<Void, Error>?) {
        lock.lock(); defer { lock.unlock() }
        streamTask = task
    }

    private func takeStreamTask() -> Task<Void, Error>? {
        lock.lock(); defer { lock.unlock() }
        let task = streamTask
        streamTask = nil
        return task
    }
}

/// 承载回调的盒子。构造 AudioStreamTranscriber 时 self 尚不可用，
/// 需要一个中间层把回调转发到构造完成后的实例。
private final class CallbackBox: @unchecked Sendable {
    var handler: (@Sendable (AudioStreamTranscriber.State) -> Void)?
}
