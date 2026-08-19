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
        /// 校正已完成，正在翻译。**排在 `.correcting` 之后**，
        /// 理由见 `allCasesInPipelineOrder`。
        case translating
        case injecting

        /// 流水线的固定顺序。**校正必须在翻译之前**——带同音错字的中文译过去，
        /// 错误会被固化：说「上线」转写成「上限」，译过去就是 upper limit，
        /// 译文里看不出这是个同音错字，而中文原文里校正层本来能修掉它。
        ///
        /// **这个数组自己证明不了上面那句话。** 它是手写的，把 `process()` 里
        /// 校正与翻译两段代码对调，它一个字都不用改——那正是本仓库栽过七次的
        /// 「看着在检查什么，其实什么都没检查」。真正守住调用顺序的是
        /// `DictationTranslationTests.stateOrderPutsCorrectionFirst`：
        /// 让假校正器与假翻译器各自记下被调到的时刻，断言的是调用顺序本身，
        /// 外加「翻译器收到的是校正**后**的文本」这条行为证据。
        ///
        /// 那么它留着干什么：一是给「实际状态序列」一个可比对的基准
        /// （`observedStatesFollowDeclaredOrder` 断言实测序列是它的子序列，
        /// 数组一改就红）；二是给要遍历全部状态的用例一个出处
        /// （`RemoteKeySuppressorTests`）——那里原本手抄了一份状态列表，
        /// 加一格时没人会记得回去补，而漏掉的那一格恰恰是没被覆盖的那一格。
        static let allCasesInPipelineOrder: [State] = [
            .idle, .listening, .transcribing, .correcting, .translating, .injecting,
        ]
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
    /// 校正跑完后回调，携带给 HUD 的标注（nil 表示正常改动过，无需提示）。
    ///
    /// **校正关闭时一次都不回调**——没开的东西不该提示「未校正」。
    var onCorrection: ((CorrectionAnnotation?) -> Void)?
    /// 翻译产生标注时回调。nil 表示正常译出（HUD 什么都不显示）。
    ///
    /// **输出语言是中文时一次都不回调**，与 `onCorrection` 同一条规矩：
    /// 用户没要翻译，屏幕上就不该冒出任何与翻译有关的字。
    var onTranslation: ((TranslationAnnotation?) -> Void)?

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
    /// 翻译流水线。可为 nil——不翻译时摘掉，注入路径上就少一次 actor 跳转。
    /// 是 `var` 的理由与 `correctionPipeline` 一字不差。
    private var translationPipeline: TranslationPipeline?
    /// 当前输出语言。
    ///
    /// **与流水线分开存，两者都要判。** `AppModel` 在目标是中文时会把流水线
    /// 直接摘掉（见 `TranslationAttachment.detach`），但那是它的策略，不是本
    /// 类型能假设的事——只判流水线在不在的话，谁哪天挂着流水线传了 `.chinese`
    /// 进来，中文就会被送去「翻译成中文」，而 `TranslationPipeline` 里的同款
    /// guard 会让这件事在行为上完全看不出来（返回值一模一样），只是白付一次
    /// actor 跳转和一次状态迁移。
    private var translationTarget: TranslationTarget = .chinese
    /// 注入失败时的兜底：写剪贴板 + 发通知。可为 nil——缺席时行为与从前
    /// 完全一致（报错、回 idle），只是文字又会蒸发。
    private let rescue: TextRescuing?

    private var buffer = AudioBuffer(sampleRate: AudioFormat.sampleRate)
    private var targetToken: String?
    /// 转写失败时保留的音频，供 retry 使用。
    private var retainedSamples: [Float] = []

    /// 供测试断言保留的样本数。
    var retainedSampleCount: Int { retainedSamples.count }

    /// 现在有没有东西可以重试。菜单栏据此决定重试项是可点还是灰的。
    ///
    /// **必须与 `retry()` 的前置条件是同一份表达式。** 两处各写一份的话，
    /// 迟早出现「菜单项可点但什么都不发生」或者「有东西可重试却是灰的」
    /// ——后者等于这个入口不存在，而它本来就是为了修「入口不存在」
    /// （`Transcriber.swift:17`：全仓只有测试在调 retry()）。
    var canRetry: Bool { state == .idle && !retainedSamples.isEmpty }

    init(
        audioSource: AudioSource,
        transcriber: Transcriber,
        sink: TextSink,
        targetGuard: TargetAppGuard,
        previewEngine: PreviewEngine? = nil,
        correctionPipeline: CorrectionPipeline? = nil,
        rescue: TextRescuing? = nil
    ) {
        self.audioSource = audioSource
        self.transcriber = transcriber
        self.sink = sink
        self.targetGuard = targetGuard
        self.previewEngine = previewEngine
        self.correctionPipeline = correctionPipeline
        self.rescue = rescue

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

    /// 挂上（或摘掉）翻译流水线。传 nil 表示不翻译。
    ///
    /// **与 `attachCorrectionPipeline` 同一条规则：只在 idle 时接受挂载。**
    /// 用户在说话途中从菜单里换语言时这次挂载会被拒，`AppModel` 记下来
    /// （`translationApplyPending`），等回到 idle 再补挂一次。
    ///
    /// 选「延迟生效」而不是「立刻生效」，理由有两条：
    ///
    /// 1. **一次会话内规则不变。** 用户是在他当时选的语言下开口的。说到一半
    ///    改主意就把这句话改译成别的，等于拿他说完之后才做的选择去处理他说完
    ///    之前的话——而这一句会被**直接注进他即将发出的窗口**。反过来（英文
    ///    切回中文）同理：那句话是冲着英文说的，就该出英文。
    /// 2. **立刻生效也换不来什么。** 本地翻译模型冷加载几十秒（M8 第 0 步实测
    ///    14.1 秒，有页缓存 3.7–8.0 秒），中途挂上的流水线在这一句上多半
    ///    `isReady == false`，注入的仍是中文，只是多一条「翻译模型还在加载」
    ///    的标注——白担一次「规则中途变了」的风险，换一句解释。
    ///
    /// 守着这条语义的是 `DictationTranslationTests.attachMidSessionAppliesNextRound`。
    func attachTranslation(_ pipeline: TranslationPipeline?, target: TranslationTarget = .chinese) {
        guard state == .idle else { return }
        translationPipeline = pipeline
        translationTarget = target
    }

    /// 用上一次失败时保留的音频重新走一遍。
    func retry() async {
        guard canRetry else { return }
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

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // 规则二：空结果是失败，不是成功。
            //
            // 此前这里在空判**之前**就把 retainedSamples 清空了，于是
            // 「转写返回空串」这条路径静默吞掉音频：不报错、不记日志、
            // HUD 直接关闭、retry() 也救不回来。真机上不到 1 秒的话
            // （「好的」「谢谢」）每一句都走这条路径消失。
            //
            // 转写层的补白已经修掉了那个成因（见
            // WhisperKitTranscriber.decodingFloorDuration），这里是兜底：
            // 哪怕补白之后仍然解不出，用户也看得见、音频也还在。
            retainedSamples = samples
            AppLogger.shared.log("转写结果为空，保留 \(samples.count) 个样本供重试")
            transition(to: .idle)
            onError?(TranscribeError.emptyResult)
            return
        }

        retainedSamples = []

        // 校正绝不抛错：CorrectionPipeline.correct 内部已把所有失败路径
        // 收敛为「返回原文」。这里不写 do/catch 是有意的——若将来它开始
        // 抛错，编译器会立刻指出，而不是让错误静默吞掉用户说的话。
        let finalText: String
        if let correctionPipeline {
            transition(to: .correcting)
            let result = await correctionPipeline.correct(trimmed)
            finalText = result.text
            onCorrection?(result.annotation)
        } else {
            finalText = trimmed
        }

        // 翻译绝不抛错：`TranslationPipeline.translate` 内部已把所有失败路径
        // 收敛为「返回中文原文 + 标注」。这里不写 do/catch 是有意的——
        // 若将来它开始抛错，编译器会立刻指出，而不是让错误静默吞掉用户说的话
        // （与上面的校正层同款处理）。
        //
        // **排在校正之后。** 带同音错字的中文译过去，错误会被固化：用户说
        // 「上线」而转写成「上限」，译过去就是 upper limit，译文里看不出这是个
        // 同音错字，而中文原文里校正层本来能修掉它。
        var textToInject = finalText
        if let translationPipeline, translationTarget.requiresTranslation {
            transition(to: .translating)
            let result = await translationPipeline.translate(finalText, to: translationTarget)
            textToInject = result.text
            onTranslation?(result.annotation)
        }

        transition(to: .injecting)

        let outcome: Result<Void, Error>
        do {
            // 规则三：注入前确认目标应用没变
            try targetGuard.verify(targetToken)
            try sink.send(textToInject)
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
            onText?(textToInject)
        case .failure(let error):
            // 规则二（注入失败）与规则三（目标应用改变）此前都到此为止，
            // 文本直接蒸发。现在先把它救进剪贴板并通知用户，再报错。
            //
            // 顺序上兜底在 onError 之前：`AppModel` 在 onError 里只是把错误
            // 写到菜单栏，而用户看到提示时文字必须已经在剪贴板里了。
            //
            // 救的是 `textToInject` 而不是 `finalText`：用户要的是译文，
            // 从剪贴板里粘出一段中文等于这次翻译白做了。
            await rescue?.rescue(textToInject, error: error)
            onError?(error)
        }
    }

    private func transition(to newState: State) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }
}
