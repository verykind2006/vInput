import Foundation

/// 一次听写会话的完整生命周期。
///
/// 只依赖 AudioSource、Transcriber、TextSink 三个 protocol，
/// 因此可以在不碰麦克风、模型和系统事件的情况下被完整测试。
@MainActor
final class DictationSession {
    enum State: Equatable {
        case idle
        case listening
        case transcribing
        case injecting
    }

    private(set) var state: State = .idle

    /// 状态变化回调，供 UI 更新。
    var onStateChange: ((State) -> Void)?
    /// 任一环节出错时回调。会话本身总会回到 idle。
    var onError: ((Error) -> Void)?
    /// 成功注入后回调，携带最终文本。
    var onText: ((String) -> Void)?

    private let audioSource: AudioSource
    private let transcriber: Transcriber
    private let sink: TextSink
    private let targetGuard: TargetAppGuard

    private var buffer = AudioBuffer(sampleRate: AudioFormat.sampleRate)
    private var targetToken: String?
    /// 转写失败时保留的音频，供 retry 使用。
    private var retainedSamples: [Float] = []

    /// 供测试断言保留的样本数。
    var retainedSampleCount: Int { retainedSamples.count }

    init(
        audioSource: AudioSource,
        transcriber: Transcriber,
        sink: TextSink,
        targetGuard: TargetAppGuard
    ) {
        self.audioSource = audioSource
        self.transcriber = transcriber
        self.sink = sink
        self.targetGuard = targetGuard

        audioSource.onFrame = { [weak self] samples in
            self?.buffer.append(samples)
        }
        audioSource.onStop = { [weak self] error in
            guard let self, let error else { return }
            // 采集过程中出错：终止会话，已收到的音频丢弃
            // （M1 不做部分转写；M3 蓝牙断连场景会重新审视）。
            self.transition(to: .idle)
            self.onError?(error)
        }
    }

    // MARK: - 生命周期

    /// 开始采集。重复调用会被忽略。
    func start() throws {
        guard state == .idle else { return }

        buffer.reset()
        retainedSamples = []
        targetToken = targetGuard.capture()

        try audioSource.start()
        transition(to: .listening)
    }

    /// 结束采集并走完转写与注入。
    func finish() async {
        guard state == .listening else { return }

        audioSource.stop()
        let samples = buffer.samples
        buffer.reset()

        await process(samples)
    }

    /// 用上一次失败时保留的音频重新走一遍。
    func retry() async {
        guard state == .idle, !retainedSamples.isEmpty else { return }
        let samples = retainedSamples
        await process(samples)
    }

    // MARK: - 处理

    private func process(_ samples: [Float]) async {
        guard !samples.isEmpty else {
            transition(to: .idle)
            return
        }

        transition(to: .transcribing)

        let text: String
        do {
            text = try await transcriber.transcribe(samples)
        } catch {
            // 规则二：保留音频，允许重试
            retainedSamples = samples
            transition(to: .idle)
            onError?(error)
            return
        }

        retainedSamples = []

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            transition(to: .idle)
            return
        }

        transition(to: .injecting)

        do {
            // 规则三：注入前确认目标应用没变
            try targetGuard.verify(targetToken)
            try sink.send(trimmed)
            onText?(trimmed)
        } catch {
            onError?(error)
        }

        transition(to: .idle)
    }

    private func transition(to newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }
}
