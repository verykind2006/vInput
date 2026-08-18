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
    /// 上一次转写失败后音频还留着，菜单栏的「重试上次转写」据此点亮。
    ///
    /// 真实判据在 `DictationSession.canRetry`，这里是它的可观察镜像：
    /// @Observable 只跟踪自身的存储属性，菜单直接读 session 的话点完不会
    /// 刷新（与 `correctionEnabled` 同一个坑，见那里的注释）。
    private(set) var canRetry: Bool = false

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
    private var bleScanner: BLEScanner?
    private var hidProbe: HIDReportProbe?
    private var bleScanFileLog: BLEScanFileLog?
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
    /// 附注的收起计时器，见 `hudNoticeLinger`。
    private var hudNoticeTimer: Timer?
    /// 通知投递（含未授权时退回 HUD）。在 `bootstrap` 里建，因为退路要拿到
    /// 已经接好线的 HUD。
    private var notificationPresenter: NotificationPresenter?

    /// 会话结束后 HUD 为附注多停留的时长。
    ///
    /// 附注（「文字未输入，已复制」「本次未校正」）**产生的时刻就是面板
    /// 该关掉的时刻**——不多停这几秒，等于把它画上去再立刻擦掉。
    /// 4 秒是「扫一眼够、挡住屏幕又不烦人」的折中，需要真机上按感觉调。
    private static let hudNoticeLinger: TimeInterval = 4

    /// 默认快捷键：Option + D。
    private let hotkeyCode = UInt32(kVK_ANSI_D)
    private let hotkeyModifiers = UInt32(optionKey)

    // MARK: - 基准集录制（开发期工具）

    /// 基准集录制是否可用。**开发期工具，默认隐藏。**
    ///
    /// 用 `VINPUT_BENCH=1` 启动才显示入口。它会把音频写到磁盘，而原始设计
    /// 写明「音频不落盘」——藏起来是为了让这个例外不会被误当成常态功能。
    nonisolated static var benchEnabled: Bool {
        ProcessInfo.processInfo.environment["VINPUT_BENCH"] == "1"
    }

    private(set) var benchSession: BenchRecordingSession?
    private var benchSamples: [Float] = []
    /// 正在录当前这条。菜单要显示它：点一下菜单就关了，没有这个状态的话
    /// 用户看不出录音到底起没起来，只能靠日志。
    private(set) var benchIsRecording = false

    /// 上一次 `onStateChange` 看到的状态。用来判「这次是不是从 idle 出来的」，
    /// 因为 HUD 只该在进入非 idle 的**那一刻**打开一次——重复调 `beginHUD`
    /// 会把已经计的时长和刚产生的校正标注一起清掉。
    private var lastSessionState: DictationSession.State = .idle

    /// 录制专用的音频源。
    ///
    /// **不复用听写那一路。** `AppModel` 里的 `SystemMicSource` 是
    /// `bootstrap()` 的局部变量、由 `AudioSourceRouter` 持有，`onFrame`
    /// 归它管——录制期间抢过来会破坏听写。另起一个实例，两者互不知情。
    ///
    /// 代价是同一支麦克风有两个 `AVAudioEngine`。它们不会同时用（两条
    /// guard 双向挡住：录制时不许听写、听写时不许录制），但这个约束靠
    /// 代码而非类型保证。
    ///
    /// 用到才建：这是开发期工具，正常分发下永远走不到这里，不该让每次
    /// 启动都白白多一个 `AVAudioEngine`。（不能用 lazy——@Observable 宏
    /// 与 lazy 的存储语义冲突，见上面 `hud` 那条注释。）
    private var benchMicSource: SystemMicSource?

    /// 录制窗口。构造它不会建窗，真正的 NSWindow 要到 show 时才出现。
    private let benchWindow = BenchRecordingWindowController()

    /// 打开录制窗口。清单读不到就只记日志——开发期工具不该让应用崩掉。
    ///
    /// 每次新开都从第一条起（新建会话）。窗口已经开着时只把它带到前台，
    /// 不重建会话：否则用户录到第 15 条时手滑点一下菜单就被弹回第 1 条。
    func startBenchRecording() {
        guard Self.benchEnabled else { return }

        if benchWindow.isOpen {
            benchWindow.show(BenchRecordingView(model: self))
            return
        }

        do {
            benchSession = BenchRecordingSession(manifest: try BenchManifest.loadFromRepository())
            AppLogger.shared.log("基准集录制已开始")
        } catch {
            AppLogger.shared.log("基准集清单读取失败：\(error)")
            return
        }

        benchWindow.onClose = { [weak self] in self?.benchWindowDidClose() }
        benchWindow.show(BenchRecordingView(model: self))
    }

    /// 录制窗口被关掉。
    ///
    /// 还在录就必须停下来：麦克风会一直开着，而界面已经不见了——那段音频
    /// 最终会写到用户看不见的那一条名下。这里走 `toggleBenchRecording()`
    /// 正常收尾，已经录进去的部分照常写成当前这条的 WAV，不白录。
    private func benchWindowDidClose() {
        guard benchIsRecording else { return }
        // **先做再记，而且记的是结果。** 原先是无条件先打「已停止并写出」
        // 再调用——被 guard 挡下时日志照样说停了，而麦克风还开着。
        // 排查时日志是唯一线索，它谎报一次就够让人走错方向。
        toggleBenchRecording()
        if benchIsRecording {
            AppLogger.shared.log("录制窗口关闭，但停止失败，仍在录音")
        } else {
            AppLogger.shared.log("录制窗口关闭时仍在录音，已停止并写出当前这条")
        }
    }

    /// `toggleBenchRecording` 该做什么。
    ///
    /// 抽成纯函数是为了能测：真要走进那个方法得先让 `benchIsRecording`
    /// 为真，而那需要真启动麦克风——测试进程拿不到麦克风权限（TCC 绑 app
    /// bundle）。判断本身与硬件无关，抽出来就钉得住。
    enum BenchToggleAction: Equatable {
        case stop
        case start
        /// 听写占着麦克风，不能**开始**录制。
        case rejectBusy
    }

    /// **停止永远允许，忙碌只拦开始。**
    ///
    /// 原先的实现把忙碌 guard 写在停止分支前面，于是连「停止」都被拦下。
    /// 失效链：录制中按遥控器语音键（那条路径当时漏查 `benchIsRecording`，
    /// 见 `startRemote`）→ 听写非 idle → 关掉录制窗口 → 停止被拦 →
    /// 麦克风一直开着、`benchIsRecording` 卡在 true、⌥D 从此被永久拒绝，
    /// 而窗口已经关了，**没有任何 UI 能清掉这个状态**。
    ///
    /// 停止本身永远是安全的：只是关掉麦克风、写出已录到的部分。
    static func benchToggleAction(
        isRecording: Bool,
        dictationIdle: Bool
    ) -> BenchToggleAction {
        if isRecording { return .stop }
        return dictationIdle ? .start : .rejectBusy
    }

    /// 遥控器语音键是否可以开始一次听写。
    ///
    /// 抽出来的理由同上，外加一条：这两个条件必须**同时**存在。
    /// 原先这里只查了模型加载，注释却写着「与 ⌥D 的守卫保持一致」——
    /// ⌥D 有两条，这里只有一条。漏掉的后果不是「多录一次」，是两个
    /// `AVAudioEngine` 抢同一支麦克风。
    static func remoteStartAllowed(
        modelLoading: Bool,
        benchRecording: Bool
    ) -> Bool {
        !modelLoading && !benchRecording
    }

    /// 开始/结束录当前这条。
    func toggleBenchRecording() {
        guard let bench = benchSession, let entry = bench.current else { return }

        switch Self.benchToggleAction(
            isRecording: benchIsRecording,
            dictationIdle: (session?.state ?? .idle) == .idle
        ) {
        case .rejectBusy:
            AppLogger.shared.log("听写进行中，基准集录制已忽略")
            return
        case .stop, .start:
            break
        }

        if benchIsRecording {
            benchMicSource?.stop()
            benchIsRecording = false
            do {
                try BenchRecorder.writeWAV(
                    samples: benchSamples, to: BenchManifest.audioURL(for: entry)
                )
                AppLogger.shared.log("基准集已录：\(entry.id) 共 \(benchSamples.count) 样本")
            } catch {
                AppLogger.shared.log("基准集写出失败 \(entry.id)：\(error)")
            }
            benchSamples = []
            return
        }

        benchSamples = []
        let mic = benchMicSource ?? SystemMicSource()
        benchMicSource = mic
        mic.onFrame = { [weak self] samples in
            self?.benchSamples.append(contentsOf: samples)
        }
        do {
            try mic.start()
            benchIsRecording = true
            AppLogger.shared.log("基准集开始录：\(entry.id)")
        } catch {
            AppLogger.shared.log("基准集录音启动失败：\(error)")
        }
    }

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

        // 通知拿不到授权时退回 HUD 提示。这条退路不是补丁：通知权限是个
        // 新弹窗，用户划掉或拒掉之后剪贴板兜底就会静默失效——而它兜的正是
        // 「说的话没落地也没留下副本」那类问题。
        let presenter = NotificationPresenter(notifier: SystemNotifier()) { [weak self] notice in
            self?.showHUDNotice(notice)
        }
        notificationPresenter = presenter

        let session = DictationSession(
            audioSource: router,
            transcriber: transcriber,
            sink: RoutingTextSink(
                typing: TypingSink(),
                clipboard: ClipboardSink()
            ),
            targetGuard: TargetAppGuard(),
            rescue: TextRescue(clipboard: ClipboardSink(), presenter: presenter)
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
            // 每次状态变化都同步，而不是只在回到 idle 时同步：新会话一
            // 开始 `retainedSamples` 就被清掉，菜单项必须立刻跟着灰掉，
            // 否则录音途中点它是「点得动但什么都不发生」。
            self.canRetry = self.session?.canRetry ?? false

            // **从 idle 进入任何非 idle 状态都要开 HUD，不能只认 .listening。**
            //
            // 重试走的是 .idle → .transcribing → …（`retry()` 不经过
            // .listening），只认 .listening 的话：菜单点重试 → 转写成功 →
            // 面板从未 orderFront → 用户什么都看不到，随后 endHUD 还会排一个
            // 停留计时器去收一个从没显示过的面板。**③ 的未校正标注在 ②
            // 这条路上等于不存在。** 独立验收 2026-08-17 指出。
            //
            // 判「上一个状态是不是 idle」而不是每次都调：beginHUD 会重置
            // 计时器与附注，在 .listening → .transcribing 上重复调用会把
            // 已经计的时长和刚产生的标注一起清掉。
            let wasIdle = self.lastSessionState == .idle
            self.lastSessionState = state
            if state != .idle, wasIdle {
                // 重试没有在录音：波形与时长计时器都不该跑，跑了显示的是
                // 上一次的能量和一个从零开始的假时长。
                self.beginHUD(recording: state == .listening)
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
        // 标注在 .correcting 与 .injecting 之间产生，那时 HUD 还开着；
        // 真正让它被看见的是 endHUD 的停留（见 hudNoticeLinger）——
        // 这两步之间只隔几十毫秒，不停留等于没显示。
        session.onCorrection = { [weak self] annotation in
            self?.hudModel.notice = annotation?.hudLabel
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
        // 把内容日志的开关状态记下来：排查校正质量时若忘了开，
        // 日志里只有「文本长度 8 字」，会白白浪费一轮真机测试。
        if AppLogger.shared.logsTranscripts {
            AppLogger.shared.log("内容日志已开启（VINPUT_LOG_TRANSCRIPTS=1），日志将包含转写全文")
        }
        // 同理把基准集入口的开关记下来：菜单项藏没藏住只能靠肉眼看，
        // 而日志里有这一行就能事后确认这次启动到底读到了什么。
        if Self.benchEnabled {
            AppLogger.shared.log("基准集录制入口已启用（VINPUT_BENCH=1），录音会写入 Bench/audio")
        }
        if Self.bleScanEnabled {
            AppLogger.shared.log(
                "BLE 扫描诊断已启用（\(BLEScanGate.enableKey)=1），目标=\(BLEScanGate.targetName)"
            )
        }

        do {
            try hotkey.register(keyCode: hotkeyCode, modifiers: hotkeyModifiers) { [weak self] in
                self?.toggle()
            }
        } catch {
            phase = .error("快捷键注册失败：\(error)")
        }

        // 把通知授权弹窗提前到启动时问掉。**不能等到第一次注入失败再问**：
        // 那一刻用户人在别的应用里、手上还有一句话要救，是最不该被打断的
        // 时机，而弹窗本身还会抢焦点，反过来把注入目标搅得更乱。
        Task { await presenter.primeAuthorization() }

        // 预览引擎依赖已加载的模型，异步挂载。
        Task { await warmUpAndAttachPreview() }

        startRemote()

        if Self.bleScanEnabled { scheduleBLEScanStart() }
    }

    func shutdown() {
        hotkey.unregister()
        stopRemote()
        stopBLEScan()
    }

    // MARK: - HUD

    /// - Parameter recording: 本次是否真的在录音。重试（`retry()`）没有录音，
    ///   此时不启动波形与时长计时器——跑了只会显示上一次的能量和一个从零
    ///   开始的假时长。
    private func beginHUD(recording: Bool = true) {
        hudModel.preview = .empty
        hudModel.energy = []
        hudModel.elapsed = 0
        hudModel.previewDegraded = false
        // 上一轮的附注与它的收起计时器必须一起清掉：不清计时器的话，
        // 它会在新会话进行到一半时把面板关掉。
        hudModel.notice = nil
        hudNoticeTimer?.invalidate()
        hudNoticeTimer = nil
        recordingStartedAt = recording ? Date() : nil
        hud.show()

        guard recording else {
            hudTimer?.invalidate()
            hudTimer = nil
            return
        }

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
        // 有附注就让面板多停一会儿，没有就照旧立刻收起。
        if hudModel.notice == nil {
            hud.hide()
        } else {
            scheduleHUDNoticeHide()
        }

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

    /// 把一行附注显示在 HUD 上，并让面板停留几秒。
    ///
    /// 会话已经结束、面板已经收起时也要能用——通知投递不出去这条退路正是
    /// 在那之后触发的，所以这里主动 `show()`。
    func showHUDNotice(_ text: String) {
        hudModel.notice = text
        hud.show()
        scheduleHUDNoticeHide()
    }

    private func scheduleHUDNoticeHide() {
        hudNoticeTimer?.invalidate()
        hudNoticeTimer = Timer.scheduledTimer(
            withTimeInterval: Self.hudNoticeLinger, repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 这几秒里用户又开始说话了就别收：新会话的 beginHUD 已经把
                // 面板重新点亮，这时候关掉等于把正在用的 HUD 关了。
                guard (self.session?.state ?? .idle) == .idle else { return }
                self.hudModel.notice = nil
                self.hud.hide()
            }
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
        // 基准集录制中不接受听写：两者用的是同一支麦克风的两个
        // AVAudioEngine，同时开会打架。反向的 guard 在
        // toggleBenchRecording 里，这两条必须成对存在——只挡一个方向的话，
        // 用户先开录制再按 ⌥D 照样能撞上。开发期功能，正常分发下恒为 false。
        guard !benchIsRecording else {
            log.log("toggle 被拒：基准集录制进行中")
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

    /// 用上一次转写失败时保留的音频再走一遍（M6 ②）。
    ///
    /// **入口放菜单栏**，理由是状态一直可见、不占用新的全局快捷键（与现有
    /// ⌥D 及其他应用有冲突风险）、也不依赖通知权限——放通知按钮里的话，
    /// 通知被划掉入口就没了。
    func retryLastTranscription() {
        guard let session, session.canRetry else {
            AppLogger.shared.log("重试被拒：当前没有可重试的音频")
            return
        }
        AppLogger.shared.log("用户从菜单栏发起重试，保留样本 \(session.retainedSampleCount) 个")
        Task { await session.retry() }
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
    ///
    /// **`emptyResult` 刻意归在「要展示」这一侧**，尽管它也可能只是
    /// 用户录了一段静音。理由是两者的代价不对称：多弹一次「没有识别到内容」
    /// 只是噪音，而静默关掉 HUD 会让用户以为已经注入成功——那正是这一轮
    /// 修的短句消失问题里最难被察觉的部分。
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
            // 两个条件缺一不可，判据见 AppModel.remoteStartAllowed。
            // 基准集那条以前漏了，而注释却写着「与 ⌥D 的守卫保持一致」。
            guard Self.remoteStartAllowed(
                modelLoading: self.loadingModelName != nil,
                benchRecording: self.benchIsRecording
            ) else {
                AppLogger.shared.log(
                    "遥控器录音被拒：模型加载中=\(self.loadingModelName != nil) "
                        + "基准集录制中=\(self.benchIsRecording)"
                )
                return
            }
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

    // MARK: - BLE 扫描诊断（开发期工具）

    /// 扫描诊断是否可用。**开发期工具，默认隐藏**，理由同 `benchEnabled`：
    /// 它会连一台与主功能无关的蓝牙设备，并把原始字节写到磁盘。
    ///
    /// 用途见 `BLEScanner` 的文件头——查清那支蓝牙鼠标的音频走什么协议。
    nonisolated static var bleScanEnabled: Bool { BLEScanGate.isEnabled }

    /// 延后几秒再开扫。
    ///
    /// **让遥控器桥先抢到 RC003。** 两个 `CBCentralManager` 同时扫描是允许
    /// 的，但用户每天在用遥控器听写，把诊断工具排在主功能后面是免费的保险。
    private func scheduleBLEScanStart() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.startBLEScan() }
        }
    }

    func startBLEScan() {
        guard Self.bleScanEnabled else { return }
        if bleScanner?.isRunning == true {
            AppLogger.shared.log("BLESCAN 已在扫描中")
            return
        }
        let fileLog = bleScanFileLog ?? BLEScanFileLog()
        bleScanFileLog = fileLog

        let scanner = BLEScanner(
            targetName: BLEScanGate.targetName,
            // 遥控器当前占着的那台一律排除。这是「不打断 RC003」这条约束
            // 在代码里的落点之一，另外两处在 BLEScanTargetMatcher。
            excludedIdentifiers: { [weak self] in
                guard let identifier = self?.bluetoothBridge?.deviceIdentifier else { return [] }
                return [identifier]
            },
            fileLog: fileLog
        )
        bleScanner = scanner
        scanner.start()

        // GATT 与 HID 两条路一起看：macOS 会把 HID over GATT 从
        // CoreBluetooth 里滤掉，只扫 GATT 有可能一无所获，而真机每跑一轮
        // 都要用户坐在电脑前按键。理由详见 HIDReportProbe 的文件头。
        let probe = HIDReportProbe(targetName: BLEScanGate.targetName, fileLog: fileLog)
        hidProbe = probe
        probe.start()
    }

    func stopBLEScan() {
        hidProbe?.stop()
        hidProbe = nil
        bleScanner?.stop()
        bleScanner = nil
        if let path = bleScanFileLog?.path {
            AppLogger.shared.log("BLESCAN 原始包已写入 \(path)")
        }
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
