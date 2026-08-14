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
        /// 转写已完成，正在校正。HUD 据此显示「正在校正」。
        case correcting
        case injecting
    }

    private(set) var state: State = .idle

    /// 状态变化回调，供 UI 更新。
    var onStateChange: ((State) -> Void)?
    /// 任一环节出错时回调。会话本身总会回到 idle。
    var onError: ((Error) -> Void)?
    /// 成功注入后回调，携带最终文本。
    var onText: ((String) -> Void)?
    /// 预览更新时回调，供 HUD 显示。
    var onPreview: ((PreviewText) -> Void)?

    private let audioSource: AudioSource
    private let transcriber: Transcriber
    private let sink: TextSink
    private let targetGuard: TargetAppGuard
    /// 流式预览引擎。可为 nil——预览是锦上添花，缺席不影响主路径。
    private var previewEngine: PreviewEngine?
    /// 校正流水线。可为 nil——校正是锦上添花，缺席不影响主路径。
    ///
    /// 是 `var` 而非 `let`：用户可在菜单栏随时开关校正、更换模型，
    /// 而本仓库不重建会话（`AppModel` 里的 session 只构造一次，
    /// 换 Whisper 模型走的是 `SwitchableTranscriber.switchTo`）。
    private var correctionPipeline: CorrectionPipeline?

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
        targetGuard: TargetAppGuard,
        previewEngine: PreviewEngine? = nil,
        correctionPipeline: CorrectionPipeline? = nil
    ) {
        self.audioSource = audioSource
        self.transcriber = transcriber
        self.sink = sink
        self.targetGuard = targetGuard
        self.previewEngine = previewEngine
        self.correctionPipeline = correctionPipeline

        audioSource.onFrame = { [weak self] samples in
            self?.buffer.append(samples)
        }
        audioSource.onStop = { [weak self] error in
            guard let self, let error else { return }
            // 只在仍在采集时才中止。若已经进入转写或注入阶段，
            // 音频已经完整拿到手了，此时中止反而是在丢字——那正是
            // 规则二要防的事。M3 的蓝牙源会在断连时异步报错，
            // 这条 guard 是它的正确性前提。
            guard self.state == .listening else { return }
            self.transition(to: .idle)
            self.onError?(error)
        }

        bindPreview(previewEngine)
    }

    /// 把预览引擎的更新转发到 `onPreview`。
    private func bindPreview(_ engine: PreviewEngine?) {
        engine?.onUpdate = { [weak self] preview in
            Task { @MainActor [weak self] in
                self?.onPreview?(preview)
            }
        }
    }

    // MARK: - 生命周期

    /// 开始采集。重复调用会被忽略。
    func start() async throws {
        guard state == .idle else { return }

        buffer.reset()
        targetToken = targetGuard.capture()

        // 先启动音频源，成功之后才丢弃上一次保留的音频。
        // 顺序反过来的话，一次失败的启动会把上次转写失败保留下来、
        // 本可 retry() 找回的内容静默吞掉，违反规则二。
        try audioSource.start()
        retainedSamples = []
        transition(to: .listening)

        // 预览是锦上添花：启动失败只记日志，录音照常进行。
        // 绝不能让预览侧的故障影响主路径，也不上报为会话错误。
        do {
            try await previewEngine?.start()
        } catch {
            AppLogger.shared.log("预览启动失败，本次无预览：\(error)")
        }
    }

    /// 结束采集并走完转写与注入。
    func finish() async {
        guard state == .listening else { return }

        audioSource.stop()
        // 必须先停预览再转写：两者共享同一套解码器实例，
        // 重叠会产生数据竞争。stop() 内部会等推理循环真正退出。
        await previewEngine?.stop()

        let samples = buffer.samples
        buffer.reset()

        await process(samples)
    }

    /// 取消当前会话：丢弃音频，不注入任何内容。
    ///
    /// 与转写失败保留音频（供 retry）语义不同——取消是用户主动放弃，
    /// 因此显式清空 retainedSamples。
    func cancel() async {
        guard state == .listening else { return }

        audioSource.stop()
        await previewEngine?.stop()

        buffer.reset()
        retainedSamples = []
        transition(to: .idle)
    }

    /// 运行时挂载预览引擎。
    ///
    /// 单独提供而非只在构造时传入：预览引擎依赖已加载的模型，而模型
    /// 加载是异步的，且换模型后需要重新挂载。
    func attachPreviewEngine(_ engine: PreviewEngine?) {
        guard state == .idle else { return }
        previewEngine = engine
        bindPreview(engine)
    }

    /// 运行时挂载校正流水线。传 nil 表示关闭校正。
    ///
    /// 与 `attachPreviewEngine` 同一模式：本仓库不重建会话，运行时配置
    /// 变更一律就地替换。只在 idle 时生效，避免在一次会话中途换掉规则。
    func attachCorrectionPipeline(_ pipeline: CorrectionPipeline?) {
        guard state == .idle else { return }
        correctionPipeline = pipeline
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

        // 校正绝不抛错：CorrectionPipeline.correct 内部已把所有失败路径
        // 收敛为「返回原文」。这里不写 do/catch 是有意的——若将来它开始
        // 抛错，编译器会立刻指出，而不是让错误静默吞掉用户说的话。
        let finalText: String
        if let correctionPipeline {
            transition(to: .correcting)
            finalText = await correctionPipeline.correct(trimmed)
        } else {
            finalText = trimmed
        }

        transition(to: .injecting)

        let outcome: Result<Void, Error>
        do {
            // 规则三：注入前确认目标应用没变
            try targetGuard.verify(targetToken)
            try sink.send(finalText)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }

        // 先回到 idle 再触发终态回调，与转写失败路径保持一致。
        // 否则调用方在 onText/onError 里同步调用 start() 会被
        // guard state == .idle 静默挡住，两条路径行为不一致。
        transition(to: .idle)
        switch outcome {
        case .success:
            onText?(finalText)
        case .failure(let error):
            onError?(error)
        }
    }

    private func transition(to newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }
}
