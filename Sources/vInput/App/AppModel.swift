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

    private let permissions = Permissions()
    private let hotkey = HotkeyRegistrar()
    private var session: DictationSession?
    private var transcriber: SwitchableTranscriber?
    private var modelRoot: String = ""
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
        let session = DictationSession(
            audioSource: micSource,
            transcriber: transcriber,
            sink: RoutingTextSink(
                typing: TypingSink(),
                clipboard: ClipboardSink(),
                threshold: 100
            ),
            targetGuard: TargetAppGuard()
        )

        session.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .idle: self.phase = .idle
            case .listening: self.phase = .listening
            case .transcribing, .injecting: self.phase = .working
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

        // DictationSession 构造时已接管 onFrame，这里在其之上再包一层，
        // 让同一路音频也进预览处理器。分叉点在 AudioSource 之后——
        // 这样 M3 接蓝牙时，预览无需任何改动即可工作。
        let sessionTap = micSource.onFrame
        let processor = previewProcessor
        micSource.onFrame = { samples in
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
        Task { await attachPreview() }
    }

    func shutdown() {
        hotkey.unregister()
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
    }

    /// 在模型加载完成后把预览引擎挂到会话上。
    ///
    /// 单独一步而非在 bootstrap 里做：预览引擎需要已加载的模型，
    /// 而模型加载是异步且可能失败的。失败时会话照常工作，只是没有预览。
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
        case .transcribing, .injecting:
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
}
