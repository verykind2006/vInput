import Foundation
import WhisperKit

/// 流式转写器中本引擎实际用到的那两个动作。
///
/// 抽出协议只为一个目的：让「每次会话都新建转写器」这条不变量能被测试。
/// `AudioStreamTranscriber` 是具体 actor，构造它需要一整套已加载的
/// WhisperKit 组件，测试环境拿不到。
protocol StreamTranscribing: Sendable {
    func startStreamTranscription() async throws
    func stopStreamTranscription() async
}

extension AudioStreamTranscriber: StreamTranscribing {}

/// 把 WhisperKit 的 `AudioStreamTranscriber` 适配成 `PreviewEngine`。
///
/// 复用 WhisperKit 的流式引擎而非自己写：流式转写的难点不是定时调用，
/// 而是窗口边界的文本拼接去重、以及判断哪部分文本已稳定。自己实现
/// 大概率会在中文分词边界上出问题。
final class StreamingPreviewEngine: PreviewEngine, @unchecked Sendable {
    var onUpdate: (@Sendable (PreviewText) -> Void)?

    /// 构造一个全新的流式转写器。**每次会话都要新建。**
    ///
    /// `AudioStreamTranscriber` 的 `state` 是私有的，没有任何重置入口。
    /// 复用同一个实例会让上一轮的状态渗进下一轮：
    ///
    /// - `confirmedSegments` 残留 → 新会话一开始就显示上次说的话
    /// - `lastConfirmedSegmentEndSeconds` 残留 → 它被当作 `clipTimestamps`
    ///   传给解码器，**新一轮音频的开头会被直接裁掉**，表现为迟迟不出字、
    ///   出来也只有后半截
    ///
    /// 真机复现过前者，后者是读源码时发现的同源问题。
    private let makeTranscriber: (CallbackBox) -> any StreamTranscribing
    private let processor: SourceBackedAudioProcessor
    private let lock = NSLock()
    private var streamTask: Task<Void, Error>?
    private var transcriber: (any StreamTranscribing)?
    /// 已构造的转写器个数，供测试断言「每次会话都新建」。
    private(set) var builtTranscriberCount = 0

    convenience init(
        audioEncoder: any AudioEncoding,
        featureExtractor: any FeatureExtracting,
        segmentSeeker: any SegmentSeeking,
        textDecoder: any TextDecoding,
        tokenizer: any WhisperTokenizer,
        processor: SourceBackedAudioProcessor,
        decodingOptions: DecodingOptions
    ) {
        self.init(processor: processor) { box in
            AudioStreamTranscriber(
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
        }
    }

    /// 工厂可注入，便于测试「每次 start 都新建转写器」这条不变量。
    init(
        processor: SourceBackedAudioProcessor,
        makeTranscriber: @escaping (CallbackBox) -> any StreamTranscribing
    ) {
        self.processor = processor
        self.makeTranscriber = makeTranscriber
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
        let confirmed = TranscriptCleaner.stripSpecialTokens(confirmedSegments.map(\.text).joined())
        let unconfirmed = TranscriptCleaner.stripSpecialTokens(unconfirmedSegments.map(\.text).joined())
        return PreviewText(
            confirmed: ChineseScript.toSimplified(confirmed.trimmingCharacters(in: .whitespaces)),
            unconfirmed: ChineseScript.toSimplified(unconfirmed.trimmingCharacters(in: .whitespaces)),
            energy: bufferEnergy
        )
    }

    func start() async throws {
        processor.reset()

        // 每次会话新建转写器，杜绝上一轮状态渗入。见 makeTranscriber 的注释。
        let box = CallbackBox()
        box.handler = { [weak self] state in
            guard let self else { return }
            self.onUpdate?(Self.makePreview(
                confirmedSegments: state.confirmedSegments,
                unconfirmedSegments: state.unconfirmedSegments,
                bufferEnergy: state.bufferEnergy
            ))
        }
        let fresh = makeTranscriber(box)
        setTranscriber(fresh)

        // 上一轮的残留文字先清掉，否则新会话开头会闪一下旧内容。
        onUpdate?(.empty)

        setStreamTask(Task { try await fresh.startStreamTranscription() })
    }

    /// 停止并**等待推理循环真正退出**。
    ///
    /// `stopStreamTranscription()` 只把 isRecording 置 false，循环会在当前
    /// 这轮转写跑完之后才退出。调用方紧接着就要发起全量转写，而两者共享
    /// 同一套解码器实例——不等就会撞上数据竞争。
    func stop() async {
        let current = takeTranscriber()
        await current?.stopStreamTranscription()

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

    private func setTranscriber(_ next: any StreamTranscribing) {
        lock.lock(); defer { lock.unlock() }
        transcriber = next
        builtTranscriberCount += 1
    }

    private func takeTranscriber() -> (any StreamTranscribing)? {
        lock.lock(); defer { lock.unlock() }
        let current = transcriber
        transcriber = nil
        return current
    }
}

/// 承载状态回调的盒子。
///
/// AudioStreamTranscriber 要求在构造时传入回调，而那时引擎自身尚未
/// 完成初始化，需要一个中间层转发。工厂注入时也用它传递回调。
final class CallbackBox: @unchecked Sendable {
    var handler: (@Sendable (AudioStreamTranscriber.State) -> Void)?
}
