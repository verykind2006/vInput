import Carbon.HIToolbox
import Foundation
import Observation
import SwiftUI

/// 顶层接线：把各层组装起来，并把状态暴露给菜单栏 UI。
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case listening
        case working
        case error(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastText: String = ""
    private(set) var permissionStatus: Permissions.Status = .ready
    /// 实际生效的模型，显示在菜单栏，方便确认切换是否成功。
    private(set) var activeModelName: String = ""
    /// `vendor/models` 下发现的全部可用模型，供菜单列出。
    private(set) var availableModels: [ModelDescriptor] = []
    /// 正在加载模型。首次使用某模型时 Core ML 要编译到神经引擎，
    /// 实测可达 40–125 秒，期间必须让用户看到进度而不是以为卡死。
    private(set) var loadingModelName: String?

    /// 校正是否启用，菜单据此显示「校正：开 / 关」。
    ///
    /// 真实存储在 UserDefaults（需跨启动保留），这里是它的可观察镜像：
    /// @Observable 只跟踪自身的存储属性，若菜单直接读 UserDefaults，
    /// 点完开关标题不会刷新。写入时两边一起更新，UI 只读这一份。
    private(set) var correctionEnabled: Bool = false
    /// 当前校正模型目录名，未指定时为 nil（此时按标识符下载）。
    /// 同样是 UserDefaults 的可观察镜像，理由同上。
    private(set) var correctionModelName: String?

    private let permissions = Permissions()
    /// 校正偏好。开关状态与模型目录都要跨启动保留。
    private let correctionPreference = CorrectionPreference()
    /// 「校正能不能开」的判定。全部规则都在它那边，这里只负责把结果
    /// 翻译成弹面板与错误提示。
    private let correctionActivation: CorrectionActivation
    /// 弹出校正模型目录选择器，返回用户选中的目录（取消时为 nil）。
    ///
    /// 由 UI 层注入：`AppModel` 不该知道 `NSOpenPanel` 的存在，而「开启校正
    /// 时若无合法模型就弹选择器」这条流程必须能在没有 UI 的测试里驱动。
    var chooseCorrectionModelFolder: (@MainActor () -> URL?)?
    /// 上一次挂载校正流水线被会话拒绝（当时不在 idle）。
    ///
    /// 用户在录音中或转写那几秒里改设置是很自然的动作，而
    /// `DictationSession` 只在 idle 时接受挂载。不记住这件事的话，
    /// 那次改动就永远丢失了——而菜单已经显示成新状态，等于在骗人。
    private var correctionApplyPending = false
    private let hotkey = HotkeyRegistrar()
    private var session: DictationSession?
    private var transcriber: SwitchableTranscriber?
    private var modelRoot: String = ""

    private(set) var remoteState: RemoteConnectionState = .disconnected
    private(set) var remoteBattery: Int?

    private let bluetoothSource = BluetoothRemoteSource()
    private let hidListener = RemoteHIDListener()
    private let keySuppressor = RemoteKeySuppressor()
    private let keepalive = VoiceSessionKeepalive()
    private var remoteCoordinator: RemoteCoordinator?
    private var bluetoothBridge: XiaomiBluetoothBridge?
    private var audioRouter: AudioSourceRouter?
    private let hudModel = HUDViewModel()
    // 不能用 lazy：@Observable 宏为存储属性生成 init accessor，
    // 与 lazy 的存储语义冲突，编译期报错。构造 HUDPanel/
    // CancelHotkeyController 本身没有副作用，非 lazy 无影响。
    private let hud: HUDPanel
    private let cancelHotkey: CancelHotkeyController
    private let previewProcessor = SourceBackedAudioProcessor()
    /// 录音开始时刻，用于 HUD 的时长显示。
    private var recordingStartedAt: Date?
    private var hudTimer: Timer?

    /// 默认快捷键：Option + D。
    private let hotkeyCode = UInt32(kVK_ANSI_D)
    private let hotkeyModifiers = UInt32(optionKey)

    init() {
        hud = HUDPanel(model: hudModel)
        cancelHotkey = CancelHotkeyController(registrar: EscHotkeyRegistrar())
        correctionActivation = CorrectionActivation(preference: correctionPreference)
        // 镜像上次退出时的偏好，菜单打开即是正确状态。
        correctionEnabled = correctionPreference.isEnabled
        correctionModelName = correctionPreference.modelDirectory?.lastPathComponent
    }

    /// 把 UserDefaults 里的校正偏好同步到可观察镜像上。
    /// 每个改动偏好的入口都必须调它，否则菜单标题会停在旧状态。
    private func syncCorrectionMirrors() {
        correctionEnabled = correctionPreference.isEnabled
        correctionModelName = correctionPreference.modelDirectory?.lastPathComponent
    }

    /// 构造底层转写器。
    ///
    /// `nonisolated`：它不碰任何 MainActor 状态，只是构造一个 actor。
    /// 不加的话会继承 AppModel 的 @MainActor 隔离，转成
    /// `@Sendable` 闭包时丢失全局 actor——那在 Swift 6 语言模式下是错误。
    private nonisolated static func makeTranscriber(_ model: ModelDescriptor) -> Transcriber {
        WhisperKitTranscriber(
            modelName: model.name,
            // 空路径表示本地没有该模型，交给 WhisperKit 按名称下载。
            modelFolder: model.folder.isEmpty ? nil : model.folder,
            language: "zh"
        )
    }

    func bootstrap() {
        permissionStatus = permissions.status()

        // 偏好为「开」但模型目录已失效（被移动/删除）时自动关掉。
        // 必须在挂流水线之前做，否则这一轮启动会带着一个注定降级的校正跑。
        let wasEnabled = correctionPreference.isEnabled
        if wasEnabled && !correctionActivation.revalidateAtLaunch() {
            AppLogger.shared.log(
                "启动自检：校正模型目录已失效"
                + "（\(correctionPreference.modelDirectory?.path ?? "未指定")），校正已自动关闭"
            )
        }
        syncCorrectionMirrors()

        modelRoot = ModelCatalog.defaultRoot(appBundleURL: Bundle.main.bundleURL)
        availableModels = ModelCatalog.discover(in: modelRoot)

        // 本地一个模型都没有时，退化成让 WhisperKit 自行下载
        // （此网络下大概率失败，会以错误状态出现在菜单栏）。
        let initial = availableModels.first
            ?? ModelDescriptor(name: ModelPreference.preferredModels.last ?? "base", folder: "")
        activeModelName = initial.name

        let transcriber = SwitchableTranscriber(
            initial: initial,
            // 写成显式的 @Sendable 闭包字面量：直接引用静态方法时，
            // 函数值本身不带 @Sendable，转换会触发数据竞争警告。
            makeTranscriber: { @Sendable model in AppModel.makeTranscriber(model) }
        )
        self.transcriber = transcriber

        let micSource = SystemMicSource()
        let router = AudioSourceRouter(sources: [
            .microphone: micSource,
            .bluetooth: bluetoothSource,
        ])
        self.audioRouter = router
        let session = DictationSession(
            audioSource: router,
            transcriber: transcriber,
            sink: RoutingTextSink(
                typing: TypingSink(),
                clipboard: ClipboardSink()
            ),
            targetGuard: TargetAppGuard()
        )

        session.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .idle:
                self.phase = .idle
                // 会话结束，把此前被拒绝的挂载补上。
                if self.correctionApplyPending { self.applyCorrectionPreference() }
            case .listening: self.phase = .listening
            // 校正与转写、注入同归 working：Phase 是给菜单栏用的粗粒度
            // 状态，不必区分到这一级，细节由 HUD 呈现。
            case .transcribing, .correcting, .injecting: self.phase = .working
            }
            self.hudModel.phase = state
            self.cancelHotkey.update(for: state)

            if state == .listening {
                self.beginHUD()
            } else if state == .idle {
                self.endHUD()
            }
        }
        session.onError = { [weak self] error in
            AppLogger.shared.log("会话出错：\(error)")
            guard AppModel.isUserFacing(error) else { return }
            self?.phase = .error(String(describing: error))
        }
        session.onText = { [weak self] text in
            AppLogger.shared.logTranscript(text, context: "注入成功")
            self?.lastText = text
        }
        session.onPreview = { [weak self] preview in
            self?.hudModel.preview = preview
        }
        self.session = session
        // 会话与全部回调就绪后再挂校正，让上次启动保存的开关状态生效。
        applyCorrectionPreference()

        // 分叉点收敛到路由器：无论音频来自内置麦还是蓝牙遥控器，
        // 都经由同一处流向预览处理器。这是 M2「分叉在 AudioSource 之后」
        // 那个决定的兑现——蓝牙接上后 HUD 与实时预览零改动可用。
        let sessionTap = router.onFrame
        let processor = previewProcessor
        router.onFrame = { samples in
            sessionTap?(samples)
            processor.append(samples)
        }

        cancelHotkey.onCancel = { [weak self] in
            guard let self, let session = self.session else { return }
            AppLogger.shared.log("用户按 Esc 取消会话")
            Task { await session.cancel() }
        }
        AppLogger.shared.log("启动完成，模型=\(initial.name) 可用模型=\(availableModels.map(\.name))")

        do {
            try hotkey.register(keyCode: hotkeyCode, modifiers: hotkeyModifiers) { [weak self] in
                self?.toggle()
            }
        } catch {
            phase = .error("快捷键注册失败：\(error)")
        }

        // 预览引擎依赖已加载的模型，异步挂载。
        Task { await warmUpAndAttachPreview() }

        startRemote()
    }

    func shutdown() {
        hotkey.unregister()
        stopRemote()
    }

    // MARK: - HUD

    private func beginHUD() {
        hudModel.preview = .empty
        hudModel.energy = []
        hudModel.elapsed = 0
        hudModel.previewDegraded = false
        recordingStartedAt = Date()
        hud.show()

        // 20 fps：波形要这个频率才不卡顿。时长只显示到秒，顺带一起更新。
        // 能量直接从 previewProcessor 读，不等流式转写的状态回调——
        // 那是 1–2 秒一次，用它驱动波形会一顿一顿的。
        hudTimer?.invalidate()
        hudTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let started = self.recordingStartedAt else { return }
                self.hudModel.elapsed = Date().timeIntervalSince(started)
                self.hudModel.energy = self.previewProcessor.relativeEnergy
            }
        }
    }

    private func endHUD() {
        hudTimer?.invalidate()
        hudTimer = nil
        recordingStartedAt = nil
        hud.hide()

        // 记录本次录音的能量分布。真机反馈「预览要 20-30 秒才出字」，
        // 而流式转写的静音阈值是 0.3——若真人对着麦克风说话的能量普遍
        // 低于该值，转写就会被 VAD 一直挡住。TTS 合成音测不出这个问题
        // （它的能量 93% 在阈值之上），必须用真实数据判断。
        let energy = previewProcessor.energySummary()
        if energy.count > 0 {
            AppLogger.shared.log(
                "本次能量：\(energy.count) 个块 中位 \(String(format: "%.3f", energy.median)) "
                + "最大 \(String(format: "%.3f", energy.max)) "
                + "超阈值(0.3) \(energy.aboveThreshold) 个 "
                + "(\(energy.aboveThreshold * 100 / energy.count)%)"
            )
        }
    }

    /// 在模型加载完成后把预览引擎挂到会话上。
    ///
    /// 单独一步而非在 bootstrap 里做：预览引擎需要已加载的模型，
    /// 而模型加载是异步且可能失败的。失败时会话照常工作，只是没有预览。
    /// 预热模型，然后挂载预览引擎。
    ///
    /// **必须先预热。** 预览引擎要从已加载的 `WhisperKit` 实例取解码器组件，
    /// 而模型是懒加载的——首次转写时才 `prepare()`。启动时直接调
    /// `attachPreview()` 必然拿到 nil（真机日志实测：「模型未就绪，本次
    /// 运行无实时预览」），且不会重试，等于实时预览永远不工作。
    ///
    /// 顺带解决另一个问题：模型首次加载要做 Core ML 到神经引擎的编译
    /// （实测 40–125 秒）。放到启动后台做，用户第一次说话就不必干等。
    private func warmUpAndAttachPreview() async {
        guard let transcriber else { return }
        do {
            try await transcriber.prepare()
            AppLogger.shared.log("模型预热完成")
        } catch {
            AppLogger.shared.log("模型预热失败，本次运行无实时预览：\(error)")
            return
        }
        await attachPreview()
    }

    private func attachPreview() async {
        guard let transcriber, let session else { return }
        guard let previewCapable = await transcriber.currentPreviewCapable() else {
            AppLogger.shared.log("当前转写器不支持预览")
            return
        }
        guard let engine = await previewCapable.makePreviewEngine(processor: previewProcessor) else {
            AppLogger.shared.log("模型未就绪，本次运行无实时预览")
            return
        }
        session.attachPreviewEngine(engine)
        AppLogger.shared.log("实时预览已就绪")
    }

    // MARK: - 校正

    /// 依据偏好构造校正流水线。关闭时返回 nil，会话行为与从前完全一致。
    ///
    /// 只在校正开着时构造，因而也只在开着时加载模型：这是个 2 GB 级的
    /// 模型，加载耗时且占内存，而校正默认关闭，多数启动根本用不到它。
    private func makeCorrectionPipeline() -> CorrectionPipeline? {
        guard correctionPreference.isEnabled else { return nil }
        return CorrectionPipeline(
            corrector: MLXCorrector(modelDirectory: correctionPreference.modelDirectory)
        )
    }

    /// 把当前偏好应用到会话上。
    ///
    /// **不重建会话**——本仓库的运行时配置变更一律就地替换（换 Whisper
    /// 模型走 `SwitchableTranscriber.switchTo`，挂预览引擎走
    /// `attachPreviewEngine`）。重建会话会丢掉已绑定的回调，
    /// 且与既有模式不一致。
    ///
    /// `attachCorrectionPipeline` 只在 idle 时生效。录音/转写途中改设置
    /// 会被 DictationSession 拒绝，因此这里记下「有一次挂载没生效」，
    /// 等会话回到 idle 时由 `onStateChange` 里的补挂逻辑再调用一次本方法。
    private func applyCorrectionPreference() {
        guard let session else {
            correctionApplyPending = true
            return
        }
        guard session.state == .idle else {
            correctionApplyPending = true
            AppLogger.shared.log("校正设置本次会话不生效（当前 \(session.state)），会话结束后补挂")
            return
        }
        let pipeline = makeCorrectionPipeline()
        session.attachCorrectionPipeline(pipeline)
        correctionApplyPending = false

        // 开着校正就立刻在后台加载模型，和 Whisper 的预热同一个道理：
        // 加载一次要几十秒，而注入路径上一秒都不能等——未就绪时流水线
        // 直接退回原文。不预热的话，用户会觉得「开了校正好像没什么用」。
        //
        // 用 detached 而非 `Task {}`：`Task {}` 继承 MainActor，加载中的
        // 同步段会卡住主线程上的 UI。优先级压到 utility，让它给启动时的
        // Whisper 预热让路。
        guard let pipeline else { return }
        Task.detached(priority: .utility) { await pipeline.warmUp() }
    }

    /// 切换校正开关。改动立即就地生效（若正在录音则下次会话生效）。
    ///
    /// 关闭不做任何校验；开启则必须先有一个合法的模型目录，见
    /// `enableCorrection()`。
    func toggleCorrection() {
        guard !correctionEnabled else {
            correctionActivation.disable()
            syncCorrectionMirrors()
            applyCorrectionPreference()
            AppLogger.shared.log("校正已关闭")
            return
        }
        enableCorrection()
    }

    /// 开启校正。**以「有一个合法的模型目录」为前提。**
    ///
    /// 没有合法目录就直接弹选择器，而不是先把开关打开再说：开着一个注定
    /// 走降级路径的校正，用户每次说话都拿到未校正的原文，而菜单显示「开」，
    /// 界面上没有任何线索——这是上手体验里最大的坑。
    private func enableCorrection() {
        let log = AppLogger.shared
        var outcome = correctionActivation.enableUsingStoredModel()

        if outcome == .needsModelSelection {
            log.log("开启校正：没有可用的校正模型目录，请用户选择")
            guard let directory = chooseCorrectionModelFolder?() else {
                // 用户取消。保持关闭，菜单仍显示「关」。
                log.log("开启校正被取消，校正保持关闭")
                syncCorrectionMirrors()
                return
            }
            outcome = correctionActivation.enable(with: directory)
        }

        switch outcome {
        case .accepted(let descriptor):
            syncCorrectionMirrors()
            applyCorrectionPreference()
            log.log("校正已开启，模型=\(descriptor.name)")
        case .rejected(let missing):
            // 不开、不保存，并说清缺了什么——只说「无效目录」的话，
            // 用户没法判断是选错了目录还是模型没下全。
            phase = .error("这不是校正模型目录，缺少：\(missing.joined(separator: "、"))")
            syncCorrectionMirrors()
            log.log("开启校正被拒：目录缺少 \(missing.joined(separator: "、"))")
        case .needsModelSelection:
            // 走不到：上面要么已选了目录，要么已 return。
            break
        }
    }

    /// 指定本地校正模型目录。
    ///
    /// 与 M1 的 Whisper 模型选择同一交互：4B 模型能否胜任中文常识判断
    /// 事先无法确定，用户可自行换更大的模型试，无需等待代码改动。
    ///
    /// 同样要校验：这是另一条能把无效路径写进偏好的入口，放过它等于
    /// 让校正在下次启动时静默失灵。
    func selectCorrectionModel(directory: URL) {
        let log = AppLogger.shared
        switch correctionActivation.selectModel(directory: directory) {
        case .accepted(let descriptor):
            syncCorrectionMirrors()
            applyCorrectionPreference()
            log.log("校正模型已切换：\(descriptor.name)")
        case .rejected(let missing):
            phase = .error("这不是校正模型目录，缺少：\(missing.joined(separator: "、"))")
            log.log("指定校正模型被拒：目录缺少 \(missing.joined(separator: "、"))")
        case .needsModelSelection:
            break
        }
    }

    // MARK: - 运行时换模型

    /// 重新扫描模型目录。打开菜单时调用，这样新下载的模型无需重启即可出现。
    func refreshAvailableModels() {
        guard !modelRoot.isEmpty else { return }
        availableModels = ModelCatalog.discover(in: modelRoot)
    }

    /// 能否切换模型。录音或转写进行中时不允许，避免换掉正在用的引擎。
    var canSwitchModel: Bool {
        loadingModelName == nil && (session?.state ?? .idle) == .idle
    }

    /// 切换到指定模型。加载可能耗时数十秒，期间 `loadingModelName` 非空。
    func selectModel(_ model: ModelDescriptor) {
        let log = AppLogger.shared
        guard let transcriber else {
            log.log("切换模型被拒：transcriber 尚未初始化")
            return
        }
        guard canSwitchModel else {
            log.log("切换模型被拒：canSwitchModel=false loading=\(loadingModelName ?? "nil") sessionState=\(String(describing: session?.state))")
            return
        }
        guard model.name != activeModelName else {
            log.log("切换模型跳过：已经是 \(model.name)")
            return
        }

        log.log("开始切换模型 \(activeModelName) → \(model.name) 目录=\(model.folder)")
        loadingModelName = model.name
        phase = .idle

        Task { [weak self] in
            let started = Date()
            do {
                try await transcriber.switchTo(model)
                self?.activeModelName = model.name
                // 换模型后预览引擎绑的是旧解码器，必须重新挂载。
                await self?.attachPreview()
                log.log("切换成功 \(model.name) 耗时 \(Int(Date().timeIntervalSince(started)))s")
            } catch {
                // 切换失败时旧模型仍然可用，见 SwitchableTranscriber 的保证。
                log.log("切换失败 \(model.name): \(error)")
                self?.phase = .error("加载模型「\(model.name)」失败：\(error)")
            }
            // 无论成败都必须解除加载态，否则 toggle() 会被永久挡住。
            self?.loadingModelName = nil
            log.log("加载态已解除，当前模型 \(self?.activeModelName ?? "?")")
        }
    }

    /// 让用户手选一个模型目录。
    ///
    /// 先校验目录结构，选错时给出明确提示，而不是等加载失败才报一个
    /// 难以理解的错误。
    func selectModelFromFolder(_ folder: String) {
        switch ModelCatalog.validate(folder: folder) {
        case .success(let model):
            selectModel(model)
        case .failure(.notAModelFolder(let missing)):
            phase = .error("这不是模型目录，缺少：\(missing.joined(separator: "、"))")
        }
    }

    /// 快捷键触发：未在录音则开始，正在录音则结束。
    func toggle() {
        let log = AppLogger.shared
        guard let session else {
            log.log("toggle 被拒：session 尚未初始化")
            return
        }
        // 模型正在编译/加载时不接受录音请求。
        guard loadingModelName == nil else {
            log.log("toggle 被拒：正在加载模型 \(loadingModelName!)")
            return
        }

        permissionStatus = permissions.status()
        guard permissionStatus == .ready else {
            log.log("toggle 被拒：权限不足 \(permissionStatus)")
            handleMissingPermission()
            return
        }

        switch session.state {
        case .idle:
            audioRouter?.select(.microphone)
            // start() 现在是 async（要等预览引擎启动），与下面 finish()
            // 一样用 Task 包一层，toggle() 本身保持同步好继续挂在按钮上。
            Task {
                do {
                    try await session.start()
                    log.log("开始录音，模型=\(activeModelName)")
                } catch {
                    log.log("录音启动失败：\(error)")
                    phase = .error(String(describing: error))
                }
            }
        case .listening:
            log.log("结束录音，进入转写")
            Task { await session.finish() }
        case .transcribing, .correcting, .injecting:
            log.log("toggle 忽略：正在处理上一段（\(session.state)）")
        }
    }

    private func handleMissingPermission() {
        switch permissionStatus {
        case .microphoneMissing:
            Task {
                _ = await permissions.requestMicrophone()
                permissionStatus = permissions.status()
            }
        case .accessibilityMissing:
            permissions.openAccessibilitySettings()
        case .ready:
            break
        }
    }

    /// 该错误是否需要展示给用户。
    ///
    /// 唯一不展示的是「音频过短」：按一下语音键就松开是常见误触，
    /// 为此弹一个错误状态是噪音。其余错误都要让用户知道——
    /// 尤其是注入失败与目标应用改变，那关系到用户说的话去了哪里。
    nonisolated static func isUserFacing(_ error: Error) -> Bool {
        if let error = error as? TranscribeError, error == .audioTooShort {
            return false
        }
        return true
    }

    // MARK: - 遥控器

    private func startRemote() {
        let coordinator = RemoteCoordinator(source: bluetoothSource)

        coordinator.onStartSession = { [weak self] in
            guard let self, let session = self.session else { return }
            // 模型加载中不接受录音请求，与 ⌥D 的守卫保持一致
            guard self.loadingModelName == nil else { return }
            self.audioRouter?.select(.bluetooth)
            // RC003 的语音键同时是 HID 按键，按住期间 macOS 会持续把它
            // 投递给前台应用（实测为 Page Up 自动重复）。录音期间吞掉。
            self.keySuppressor.beginSuppressing()
            Task {
                do {
                    try await session.start()
                    AppLogger.shared.log("遥控器语音键按下，开始录音")
                } catch {
                    AppLogger.shared.log("遥控器录音启动失败：\(error)")
                }
            }
            self.keepalive.start()
        }
        coordinator.onFinishSession = { [weak self] in
            self?.keySuppressor.endSuppressing()
            self?.keepalive.stop()
            guard let session = self?.session else { return }
            AppLogger.shared.log("遥控器语音键松开，进入转写")
            Task { await session.finish() }
        }
        coordinator.onCancelSession = { [weak self] in
            self?.keySuppressor.endSuppressing()
            self?.keepalive.stop()
            guard let session = self?.session else { return }
            AppLogger.shared.log("遥控器返回键按下，取消会话")
            Task { await session.cancel() }
        }

        keepalive.onExtend = { [weak self] in
            guard let bridge = self?.bluetoothBridge else { return }
            if !bridge.requestMicrophoneExtend() {
                // 单次失败不中断会话——下一个间隔还会再试，
                // 连接真正断开时由桥的生命周期终止。
                AppLogger.shared.log("MIC_EXTEND 写入失败，将在下个间隔重试")
            }
        }
        keepalive.onTimeout = { [weak self] in
            AppLogger.shared.log("达到 \(Int(VoiceSessionKeepalive.maxDuration)) 秒上限，主动结束会话")
            self?.remoteCoordinator?.handleVoiceStop()
        }
        remoteCoordinator = coordinator

        hidListener.onCancelPressed = { [weak coordinator] in
            coordinator?.handleCancelPressed()
        }
        hidListener.start()
        keySuppressor.start()

        let bridge = XiaomiBluetoothBridge(delegate: self)
        bluetoothBridge = bridge
        bridge.start()
    }

    private func stopRemote() {
        hidListener.stop()
        keySuppressor.stop()
        bluetoothBridge?.stop()
        bluetoothBridge = nil
        remoteCoordinator = nil
    }
}

// MARK: - XiaomiBluetoothBridgeDelegate

extension AppModel: @MainActor XiaomiBluetoothBridgeDelegate {
    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didChange state: BluetoothBridgeState) {
        AppLogger.shared.log("遥控器状态：\(state)")
        remoteState = RemoteConnectionState(bridgeState: state)
    }

    func bluetoothBridgeDidStartVoice(_ bridge: XiaomiBluetoothBridge) {
        remoteCoordinator?.handleVoiceStart()
    }

    func bluetoothBridgeDidStopVoice(_ bridge: XiaomiBluetoothBridge) {
        remoteCoordinator?.handleVoiceStop()
    }

    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode samples: [Int16]) {
        remoteCoordinator?.handleDecoded(samples)
    }

    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didUpdateBatteryLevel level: Int?) {
        remoteBattery = level
    }

    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didIdentifyRemoteModel model: XiaomiRemoteModel) {
        AppLogger.shared.log("识别到遥控器型号：\(model)")
    }

    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didUpdatePowerState state: RemotePowerState?) {
        // 本项目不使用电源状态，仅记录
        AppLogger.shared.log("遥控器电源状态：\(String(describing: state))")
    }
}
