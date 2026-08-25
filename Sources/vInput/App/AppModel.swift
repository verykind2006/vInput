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
    /// 实际生效的模型目录。空字符串表示**一个模型都没有**。
    ///
    /// 单独存一份而不是从 `availableModels` 推：用户可以经「其他目录…」
    /// 用一个根目录外面的模型，那时列表可能仍是空的，而模型确实有一个。
    private(set) var activeModelFolder: String = ""
    /// 模型根目录（以及用户导入的目录）里发现的全部可用模型，供菜单列出。
    private(set) var availableModels: [ModelDescriptor] = []
    /// 正在加载模型。首次使用某模型时 Core ML 要编译到神经引擎，
    /// 实测可达 40–125 秒，期间必须让用户看到进度而不是以为卡死。
    private(set) var loadingModelName: String?
    /// 最近一次模型加载失败的整句话；开始下一次加载或加载成功时清空。
    ///
    /// 与 `phase = .error` 分开存：`phase` 会被任何别的错误覆盖、也会被下一次
    /// 听写重置，而向导第五步要在用户回来看的时候还能说清「模型为什么没好」。
    private(set) var modelLoadFailure: String?
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

    /// 当前输出语言，菜单据此显示。
    ///
    /// 真实存储在 UserDefaults（需跨启动保留），这里是它的可观察镜像：
    /// @Observable 只跟踪自身的存储属性，若菜单直接读 UserDefaults，
    /// 点完标题不会刷新（与 `correctionEnabled` 同一个坑）。
    private(set) var outputLanguage: Language = .chinese

    /// 选了外语，却一个可用的翻译模型目录都没有。
    ///
    /// **这个状态必须能被看见。** 没有它的话，用户在菜单里选完「西班牙文」
    /// 之后什么都不会发生，而菜单上还写着「输出语言：西班牙文」——用户
    /// 看到的只有「没变化」，无从判断是哪一种（M6 ③ 修掉的正是这一类）。
    /// 菜单标题据此加后缀，切换语言的那一刻另有一次 HUD 提示。
    ///
    /// **做成常驻后缀而不是只弹一次**：弹窗切走再切回来就看不到了，
    /// 而「为什么没翻译」是个会反复被问起的问题。
    private(set) var translationModelMissing: Bool = false

    /// 翻译**由谁来做**：本机，还是云端 Google。菜单据此显示。
    ///
    /// 与 `outputLanguage` 是两件事：那个决定「译成什么」，这个决定「谁来译」。
    /// 用户 2026-08-19 专门强调过别把这两个开关搅在一起。
    ///
    /// 取值由 `translationBackendStatus` 从**协调器真正算出来的那个挂载结论**
    /// 推出来（而不是把偏好里的布尔值直接抄给菜单）：抄布尔值的话，
    /// 「云端开着但输出语言是中文」这一格会显示成「每句话都会发出」，
    /// 而真实行为是一个字节都不出站——菜单就在骗人。
    private(set) var translationBackend: TranslationBackendStatus = .local

    /// 当前**实际**在用的本机翻译模型目录名。没有可用目录时为 nil。
    ///
    /// 「实际」两个字是重点：它可能来自 `translation.modelDirectory`，
    /// 也可能是退回校正层的目录借来的。菜单必须把这两种情况说清楚，
    /// 否则用户换了校正模型会莫名其妙发现翻译也跟着变了。
    private(set) var translationModelName: String?

    /// 上面那个目录是不是**借来的**（用户没单独给翻译指定）。
    private(set) var translationModelIsInherited: Bool = true

    /// 云端选中的模型。菜单据此显示。
    private(set) var cloudModel: CloudTranslationModel = .default

    /// Keychain 里有没有 API key。
    ///
    /// **是缓存不是实时值**：每次打开菜单都读一次 Keychain 会弹系统授权框，
    /// 而菜单是每天点很多次的东西（见 `TranslationAttachmentCoordinator`
    /// 里同一条权衡）。用户存完 key 我们当场更新它，不必等下一次挂载。
    private(set) var hasCloudAPIKey: Bool = false

    /// 此刻在飞的模型下载进度（0…1）。nil 表示没有下载在跑。
    ///
    /// 由向导报进来（`OnboardingCoordinator.Wiring.onDownloadProgress`）。
    /// **关掉向导不取消下载**——不接这一路的话，那十几分钟里应用看上去
    /// 什么都没在做，然后忽然自己进入加载态。面板上那行「正在下载模型 42%」
    /// 读的就是它。
    private(set) var downloadingModelProgress: Double?

    /// 下载源：nil = 自动（并发探测谁快用谁），非 nil = 用户在「高级」里强制。
    ///
    /// 又一个 UserDefaults 的可观察镜像（理由同 `correctionEnabled`）。
    /// 真实存储与那个 key 都在 `DownloadSourcePreference` 里，全仓一处。
    private(set) var forcedDownloadSource: DownloadSource?

    /// 下载好了但还没换上去的模型目录（会话进行中被推迟的那一个）。
    /// 面板据此显示「结束后自动启用」。判断与记账都在 `ModelAdoptionQueue`。
    ///
    /// **必须是本类的存储属性，不能写成 `{ modelAdoption.pendingFolder }`。**
    /// `@Observable` 只跟踪自己的可变存储属性——`ModelAdoptionQueue` 是个普通
    /// 类，改它的字段不通知任何人，那样写的话这一行「能显示」纯属巧合：
    /// `adoptDownloadedModel` 恰好先调了 `refreshAvailableModels()`、紧接着
    /// 进度回调又动了 `downloadingModelProgress`，是这两个**被观察的**属性
    /// 顺手让面板失效的。任何一处顺序调整都会静默干掉这一行。
    /// 这与 `canRetry` / `correctionEnabled` 是同一条规矩（见它们的注释）。
    private(set) var pendingModelFolder: String?

    private let permissions = Permissions()
    /// 下载源偏好。key 只在 `DownloadSourcePreference` 里写一次，
    /// 向导那侧读的是同一个类型——两边各写一遍字面量的话，拼错的表现是
    /// 「这个设置什么都不做」，而面板上照样打着勾。
    private let downloadSourcePreference = DownloadSourcePreference()
    /// 「我已经有模型文件」导入进来的那些目录。不记的话它们只活一次启动，
    /// 理由见该类型的注释。
    private let importedModels = ImportedModelPreference()
    /// 「下载好的模型什么时候真的换上去」。理由见该类型的注释：
    /// 正录着的时候下载完，`selectModel` 会打一行日志就返回，
    /// 而此后**再也没有人重试**。
    ///
    /// internal 而不是 private：量面板高度的那条用例要摆出「有一个待启用的
    /// 模型」这个最坏状态，而真机上进到这个状态要靠「下载恰好在录音途中
    /// 完成」，测试进程里造不出来（`session` 起不来，`canSwitchModel` 恒真）。
    let modelAdoption = ModelAdoptionQueue()
    /// 校正偏好。开关状态与模型目录都要跨启动保留。
    private let correctionPreference = CorrectionPreference()
    /// 翻译偏好。输出语言、云端开关、模型目录都要跨启动保留。
    private let translationPreference = TranslationPreference()
    /// 输入语言偏好。转写解码与翻译源语言都读它，同样跨启动保留。
    private let inputLanguagePreference = InputLanguagePreference()
    /// 「校正能不能开」的判定。全部规则都在它那边，这里只负责把结果
    /// 翻译成弹面板与错误提示。
    private let correctionActivation: CorrectionActivation
    /// 弹出校正模型目录选择器，返回用户选中的目录（取消时为 nil）。
    ///
    /// 由 UI 层注入：`AppModel` 不该知道 `NSOpenPanel` 的存在，而「开启校正
    /// 时若无合法模型就弹选择器」这条流程必须能在没有 UI 的测试里驱动。
    var chooseCorrectionModelFolder: (@MainActor () -> URL?)?

    /// 选翻译模型目录的面板。与 `chooseCorrectionModelFolder` 同一条分工。
    var chooseTranslationModelFolder: (@MainActor () -> URL?)?

    /// 让用户输入云端 API key 的面板。返回 nil 表示取消。
    ///
    /// **返回的字符串是密钥本身，绝不可以进日志。** 调用点只记「成功/失败」。
    var promptForCloudAPIKey: (@MainActor () -> String?)?

    /// 让用户输入自定义云端模型标识符的面板。
    var promptForCloudModelIdentifier: (@MainActor (String) -> String?)?
    /// 弹出「开启云端翻译」的确认，返回用户是否确认。
    ///
    /// 与 `chooseCorrectionModelFolder` 同一条分工：`AppModel` 不该知道
    /// `NSAlert` 的存在，而「开启前必须先确认」这条流程要能被扫源码钉住。
    ///
    /// **没接上 UI 时默认不开**（`useCloudBackend` 里的 `?? false`）：
    /// 一个出站开关的失败方向只能是「不出站」。
    var confirmCloudBackend: (@MainActor () -> Bool)?
    /// 上一次挂载校正流水线被会话拒绝（当时不在 idle）。
    ///
    /// 用户在录音中或转写那几秒里改设置是很自然的动作，而
    /// `DictationSession` 只在 idle 时接受挂载。不记住这件事的话，
    /// 那次改动就永远丢失了——而菜单已经显示成新状态，等于在骗人。
    private var correctionApplyPending = false
    /// 翻译层的挂载状态机（挂什么、挂不上时记着、回到 idle 补挂）。
    ///
    /// **这段逻辑刻意不长在 `AppModel` 里**：本类在测试进程里起不来
    /// （init 就要真快捷键、真 CGEvent tap），长在这里就等于零覆盖——
    /// 两条变异（删掉挂载那句、丢掉待补挂）实测都是 899/899 全绿
    /// （2026-08-19 把本文件退回搬家前的版本重跑确认过）。
    /// 搬进 `TranslationAttachmentCoordinator` 之后两条各自有用例红，
    /// 理由与「怎么保证抽出来的就是实际跑的」写在那边的类型注释里。
    ///
    /// 可选是因为它要在 `bootstrap` 里等会话建好之后才能构造；
    /// 不能用 `lazy`——@Observable 宏为存储属性生成 init accessor，与 lazy
    /// 的存储语义冲突，编译期报错（同 HUD 那几个字段）。
    private var translationCoordinator: TranslationAttachmentCoordinator?
    private let hotkey = HotkeyRegistrar()
    private var session: DictationSession?

    /// 遥控器按键映射用的注入器（关机键→退格、「·」键→空格）。
    /// 与鼠标桥各持一个 `SystemKeyPoster` 同一个形态；
    /// 替身注入点留给将来的接线测试。
    private let remoteKeyPoster: KeyPoster = SystemKeyPoster()
    private var transcriber: SwitchableTranscriber?
    private var modelRoot: String = ""

    /// 会话的注入口。平常是纯转发，首次启动向导的「试说一句」期间改道到
    /// 向导自己的输入框（见 `RedirectableTextSink`）。
    private var redirectSink: RedirectableTextSink?

    /// 模型根目录。向导要拿它算下载去处——必须与这里用的是同一个地方，
    /// 各算各的就会「下载 1.5GB 然后报告找不到模型」。
    var modelRootPath: String { modelRoot }

    /// 挂上 / 摘掉转写改道。传 nil 摘掉，文本回到平常那条路。
    ///
    /// 闭包返回 `true` 表示「这一次归我，别再往下送」，返回 `false` 表示
    /// 「不归我」——**无条件吞会让向导开着时别的应用里的听写凭空消失**，
    /// 理由见 `RedirectableTextSink`。
    func setTranscriptRedirect(_ handler: ((String) -> Bool)?) {
        redirectSink?.redirect = handler
        AppLogger.shared.log("转写改道：\(handler == nil ? "已摘掉" : "已挂上")")
    }

    private(set) var remoteState: RemoteConnectionState = .disconnected
    private(set) var remoteBattery: Int?

    private(set) var mouseState: MouseBridgeState = .stopped
    private(set) var mouseBattery: Int?

    private let bluetoothSource = BluetoothRemoteSource()
    /// 蓝牙鼠标那一路的音频源（第三个源，M7）。
    private let mouseSource = MouseAudioSource()
    private let hidListener = RemoteHIDListener()
    private let keySuppressor = RemoteKeySuppressor()
    /// 「·」键与菜单键那两路的回声吞键器。**刻意与 `keySuppressor` 分开**：
    /// 那个是会话作用域的、坐在听写主路径上、有过 tap 生命周期崩溃史
    /// （`6a24f18`），这个是常开的。分开之后这里出问题最多是原始按键不被吞，
    /// 听写照常。两个键共用一个实例的理由见 `RemoteEchoSwallower` 的注释。
    private let echoSwallower = RemoteEchoSwallower()
    /// 菜单键那一路的应用切换器。**按住 Command 跨越多次按键**，用户才能在
    /// 最近使用列表里连着往后翻（2026-08-22 真机验收后改的，原来一次按一次
    /// 松，只能在两个应用之间来回）。五道「别把 Command 卡住」的兜底见
    /// `AppSwitcher` 的类型注释。
    ///
    /// `lazy` 是因为它要用同一个 `remoteKeyPoster`，而存储属性的默认值里
    /// 引用不到别的存储属性；`@ObservationIgnored` 是因为 `@Observable` 会把
    /// 普通存储属性改写成计算属性，而 `lazy` 用不了计算属性。它也确实不该
    /// 参与视图刷新。
    @ObservationIgnored private lazy var appSwitcher = AppSwitcher(poster: remoteKeyPoster)
    private let keepalive = VoiceSessionKeepalive()
    private var remoteCoordinator: RemoteCoordinator?
    private var bluetoothBridge: XiaomiBluetoothBridge?
    private var mouseCoordinator: MouseCoordinator?
    private var mouseBridge: MouseBluetoothBridge?
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
    private let zoomHotkeys: ZoomHotkeyController
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

    /// 关机键按下时要不要注退格。抽成纯函数以便单测（真 HID 设备进不了
    /// 测试进程，接线闭包本身只能真机验）。
    ///
    /// **录音中忽略**：说话时误碰关机键去删目标应用里的字，比什么都
    /// 不做更糟——与「会话期间按键抑制」同一条哲学（宁可少动作，
    /// 不要错动作）。
    nonisolated static func powerKeyPostsBackspace(dictationIdle: Bool) -> Bool {
        dictationIdle
    }

    /// 遥控器「·」键按下时要不要注空格。理由同上一条：录音时误碰不该往
    /// 目标应用里插东西。
    ///
    /// **注意它只管「注不注空格」，不管「吞不吞原始按键」。**
    /// 那个「·」在任何情况下都不该落到应用里——录音中按了它，正确的结果是
    /// **什么都没发生**，而不是「插了个「·」但没插空格」。所以接线处是先
    /// 无条件 `echoSwallower.arm(.grave)`，再拿本函数决定注不注空格。
    nonisolated static func graveKeyPostsSpace(dictationIdle: Bool) -> Bool {
        dictationIdle
    }

    /// 遥控器菜单键按下时要不要发 Command+Tab（切到上一个应用）。
    /// 理由同上两条：**听写进行中忽略**。
    ///
    /// 这个键的「错动作」比另外两个更重：说到一半突然切走应用，注入的目标
    /// 就变了——转写结果会落到刚切过去的那个窗口里，而不是用户看着的那个。
    /// 与「会话期间按键抑制」同一条哲学：宁可少动作，不要错动作。
    ///
    /// **它同样只管「发不发 Command+Tab」，不管「吞不吞原始按键」。**
    /// 那次原始按键在任何情况下都不该落到应用里——听写中按了它，正确的结果
    /// 是**什么都没发生**，而不是「没切应用但弹出了右键菜单」。所以接线处
    /// 是先无条件 `echoSwallower.arm(.contextualMenu)`，再拿本函数决定。
    nonisolated static func contextMenuKeyPostsAppSwitch(dictationIdle: Bool) -> Bool {
        dictationIdle
    }

    /// 蓝牙设备（遥控器 / 鼠标）的语音键是否可以开始一次听写。
    ///
    /// 抽出来的理由同上，外加一条：这几个条件必须**同时**成立。
    /// 原先这里只查了模型加载，注释却写着「与 ⌥D 的守卫保持一致」——
    /// ⌥D 有两条，这里只有一条。漏掉的后果不是「多录一次」，是两个
    /// `AVAudioEngine` 抢同一支麦克风。
    ///
    /// **M7 加上 `dictationIdle`，因为音频源从两个变成了三个。**
    /// 前两条挡的是「听写 vs 基准集录制」的互斥；三个源之间的互斥是新的
    /// 一条：遥控器正在录时按鼠标语音键，或反过来。
    /// `DictationSession.start()` 自己有 `guard state == .idle`，但它是
    /// **静默**返回的——会话没起来，而这边的按键抑制、路由选择、HUD 都已经
    /// 按「开始了」走了一遍，日志里也没有任何一行说明为什么没录上。
    /// 把条件摆到明面上，拒绝时才有话可说。
    static func voiceDeviceStartAllowed(
        modelLoading: Bool,
        benchRecording: Bool,
        dictationIdle: Bool
    ) -> Bool {
        !modelLoading && !benchRecording && dictationIdle
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
        zoomHotkeys = ZoomHotkeyController(registrar: CarbonZoomHotkeyRegistrar())
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
    ///
    /// internal 而不是 private：空目录那一支（「一个模型都没有」）是本批
    /// 最贵的一条静默失效链，必须真跑一遍才算被守住——而扫源码证明不了
    /// 它返回的是哪个类型。
    nonisolated static func makeTranscriber(_ model: ModelDescriptor) -> Transcriber {
        // **空 folder 不再等于「让 WhisperKit 按名字去下载」。**
        // 那条路会在用户没要求的情况下从官方源拉一个 140MB 的
        // openai_whisper-base（还忽略他刚选定的下载源），整个理由写在
        // `MissingModelTranscriber` 的类型注释里。
        guard !model.folder.isEmpty else { return MissingModelTranscriber() }
        return WhisperKitTranscriber(
            modelName: model.name,
            modelFolder: model.folder,
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
        // 下载源同样是「上次退出时选的」，面板打开即是正确状态。
        forcedDownloadSource = downloadSourcePreference.forced
        // **必须排在造 transcriber 之前**：它设的 `HF_ENDPOINT` 是 WhisperKit
        // 取 tokenizer 时唯一认得的判据（那个入口没有 endpoint 参数），
        // 而 tokenizer 是 `prepare()` 里取的。排在后面等于这一轮启动的
        // 每一次模型加载都仍然去连官方源——国内用户会在那里挂住。
        // 全部理由在 `HuggingFaceEndpoint` 的类型注释里。
        HuggingFaceEndpoint.applyFromPreference(downloadSourcePreference)

        modelRoot = ModelCatalog.resolveRoot(
            appSupport: ModelCatalog.applicationSupportRoot(
                home: NSHomeDirectory()),
            developmentRoot: ModelCatalog.defaultRoot(appBundleURL: Bundle.main.bundleURL),
            exists: { FileManager.default.fileExists(atPath: $0) }
        )
        // 导入的目录先复核一遍：搬走了/删掉了就当场忘掉，不再挂在列表里
        // 让用户每次点都得到一句「这不是模型目录」。做法与
        // `correctionActivation.revalidateAtLaunch()` 是同一条。
        let forgotten = importedModels.revalidate { folder in
            if case .success = ModelCatalog.validate(folder: folder) { return true }
            return false
        }
        if !forgotten.isEmpty {
            AppLogger.shared.log("启动自检：导入的模型目录已失效，已忘记 \(forgotten)")
        }
        availableModels = discoverModels()

        // **本地一个模型都没有时不再退化成「让 WhisperKit 自行下载」。**
        // 那条路会在用户没要求的情况下拉一个 140MB 的 base 模型，而且走的是
        // 官方源（忽略他刚在向导里被指定的那个）。现在如实占一个空位，
        // 转写器是 `MissingModelTranscriber`（立刻失败、绝不联网），
        // 面板头部据 `hasModel` 说「还没有语音模型」。
        let initial = availableModels.first ?? ModelCatalog.noModel
        activeModelName = initial.name
        activeModelFolder = initial.folder

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
            .mouse: mouseSource,
        ])
        self.audioRouter = router

        // 通知拿不到授权时退回 HUD 提示。这条退路不是补丁：通知权限是个
        // 新弹窗，用户划掉或拒掉之后剪贴板兜底就会静默失效——而它兜的正是
        // 「说的话没落地也没留下副本」那类问题。
        let presenter = NotificationPresenter(notifier: SystemNotifier()) { [weak self] notice in
            self?.showHUDNotice(notice)
        }
        notificationPresenter = presenter

        let redirectSink = RedirectableTextSink(
            fallback: RoutingTextSink(
                typing: TypingSink(),
                clipboard: ClipboardSink()
            ))
        self.redirectSink = redirectSink

        let session = DictationSession(
            audioSource: router,
            transcriber: transcriber,
            // 平常那条路原样保留，外面再包一层可改道的壳。首次启动向导的
            // 「试说一句」要把文字落进向导自己的输入框，而 `DictationSession.sink`
            // 是 `let`、会话建好之后换不掉——包一个引用类型进去，改它的属性即可。
            // 没挂改道时它是纯转发，行为与原来一字不差。
            sink: redirectSink,
            targetGuard: TargetAppGuard(),
            rescue: TextRescue(clipboard: ClipboardSink(), presenter: presenter)
        )

        session.onStateChange = { [weak self] state in
            guard let self else { return }
            // **听写一开始就把按住的 Command 抬起来。**
            //
            // `contextMenuKeyPostsAppSwitch(dictationIdle:)` 那个守卫只挡
            // **新按键**，挡不住一个**已经按住**的 Command：用户按了菜单键、
            // 在那 0.7 秒里又按了语音键开始说话，Command 就会一直按到停手
            // 计时器到点为止，期间语音键那一路的按键全变成快捷键。
            //
            // 挂在 `onStateChange` 而不是三个 `session.start()` 调用点上：
            // ⌥D、遥控器、鼠标三条路都汇到这一个回调，逐个去接迟早漏一个
            // ——同 `keySuppressor.update(for:)` 那条教训（Esc 那个出口就漏过）。
            // `release` 是幂等的，非 idle 状态每次都调也无害。
            if state != .idle { self.appSwitcher.release(reason: .dictation) }
            switch state {
            case .idle:
                self.phase = .idle
                // 会话结束，把此前被拒绝的挂载补上。
                if self.correctionApplyPending { self.applyCorrectionPreference() }
                // 翻译的补挂**必须排在校正之后**，与 bootstrap 里那次同一个
                // 理由：翻译没配自己的模型目录时要退回校正层的目录，顺序反了
                // 会拿到上一轮那个可能刚被判掉的路径。
                //
                // 「有没有待补挂」由协调器自己判（那条判断在这里就没人守得住，
                // 见 `TranslationAttachmentCoordinator` 的类型注释）。
                self.translationCoordinator?.sessionDidBecomeIdle()
                self.syncTranslationMirrors()
                // 会话结束，把此前被推迟的模型换用补上（下载在录音途中完成的
                // 那种情况）。不补的话用户刚下的 1.5GB 要等到下次启动才生效。
                self.applyPendingModelAdoption()
            case .listening: self.phase = .listening
            // 校正、翻译与转写、注入同归 working：Phase 是给菜单栏用的粗粒度
            // 状态，不必区分到这一级，细节由 HUD 呈现。
            case .transcribing, .correcting, .translating, .injecting:
                self.phase = .working
                // **模型这次真的加载成功了，把上一次的失败擦掉。**
                //
                // 原先只有两个清空点（预热成功、`selectModel` 开始），于是有
                // 一条永远擦不掉的路：盘上是没打包的变体 + 断网 → 预热被
                // `TokenizerPreflight` 判死、写下红字 → 网络恢复 → 用户按 ⌥D，
                // `transcribe()` 里 `prepare()` 重跑、这次通了 → 听写完全正常，
                // 但预热只跑一次，点当前模型又被 `selectModel` 的
                // `guard model.name != activeModelName` 挡掉 → 向导第五步永远
                // 挂着一句「加载模型失败」，旁边是个好用的「开始说话」。
                //
                // **`.transcribing` 不算数**：`prepare()` 就在它里面跑，那时
                // 还没有结论。到得了后面三个状态才说明转写真的出了文本。
                if state != .transcribing { self.modelLoadFailure = nil }
            }
            self.hudModel.phase = state
            self.cancelHotkey.update(for: state)
            self.zoomHotkeys.update(for: state)
            // 按键抑制跟着会话状态自己收。**离开 .listening 的出口不止一个**
            // （松开语音键、撞时长上限、转写失败、按 Esc 取消），逐个出口去调
            // endSuppressing() 迟早会漏一个——Esc 那条就漏了，见下面
            // cancelHotkey.onCancel 的注释。理由与语义见
            // RemoteKeySuppressor.update(for:)：只收不开。
            self.keySuppressor.update(for: state)
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
        // 翻译标注走同一条路：产生的时刻紧挨着校正标注（.translating 与
        // .injecting 之间），同样靠 endHUD 的停留才被看见。
        //
        // **不能照抄上面那行赋值。** 翻译回调排在校正回调之后，写成
        // `notice = annotation?.hudLabel` 的话，一次正常译出（标注为 nil）
        // 会把刚写进去的校正标注**抹掉**——用户看到的是「校正好像没运行」。
        // 走 `applyTranslationAnnotation`，它对 nil 的语义是「什么都不做」。
        session.onTranslation = { [weak self] annotation in
            guard let self else { return }
            AppModel.applyTranslationAnnotation(annotation, to: self.hudModel)
        }
        self.session = session
        // 协调器要等会话建好才能构造。捕获的是三个偏好结构体本身而不是
        // `self`：它们只是 UserDefaults 的取值器（`nonmutating set`），
        // 每次 `apply()` 都会重新读一遍——补挂那次必须读**当时**的偏好，
        // 而不是第一次被拒时的快照。
        let translationPreference = self.translationPreference
        let correctionPreference = self.correctionPreference
        let inputLanguagePreference = self.inputLanguagePreference
        translationCoordinator = TranslationAttachmentCoordinator(
            inputs: {
                TranslationAttachmentCoordinator.Inputs(
                    input: inputLanguagePreference.language,
                    choice: translationPreference.choice,
                    usesCloudBackend: translationPreference.usesCloudBackend,
                    translationModelDirectory: translationPreference.modelDirectory,
                    correctionModelDirectory: correctionPreference.modelDirectory,
                    cloudModel: translationPreference.cloudModel.identifier
                )
            },
            session: { [weak session] in session },
            makeTranslator: { MLXTranslator(modelDirectory: $0) }
        )
        // 会话与全部回调就绪后再挂校正，让上次启动保存的开关状态生效。
        applyCorrectionPreference()
        // 翻译同理，且**必须排在校正之后**：翻译没配自己的模型目录时要退回
        // 校正层的目录，而校正的启动自检可能刚把一个失效目录判掉。顺序反了
        // 的话翻译会拿到一个已经确认无效的路径。
        applyTranslationPreference()

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
            // **取消也要立刻把按键抑制收掉。**
            //
            // 原来这里只有 cancel()。鼠标那档策略是 `.allExcept([Esc])`，
            // 于是按 Esc 取消之后**整个键盘只剩 Esc 能用**，直到用户松开
            // 鼠标语音键（`0x22` 走 onFinishSession 才自愈）。RC003 那档是
            // `.only([F5])`，同样的不对称从来看不出来——第三个源把旧的缺口
            // 暴露了出来。独立验收 2026-08-18 指出。
            //
            // 上面 onStateChange 里的 update(for:) 已经是一道网，这一行**不是
            // 冗余**：cancel() 是 async 的，状态回到 .idle 要等 Task 被调度，
            // 那期间 tap 还在吃键；而 cancel() 对非 .listening 的会话直接返回，
            // 那种情况下状态变化永远不会来。用户按了取消，键盘就该当场还给他。
            self.keySuppressor.endSuppressing()
            Task { await session.cancel() }
        }
        zoomHotkeys.onIncrease = { [weak self] in self?.hudModel.increaseFontSize() }
        zoomHotkeys.onDecrease = { [weak self] in self?.hudModel.decreaseFontSize() }
        zoomHotkeys.onReset = { [weak self] in self?.hudModel.resetFontSize() }
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
        startMouse()

        if Self.bleScanEnabled { scheduleBLEScanStart() }
    }

    func shutdown() {
        hotkey.unregister()
        stopRemote()
        stopMouse()
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
            modelLoadFailure = nil
            AppLogger.shared.log("模型预热完成")
        } catch {
            AppLogger.shared.log("模型预热失败，本次运行无实时预览：\(error)")
            // 向导第五步也要看得到这一路的失败：没走完的向导每次启动都会
            // 重新出现，而启动预热是那时唯一的一次加载——不写的话，用户看到
            // 的是一个能点的「开始说话」，点下去转写失败，向导上什么都不说。
            // 两句话分开说：有模型是「加载失败」，没模型是「还没有模型」。
            //
            // 原先零模型时**什么都不写**，理由写的是「第四步自己会说」。
            // 2026-08-24 收尾 QA 指出那条理由在一条真实路径上是假的：上次停在
            // 第五步没点完成（step 会持久化，`present()` 直接恢复到第五步），
            // 这次启动模型目录被移走 / 外置盘没挂 → `hasModel` 为假 → 什么都
            // 不写 → 第五步「语音模型还在准备，稍等一下…」**永远**转，按钮
            // 灰着，而**第四步此刻不在屏幕上，向导也没有「上一步」**。
            //
            // 仍然不写成「加载模型「(无)」失败」——那句话既不准，也没法照做。
            modelLoadFailure =
                hasModel
                ? "加载模型「\(activeModelName)」失败：\(error)"
                : "还没有模型。在下面的框里随便打点字就能点「完成」，之后从菜单栏面板的「高级」里下载或选择模型。"
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
            // **翻译层也要重挂，且必须排在 applyCorrectionPreference() 之后。**
            //
            // `correction.modelDirectory` 是翻译层今天**唯一**的模型来源
            // （`translation.modelDirectory` 没有任何入口能设，见
            // `translationAttachment` 的注释）。少了这一句，用户照着
            // 「请在「校正」菜单里指定本地模型目录」那条提示做完之后，
            // 说话出来的还是中文、菜单还挂着「（缺模型目录）」，
            // 要重启才生效——应用亲口给的指令，用户照做，什么都没发生。
            //
            // 顺序的理由与 `bootstrap` 里那一处一字不差：翻译要退回校正层的
            // 目录，而校正的启动自检/开启校验可能刚把一个失效目录判掉。
            applyTranslationPreference()
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
            // 同 `enableCorrection()`：这是写 `correction.modelDirectory` 的
            // 第二条入口，而那个键是翻译层唯一的模型来源。
            //
            // 换模型时不重挂还有第二个后果：翻译层会继续持有**旧目录**的
            // `MLXTranslator`，于是登记处里同时活着两个 `OneShotLoader`、
            // 两份 2 GB 权重常驻——`ModelContainerRegistry` 要省的那一份
            // 正好在这条路径上被吃回去。
            applyTranslationPreference()
            log.log("校正模型已切换：\(descriptor.name)")
        case .rejected(let missing):
            phase = .error("这不是校正模型目录，缺少：\(missing.joined(separator: "、"))")
            log.log("指定校正模型被拒：目录缺少 \(missing.joined(separator: "、"))")
        case .needsModelSelection:
            break
        }
    }

    // MARK: - 翻译

    /// 把翻译标注写到 HUD。
    ///
    /// 抽成静态函数是为了**能测**：`AppModel` 的实例构造会拉起真快捷键、
    /// 真 CGEvent tap 与模型加载，测试进程里跑不动。这与
    /// `benchToggleAction` / `translationAttachment` 是同一个理由。
    ///
    /// **nil 的语义是「什么都不做」，不是「清空」。** 两者的差别不是风格：
    /// 翻译回调排在校正回调之后（`.correcting` → `.translating`），
    /// 写成清空的话，一次**成功**的翻译会把刚写进去的校正标注抹掉，
    /// 而用户会以为校正没运行。`beginHUD` 已经在每次会话开始时清过一遍，
    /// 这里不需要再清（见 `beginHUD` 里那句「上一轮的附注与它的收起计时器
    /// 必须一起清掉」）。
    ///
    /// 正常译出不写任何字：写了的话每句话都要多停 `hudNoticeLinger` 那几秒。
    static func applyTranslationAnnotation(
        _ annotation: TranslationAnnotation?, to hud: HUDViewModel
    ) {
        guard let annotation else { return }
        hud.notice = annotation.hudLabel
    }


    /// 按当前偏好，翻译层该挂什么。
    ///
    /// 抽成纯函数的理由与 `benchToggleAction` / `voiceDeviceStartAllowed`
    /// 一样：`AppModel` 在测试进程里起不来（init 就要真快捷键、真 CGEvent
    /// tap），判断留在方法体里就没有任何东西守得住它——而这里要守的恰恰是
    /// **四种组合都不能错**的那张表。
    enum TranslationAttachment: Equatable {
        /// 不翻译，摘掉流水线。
        case detach
        /// 挂本地 MLX 翻译，用这个模型目录。
        case local(directory: URL)
        /// 要翻译、且选了云端：挂 `GeminiTranslator`。**文字会离开本机。**
        ///
        /// 单列一格是为了让「先判语言、再判后端」这条顺序**有牙口**：
        /// 没有这一格的话，把两个判断对调不会改变任何返回值，
        /// 「云端开着但输出语言是中文时一个字节都不出站」就没有任何
        /// 测试守着。
        ///
        /// **这一格不带模型目录**：云端不需要本地权重，也**不许**在缺 key
        /// 时退回本地——那样用户以为走的是云端，实际跑的是本机模型，
        /// 而这两件事的出站行为正好相反。
        case cloud
        /// 要翻译，但一个模型目录都没有。**不许静默**：调用方要日志 + HUD。
        case unconfigured
    }

    /// - Parameters:
    ///   - target: 输出语言。中文＝不翻译。
    ///   - usesCloudBackend: 云端开关。**只管翻译**，转写与校正永远在本机。
    ///   - translationModelDirectory: `translation.modelDirectory`，通常没配。
    ///   - correctionModelDirectory: 校正层的模型目录，翻译没配时拿它顶上。
    ///
    /// ## 判断顺序：先语言，后后端
    ///
    /// 这两个开关是正交的，四种组合都必须成立：
    ///
    /// | 语言 | 云端 | 行为 | 出站 |
    /// |---|---|---|---|
    /// | 中文 | 关 | 翻译层完全不参与 | 零 |
    /// | 中文 | **开** | **同上** | **零** |
    /// | 外语 | 关 | 本地 `MLXTranslator` | 零 |
    /// | 外语 | 开 | 云端 `GeminiTranslator` | 有 |
    ///
    /// **第二行最容易漏**：用户可能为某次需要打开过云端、之后忘了关。
    /// 只要输出语言是中文，就不该有任何东西出站，也不该弹任何与云端有关的
    /// 提示——所以云端开关的读取必须排在语言 guard **之后**，一格都不能提前。
    ///
    /// ## 模型目录退回校正层，不能静默不翻译
    ///
    /// `translation.modelDirectory` 默认是 nil，而今天**没有任何入口会去设它**
    /// （菜单里只有校正模型选择器）。照着「没配就 return」写的话，用户选完
    /// 「西班牙文」什么都不会发生、也没有任何提示——正是本仓库反复栽的那类
    /// 「静默不工作」。
    ///
    /// 退回校正层的目录是有依据的：M8 第 0 步实测把翻译后端定成了
    /// `qwen3-4b-instruct-2507-4bit`，**正是校正层现在用的同一个模型**。
    /// 这也正是 `ModelContainerRegistry` 能生效的前提——同一个目录 → 同一个键
    /// → 同一份权重，在 16 GB 的目标机上省下一次加载和一份 2 GB 常驻。
    ///
    /// 两个都没配时返回 `.unconfigured`，由调用方记日志并提示，绝不静默。
    ///
    /// ## 借目录也要借校验
    ///
    /// `CorrectionActivation.revalidateAtLaunch()` 在目录失效时只把校正开关
    /// 落回「关」，**不清 `modelDirectory`**（那是对的：用户下次把文件夹挪
    /// 回来就能直接开）。于是翻译层会拿到一条死路径，而
    /// `.local` 一挂上去，菜单不带「（缺模型目录）」后缀、每次听写 HUD 都打
    /// 「翻译模型还在加载，本次注入原文」——`OneShotLoader` 失败不缓存值、
    /// `detachedWarmUp` 用 `try?` 吞掉异常且只调一次，那个「加载」**永远不会
    /// 完成**。用户会等一个等不到的东西，而那行字在这里是错的：不是「慢」，
    /// 是「没有」。
    ///
    /// 所以校验必须发生在挂上去**之前**，落 `.unconfigured`——那一格已经有
    /// 现成的三处告知（日志说清查了哪两个位置、菜单后缀、换语言时的 HUD）。
    ///
    /// **校验以闭包传进来，本函数因此仍然不碰文件系统。**
    /// 判据不另写一套：生产用的是 `CorrectionModelCatalog.validate`（与校正
    /// 层开启时用的同一个），由 `TranslationAttachmentCoordinator` 提供，
    /// 见那边 `isUsableModelDirectory` 的默认值。参数**不给默认值**是有意的：
    /// 给了「永远为真」的默认值，新出现的调用点会静默绕过校验，而那正是本
    /// 缺陷的形状。
    nonisolated static func translationAttachment(
        effectiveTarget: Language?,
        usesCloudBackend: Bool,
        translationModelDirectory: URL?,
        correctionModelDirectory: URL?,
        isUsableModelDirectory: (URL) -> Bool
    ) -> TranslationAttachment {
        // 先判「有没有有效目标」。nil = 不翻译（off 或 目标==输入），
        // **云端开关在这一行之后才允许被读到**。
        guard effectiveTarget != nil else { return .detach }
        // 到这里才轮到后端选择。**这是插入，不是重排**——两行对调时
        // `TranslationAttachmentTests.offWithCloudStillDetaches` 会红，
        // 那条的期望值（`.detach`）不该被迁就。
        if usesCloudBackend { return .cloud }
        // 云端那一格在上面就返回了：云端不需要本地权重，拿本地目录的死活
        // 去拦一条根本不读它的路径是纯误杀。
        guard let directory = translationModelDirectory ?? correctionModelDirectory else {
            return .unconfigured
        }
        // 选中哪个就校验哪个，**不在两个候选之间悄悄改选**：
        // `translation.modelDirectory` 今天没有入口能设，真有了以后，
        // 「我指了 A 却在用 B」比「A 坏了，告诉我」更难排查。
        guard isUsableModelDirectory(directory) else { return .unconfigured }
        return .local(directory: directory)
    }

    /// 「输出语言：…」这一行菜单标题。
    ///
    /// 缺目录时带后缀，因为那时选中的语言**根本没生效**，而标题只写语言名
    /// 的话它恰好在骗人——用户看到「输出语言：西班牙文」，得到的却是中文。
    nonisolated static func outputLanguageMenuTitle(
        target: Language,
        modelMissing: Bool
    ) -> String {
        let title = "输出语言：\(target.displayName)"
        return modelMissing ? "\(title)（缺模型目录）" : title
    }

    // MARK: - 云端开关：谁来译

    /// 云端翻译**此刻**的真实状态。菜单栏的「翻译后端：…」一行由它决定。
    ///
    /// 分成四格而不是一个布尔值，是因为「开关开着」与「开着且真的在出站」
    /// 差得很远，而只印开关状态的菜单会在两种情况下骗人：
    ///
    /// - 云端开着、输出语言却是中文（＝不翻译）：**一个字节都不出站**
    ///   （`CloudEgressTests` 拿真会话 + 记录型网络会话端到端验过）。
    ///   只写「云端：开」的话，用户会以为自己说的话正在往外发。
    /// - 云端开着、选了外语，但 Keychain 里没有 key：每次听写都退回中文原文
    ///   （`GeminiTranslator` 在发请求之前就抛 `.missingAPIKey`）。
    ///   只写「云端：开」的话，用户会以为翻译在工作，而它一次都没工作过。
    ///
    /// 这与 `outputLanguageMenuTitle` 的「（缺模型目录）」后缀是同一条原则：
    /// 状态显示与实际行为不一致，等于在骗人。
    enum TranslationBackendStatus: Equatable {
        /// 云端关。要不要翻译由输出语言决定，但**无论翻不翻，都在本机跑**。
        case local
        /// 云端开着，但输出语言是中文＝不翻译，因此仍然零出站。
        case cloudIdleBecauseChinese
        /// 云端开 + 外语，但 Keychain 里没有 API key：每次听写退回中文原文。
        ///
        /// **不出站**：`GeminiTranslator` 读不到 key 就抛，请求根本不发
        /// （`CloudEgressTests.missingKeyIsLoudAndDoesNotFallBackToLocal`）。
        case cloudMissingKey
        /// 云端开 + 外语 + 有 key：**每句话都会发到 Google。**
        case cloudActive

        /// 这一格下，用户说的话会不会离开这台电脑。
        ///
        /// 菜单文案里那句出站警示只该出现在它为真的那一格，而它为真的那一格
        /// 必须正好是**真的发得出请求**的那一格——后半句由
        /// `CloudEgressTests.menuClaimMatchesObservedEgress` 拿记录型网络
        /// 会话当场对照，不是靠推理。
        ///
        /// （这两处刻意不写出那个网络类型的名字：出站面的源码扫描不剥注释，
        /// 提一句就会把本文件扫进允许清单，而那条清单是要越短越好的。）
        var sendsTextOffDevice: Bool { self == .cloudActive }
    }

    /// 由「挂载结论 + 云端开关 + 有没有 key」算出菜单要显示的状态。
    ///
    /// **第一个参数是 `translationAttachment` 的返回值，不是偏好里的布尔值。**
    /// 这条接法是本函数的全部要点：菜单说的话必须是从**真正决定行为的那个
    /// 判断**里推出来的，而不是另起一套判断。另起一套的后果就是「菜单说开、
    /// 实际走本机」——两套判断迟早分家，而分家没有任何东西看得见。
    ///
    /// 于是「先判语言、后判后端」那条顺序在这里也有牙口：把
    /// `translationAttachment` 里两个判断对调，中文 + 云端开会变成 `.cloud`，
    /// 本函数随之给出 `.cloudActive`，`CloudBackendMenuTests` 那张手写的
    /// 真值表当场红。
    ///
    /// - Parameter hasAPIKey: Keychain 里有没有 key。**只在 `.cloud` 那一格
    ///   被读到**，理由见 `TranslationAttachmentCoordinator.cloudKeyPresent`：
    ///   读 Keychain 可能弹系统授权框，中文那一格不该因为一个开关去碰它。
    nonisolated static func translationBackendStatus(
        attachment: TranslationAttachment,
        usesCloudBackend: Bool,
        hasAPIKey: Bool
    ) -> TranslationBackendStatus {
        guard attachment == .cloud else {
            // 走不到云端却开着云端开关，只可能是「输出语言是中文」——
            // 外语无论有没有本地模型目录都会落到 `.cloud`。
            return usesCloudBackend ? .cloudIdleBecauseChinese : .local
        }
        return hasAPIKey ? .cloudActive : .cloudMissingKey
    }

    /// 「翻译后端：…」这一行菜单标题。
    ///
    /// **四格四句话，一格一句**：都写「云端：开」的话，上面那两种「开了但
    /// 不会生效」的状态在菜单上就消失了。
    nonisolated static func translationBackendMenuTitle(
        _ status: TranslationBackendStatus
    ) -> String {
        switch status {
        case .local:
            "翻译后端：本机（文字不出这台电脑）"
        case .cloudIdleBecauseChinese:
            "翻译后端：云端 Google（当前输出中文，未出站）"
        case .cloudMissingKey:
            "翻译后端：云端 Google（缺 API key，未生效）"
        case .cloudActive:
            "翻译后端：云端 Google（每句话都会发出）"
        }
    }

    /// 二选一那两项的文案。
    ///
    /// **两项都常驻，用勾选标出当前那个**，而不是只显示「切到另一个」——
    /// 用户 2026-08-19 要的是「点开之后可以选本地，也可以选云端」，
    /// 那要求两个选项同时看得见。
    ///
    /// 云端那项**在文案里就说清后果**（不是等点下去才在确认框里说）：
    /// 一个会把用户每句话发出去的选项，不该长得和「换个字体」一样。
    nonisolated static func backendChoiceLabel(cloud: Bool) -> String {
        cloud ? "云端 Google（每句话都会发出）" : "本机（文字不出这台电脑）"
    }

    /// 子菜单里的说明行。**每一格都要把「现在到底会发生什么」说完。**
    ///
    /// 做成一个纯函数而不是拼在 SwiftUI 视图里：拼在视图里就没有任何测试
    /// 守得住它（与 `Language.menuLabel`、`HUDViewModel` 同一条分工）。
    nonisolated static func translationBackendDetailLines(
        status: TranslationBackendStatus,
        target: Language
    ) -> [String] {
        switch status {
        case .local:
            [
                "翻译在本机跑，说的话不出这台电脑。",
                "「输出语言」决定译成什么，这里决定谁来译——两件事。",
            ]
        case .cloudIdleBecauseChinese:
            [
                // **这一格是用户最容易误解的**：开着开关不等于正在往外发。
                "云端开着，但输出语言是「中文」＝不翻译：现在一个字节都不会离开本机。",
                "把输出语言换成外语之后，每句话才会发到 Google。",
            ]
        case .cloudMissingKey:
            [
                "云端开着，但 Keychain 里没有 API key：每次听写都会退回中文原文，也不会发出任何请求。",
                "存 key：security add-generic-password -a vInput -s \(TranslationKey.geminiService) -w",
                "存好后下次听写即生效，不必回菜单重选。",
            ]
        case .cloudActive:
            [
                "现在每说一句话，转写出来的全文都会发到 Google 的服务器，译成\(target.displayName)。",
                "涉及报价等机密内容时，先关掉它，或把输出语言切回中文。",
                "转写与校正始终在本机，不受这个开关影响。",
            ]
        }
    }

    /// 「开启云端翻译」的确认框文案。
    ///
    /// **开启云端不能像切换一个普通选项。** 产品大原则是一切不出本机
    /// （用户 2026-08-17 确立，理由是这工具会涉及机密内容，包括报价），
    /// 云端是「默认关、用户显式开」——「显式」这两个字要求用户在知道后果
    /// 之后再点一次，而不是划过一个开关。
    ///
    /// 文案里必须同时说清三件事，缺一件用户就会做出错的判断：
    /// 发生什么（每句话发到 Google）、什么时候不发生（输出语言是中文时零
    /// 出站）、什么不受影响（转写与校正始终在本机）。
    struct CloudBackendConfirmation {
        let title: String
        let message: String
        let confirmButton: String
        /// **取消是默认按钮**（见 `presentCloudBackendConfirmation`）：
        /// 一路回车不该把出站开关按开。
        let cancelButton: String
    }

    nonisolated static let cloudBackendConfirmation = CloudBackendConfirmation(
        title: "开启云端翻译？每句话都会发到 Google",
        message: """
            开启后，你说的每一句话——转写出来的全文——都会通过网络发到 Google 的 \
            Gemini 服务器做翻译。涉及报价、客户信息等机密内容时不要开启。

            这个开关只管「谁来译」，不管「要不要译」：只要输出语言是中文（＝不翻译），\
            就算它开着也不会有任何文字离开本机；出站只发生在输出语言是外语时。

            转写与校正始终在本机，不受这个开关影响。随时可以在同一处关掉。
            """,
        confirmButton: "开启云端翻译",
        cancelButton: "取消"
    )

    /// 按当前偏好挂（或摘掉）翻译流水线。
    ///
    /// **判断与挂载全在 `TranslationAttachmentCoordinator` 里**，本方法只负责
    /// 调它、再把结果同步到两个可观察镜像上。搬出去的理由（这段逻辑长在
    /// `AppModel` 里就是零覆盖，两条变异实测全绿）写在那边的类型注释里。
    private func applyTranslationPreference() {
        translationCoordinator?.apply()
        syncTranslationMirrors()
    }

    /// 把协调器的状态抄到两个可观察镜像上。
    ///
    /// **镜像必须留在 `AppModel`**：@Observable 只跟踪自身的存储属性，
    /// 菜单读协调器上的值的话点完不会刷新（与 `correctionEnabled` 同一个坑）。
    ///
    /// 只在这一处抄，`applyTranslationPreference` 与 idle 补挂都经由它——
    /// 两处各写一份的话，迟早有一条路径忘了同步，而表现是「菜单标题停在
    /// 旧语言」。
    private func syncTranslationMirrors() {
        guard let translationCoordinator else { return }
        // TEMP(Task 10 重写)：镜像还是旧的单语言形态，用有效目标近似——
        // off 时显示中文（旧语义的「中文=不翻译」），真目标时显示目标。
        outputLanguage = translationCoordinator.choice.effectiveTarget(input: translationCoordinator.input) ?? .chinese
        translationModelMissing = translationCoordinator.modelMissing
        // **从协调器真正算出来的那个挂载结论推，不要另起一套判断。**
        // 菜单是否显示「会发出」，必须与实际会不会发出同源；两处各判一次
        // 的话，「云端开 + 中文＝零出站」这一格迟早会在菜单上显示成正在出站。
        translationBackend = AppModel.translationBackendStatus(
            attachment: translationCoordinator.attachment,
            usesCloudBackend: translationPreference.usesCloudBackend,
            hasAPIKey: translationCoordinator.cloudKeyPresent
        )
        let mirror = AppModel.translationModelMirror(
            attachment: translationCoordinator.attachment,
            explicitDirectory: translationPreference.modelDirectory
        )
        translationModelName = mirror.name
        translationModelIsInherited = mirror.inherited
        cloudModel = translationPreference.cloudModel
        hasCloudAPIKey = translationCoordinator.cloudKeyPresent
    }

    /// 菜单上该显示哪个模型名、算不算「跟随校正」。
    ///
    /// **从挂载结论里取，不直接读偏好。** 读偏好的话，「用户指定过一个目录、
    /// 但它已经失效、实际退回了校正层的那个」这种情况，菜单上会显示成前者
    /// 而跑的是后者——用户据此判断「翻译在用哪个模型」，那就是在骗他。
    ///
    /// 抽成纯函数是为了能测：`AppModel` 在测试进程里起不来（init 就要真
    /// 快捷键、真 CGEvent tap），留在方法体里这条判断就没有任何东西守得住。
    nonisolated static func translationModelMirror(
        attachment: TranslationAttachment, explicitDirectory: URL?
    ) -> (name: String?, inherited: Bool) {
        let inherited = explicitDirectory == nil
        guard case .local(let directory) = attachment else { return (nil, inherited) }
        return (directory.lastPathComponent, inherited)
    }

    /// 「模型：…」那一行菜单文案。
    ///
    /// 抽成纯函数的理由与本文件其他几个一样：`AppModel` 在测试进程里起不来，
    /// 拼在 SwiftUI 视图里就没有任何测试守得住它。
    ///
    /// **「跟随校正」这四个字不能省。** 不写的话，用户换校正模型时翻译
    /// 也跟着变，而他完全无从预料——两个菜单看起来是两件事。
    nonisolated static func translationModelMenuLine(
        name: String?, inherited: Bool
    ) -> String {
        guard let name else { return "模型：未指定（在「校正」里指定，或在这里单独指定）" }
        return inherited ? "模型：\(name)（跟随校正）" : "模型：\(name)"
    }

    /// 单独给翻译指定一个本机模型目录。
    ///
    /// 校验用的是**校正层那一套** `CorrectionModelCatalog.validate`，不另写：
    /// 两层跑的是同一个 MLX 加载器，对目录的要求逐字相同。另写一套的话，
    /// 两边迟早对不上，而症状是「校正说这个目录能用，翻译说不能」。
    func selectTranslationModel(directory: URL) {
        switch CorrectionModelCatalog.validate(directory: directory) {
        case .success(let descriptor):
            translationPreference.modelDirectory = directory
            applyTranslationPreference()
            AppLogger.shared.log("翻译模型已单独指定：\(descriptor.name)")
        case .failure(let error):
            phase = .error("这不是可用的模型目录：\(error)")
            AppLogger.shared.log("指定翻译模型被拒：\(error)")
        }
    }

    /// 「模型：…」那一行（云端）。
    ///
    /// 只印标识符，**不附任何质量或速度的说法**——云端一次真实请求都没发过，
    /// 附一句就是在编。本机那三个实测数字是本机模型的，不许替云端说话。
    nonisolated static func cloudModelMenuLine(_ model: CloudTranslationModel) -> String {
        "模型：\(model.identifier)"
    }

    /// 「API Key：…」那一行。
    ///
    /// **有 key ≠ key 是对的。** 这行只说 Keychain 里有没有东西——
    /// key 对不对要等真的发一次请求才知道，而截至 2026-08-19 云端一次
    /// 真实请求都没发过。所以措辞是「已存」不是「已就绪」，
    /// 后者会让用户以为验证过了。
    nonisolated static func cloudAPIKeyMenuLine(hasKey: Bool) -> String {
        hasKey ? "API Key：已存入 Keychain（是否有效未验证）" : "API Key：未配置，翻译会退回中文原文"
    }

    /// 切到本机后端。**任何时候都可以，不需要确认**——这个方向是「更不出站」。
    func useLocalBackend() {
        guard translationPreference.usesCloudBackend else { return }
        translationPreference.usesCloudBackend = false
        applyTranslationPreference()
        AppLogger.shared.log("翻译后端已切回本机")
    }

    /// 点「云端 Google」那一项该做什么。**三档，纯函数，可单测。**
    ///
    /// 抽出来是因为最要命的那一档在视图里守不住：原来的 `toggleCloudBackend()`
    /// 是**切换**，已经在云端时再点一次会静默切回本机——用户以为自己点的是
    /// 一个已选中的选项，实际把出站开关关掉了，而面板上两项都是常驻带勾的
    /// 单选样式，正是最容易被再点一次的那种。守卫原来写在 SwiftUI 的按钮
    /// 闭包里（`guard model.translationBackend == .local else { return }`），
    /// 那里没有任何测试进得去。
    ///
    /// **已经在云端时 `confirm` 一次都不许被调用**：那会平白弹一个「你确定要
    /// 把每句话发到 Google 吗」的确认框，而用户其实什么都没改。这一条由
    /// `CloudBackendMenuTests` 拿一个会记录调用次数的闭包钉着。
    ///
    /// 开启要先确认、关闭（`useLocalBackend`）不必，这个不对称是有意的：
    /// 关掉的方向是「更不出站」，任何时候都该一步到位；开启的方向会让用户
    /// 说的每一句话离开本机，必须先看到后果再点一次（文案见
    /// `cloudBackendConfirmation`）。没接上确认 UI 时**不开**：一个出站开关
    /// 的失败方向只能是「不出站」（`?? false` 在下面那个调用点上）。
    nonisolated static func cloudBackendRequest(
        currentlyCloud: Bool, confirm: () -> Bool
    ) -> CloudBackendRequest {
        guard !currentlyCloud else { return .alreadyCloud }
        return confirm() ? .enable : .cancelled
    }

    enum CloudBackendRequest: Equatable {
        /// 已经在云端：什么都不做（**不切回本机，也不弹确认**）。
        case alreadyCloud
        /// 用户在确认框里点了取消：保持本机。
        case cancelled
        /// 开启云端。
        case enable
    }

    /// 切到云端后端。与 `useLocalBackend()` 对称：**幂等**，已经在云端时
    /// 再调是一次无操作。决策在 `cloudBackendRequest`，这里只执行。
    func useCloudBackend() {
        switch Self.cloudBackendRequest(
            currentlyCloud: translationPreference.usesCloudBackend,
            confirm: { confirmCloudBackend?() ?? false }
        ) {
        case .alreadyCloud:
            return
        case .cancelled:
            AppLogger.shared.log("开启云端翻译被取消，翻译保持在本机")
        case .enable:
            translationPreference.usesCloudBackend = true
            applyTranslationPreference()
            // 出站是唯一需要用户事后能在日志里查证的那件事，
            // 所以开关本身也留一条，而不只有挂载时那条。
            AppLogger.shared.log(
                "云端翻译已开启（输出语言为外语时，转写出来的文字会离开本机）")
        }
    }

    /// 选云端模型。
    func selectCloudModel(_ model: CloudTranslationModel) {
        translationPreference.cloudModel = model
        applyTranslationPreference()
        AppLogger.shared.log("云端翻译模型已选：\(model.identifier)")
    }

    /// 让用户填一个自定义模型标识符。
    func promptCloudModel() {
        guard let entered = promptForCloudModelIdentifier?(cloudModel.identifier) else { return }
        let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        selectCloudModel(.from(identifier: trimmed))
    }

    /// 让用户输入 API key 并存进 Keychain。
    ///
    /// **key 一个字节都不进日志。** 只记成功与否——日志是会被贴进对话、
    /// 贴进 issue 的东西。
    func enterCloudAPIKey() {
        guard let key = promptForCloudAPIKey?() else { return }
        let ok = TranslationKey.write(key, service: TranslationKey.geminiService)
        AppLogger.shared.log(ok ? "云端 API key 已存入 Keychain" : "云端 API key 存入失败")
        guard ok else {
            phase = .error("API key 存入 Keychain 失败")
            return
        }
        recheckCloudAPIKey()
    }

    /// 删掉 Keychain 里的 key。
    func removeCloudAPIKey() {
        TranslationKey.delete(service: TranslationKey.geminiService)
        AppLogger.shared.log("云端 API key 已从 Keychain 删除")
        recheckCloudAPIKey()
    }

    /// 撤销单独指定，改回跟随校正模型。
    ///
    /// **保留这条路**：没有它，用户一旦单独指过一次就再也回不去「跟随」，
    /// 而「跟随」正是默认且推荐的状态——两层共用同一份权重，
    /// 在 16 GB 的机器上省一次加载和一份 2 GB 常驻。
    func clearTranslationModel() {
        translationPreference.modelDirectory = nil
        applyTranslationPreference()
        AppLogger.shared.log("翻译模型改回跟随校正模型")
    }

    /// 重新查一次 Keychain 里有没有 API key，并刷新菜单上的状态。
    ///
    /// 菜单**不会**每次打开就去读 Keychain（理由见
    /// `TranslationAttachmentCoordinator.cloudKeyPresent`：那可能弹系统授权
    /// 框），所以「刚存完 key」这件事需要一个用户自己按的入口。
    /// 用户主动按下的一次读取是可以接受的——他知道自己在干什么。
    ///
    /// 顺带一提，存好 key 之后**不按也行**：`GeminiTranslator` 每次请求都
    /// 现读 Keychain，下一句话就生效；这个按钮只影响菜单上的显示。
    func recheckCloudAPIKey() {
        applyTranslationPreference()
    }

    /// 切换输出语言。改动立即生效并跨启动保留。
    func selectOutputLanguage(_ target: Language) {
        // TEMP(Task 10 重写)：旧语义等价桥
        translationPreference.choice = (target == .chinese ? .off : .translate(to: target))
        applyTranslationPreference()
        // 菜单标题上的后缀是常驻提示，但用户刚点完菜单、菜单当场就关了，
        // HUD 才是他这一刻会看到的东西。文案取自 `TranslationAnnotation`，
        // 不另写一句——「翻译为什么没生效」只该有一处措辞。
        if translationModelMissing {
            showHUDNotice(TranslationAnnotation.missingLocalModel.hudLabel)
        }
    }

    // MARK: - 运行时换模型

    /// 重新扫描模型目录。打开菜单时调用，这样新下载的模型无需重启即可出现。
    ///
    /// **留一条日志**：这是「面板每次打开都真的重建了」唯一可查证的痕迹。
    /// 面板换成 `.window` 之后，「模型列表刷没刷新」与「展开的设置行有没有
    /// 收回去」是同一个事实的两面（视图重建则两者都成立），而这件事在测试
    /// 进程里跑不到——数三次开面板产生的三行日志就能一次回答两个问题，
    /// 比肉眼「看着像刷新了」可靠。
    func refreshAvailableModels() {
        guard !modelRoot.isEmpty else { return }
        availableModels = discoverModels()
        AppLogger.shared.log("重扫模型目录，发现 \(availableModels.count) 个")
    }

    /// 根目录里扫出来的 + 用户导入的那些。
    ///
    /// 抽成一处是因为 `bootstrap()` 与 `refreshAvailableModels()` 各写一份的
    /// 话，迟早只有一处并上导入的目录——表现是「导入的模型开着能用，
    /// 打开一次面板就从列表里消失了」（面板 `onAppear` 会重扫）。
    private func discoverModels() -> [ModelDescriptor] {
        ModelCatalog.merge(
            discovered: ModelCatalog.discover(in: modelRoot),
            imported: importedModels.folders,
            validate: { ModelCatalog.validate(folder: $0) })
    }

    /// 手上到底有没有一个真模型。
    ///
    /// **面板头部与向导第五步的「可以听写了」都以它为准。** 原先两处判的都是
    /// `loadingModelName == nil`，那句话的意思只是「此刻没有东西在加载」——
    /// 零模型时它恒为真，于是面板说「就绪」、向导第五步的按钮亮着，
    /// 而按下去什么模型都没有。
    var hasModel: Bool { !activeModelFolder.isEmpty }

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
        modelLoadFailure = nil
        phase = .idle

        Task { [weak self] in
            let started = Date()
            do {
                try await transcriber.switchTo(model)
                self?.activeModelName = model.name
                // `hasModel` 读的就是它——不更的话，零模型启动、随后导入一个
                // 模型成功，面板头部还会继续说「还没有语音模型」。
                self?.activeModelFolder = model.folder
                // 换模型后预览引擎绑的是旧解码器，必须重新挂载。
                await self?.attachPreview()
                log.log("切换成功 \(model.name) 耗时 \(Int(Date().timeIntervalSince(started)))s")
            } catch {
                // 切换失败时旧模型仍然可用，见 SwitchableTranscriber 的保证。
                log.log("切换失败 \(model.name): \(error)")
                let message = "加载模型「\(model.name)」失败：\(error)"
                self?.modelLoadFailure = message
                self?.phase = .error(message)
            }
            // 无论成败都必须解除加载态，否则 toggle() 会被永久挡住。
            self?.loadingModelName = nil
            log.log("加载态已解除，当前模型 \(self?.activeModelName ?? "?")")
        }
    }

    /// 向导下载完 / 手动导入完，把这个目录交给应用真的用上。
    ///
    /// **不是直接 `selectModelFromFolder`。** 那条路的第一道门是
    /// `canSwitchModel`，录音或转写途中为 false，被挡下来之后只有一行日志，
    /// 此后再也没有人重试——用户刚下的 1.5GB 要等到下次启动才生效，
    /// 而界面上「下载完成」与「下载完成但没换上」长得一模一样。
    ///
    /// 挡是对的（换掉正在用的引擎更糟），缺的是记账与补做，都在
    /// `ModelAdoptionQueue` 里；这里只负责接线，外加**先重扫**
    /// ——重扫不受会话状态影响，先做的话即使换用被推迟，
    /// 新模型也已经出现在面板的模型列表里，用户可以自己点。
    func adoptDownloadedModel(_ folder: String) {
        refreshAvailableModels()
        let now = modelAdoption.request(folder: folder, canSwitchNow: canSwitchModel)
        syncPendingModelMirror()
        guard let now else { return }
        selectModelFromFolder(now)
    }

    /// 会话回到 idle 时补做被推迟的那次换用。调用点在 `onStateChange` 的
    /// `.idle` 分支，与校正/翻译两条补挂并排。
    ///
    /// **这条路上不许 surface 成 `phase = .error`。** 目录可能已经不在了
    /// （用户手动删了、卸载过、或者换了盘），而这一步发生在「用户刚说完一句
    /// 话」的那一刻——弹一个「这不是模型目录，缺少：…」的红字，对他来说是
    /// 毫无上下文的报错：他没点任何东西。所以只记日志、清账，界面照旧。
    /// 走 `ModelCatalog.validate` 而不是 `selectModelFromFolder`，差别就在这里。
    private func applyPendingModelAdoption() {
        let folder = modelAdoption.resume(canSwitchNow: canSwitchModel)
        syncPendingModelMirror()
        guard let folder else { return }
        switch ModelCatalog.validate(folder: folder) {
        case .success(let model):
            selectModel(model)
        case .failure(.notAModelFolder(let missing)):
            AppLogger.shared.log(
                "待启用的模型目录已经不在了，放弃这次补做（缺少：\(missing.joined(separator: "、"))）：\(folder)")
        }
    }

    /// 把队列里的欠账同步到可观察镜像上。
    ///
    /// 每个动队列的入口都必须调它，否则面板上那行「结束后自动启用」不会跟着
    /// 出现或消失——`@Observable` 看不见 `ModelAdoptionQueue` 里的字段
    /// （与 `syncCorrectionMirrors` 是同一件事）。
    ///
    /// internal 而不是 private：理由同 `modelAdoption`，量高度那条用例要用它
    /// 把面板推到最坏状态。
    func syncPendingModelMirror() {
        pendingModelFolder = modelAdoption.pendingFolder
    }

    /// 下载进度报进来。nil = 没有下载在跑。
    func reportModelDownload(progress: Double?) {
        downloadingModelProgress = progress
    }

    /// 「高级 → 下载源」三选一。nil 表示自动（并发探测，谁快用谁）。
    ///
    /// 只写偏好、只更镜像：**这个设置不影响任何正在跑的下载**
    /// （`DownloadSource.choose` 在下载开始那一刻读一次），
    /// 它管的是下一次下载。
    func selectDownloadSource(_ source: DownloadSource?) {
        downloadSourcePreference.forced = source
        forcedDownloadSource = source
        AppLogger.shared.log("下载源设置为：\(source?.displayName ?? "自动")")
        // 端点当场跟着改。用户在这里选的就是「走哪个源」，没道理只有模型
        // 权重听他的、而 tokenizer 那几 MB 照样去连官方源（那个入口只认
        // `HF_ENDPOINT`）。这**不影响任何正在跑的下载**——那一路的 endpoint
        // 是在下载开始那一刻按值传进去的。
        HuggingFaceEndpoint.apply(
            forced: source, resolved: downloadSourcePreference.resolved)
    }

    /// 让用户手选一个模型目录。
    ///
    /// 先校验目录结构，选错时给出明确提示，而不是等加载失败才报一个
    /// 难以理解的错误。
    func selectModelFromFolder(_ folder: String) {
        switch ModelCatalog.validate(folder: folder) {
        case .success(let model):
            // **记住它，否则下次启动就忘了。** 这条路（向导的「我已经有模型
            // 文件」、面板的「其他目录…」）是唯一能用根目录外面那份模型的
            // 入口，而 `bootstrap()` 只按根目录重建列表——不记的话，从
            // `~/Desktop/` 导入的模型这一次能用，重启就掉回零模型。
            // 根目录里的不必记（`discover` 自己扫得到），理由见 `isUnder`。
            if !ModelCatalog.isUnder(folder: model.folder, root: modelRoot),
                importedModels.remember(model.folder)
            {
                AppLogger.shared.log("记住导入的模型目录：\(model.folder)")
                refreshAvailableModels()
            }
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
        // 一个模型都没有时当场说清楚，不要让用户先说完一句话再失败。
        // `MissingModelTranscriber` 是这条路的兜底（它只会在转写那一刻报错，
        // 那时话已经说完了）；这道 guard 是把这句话提前到按下按钮的那一刻。
        guard hasModel else {
            log.log("toggle 被拒：一个模型都没有")
            phase = .error("还没有语音模型")
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
            // **⌥D 不判「这次会话是谁的」。**
            //
            // 三个源共用一个 `DictationSession`，所以鼠标或遥控器正录着的时候
            // 按 ⌥D，走的也是这一支：结束的是**别人的**会话。
            //
            // 独立验收 2026-08-18 列为低置信项（P6），复核后的结论是
            // **高置信推断，但未实证**：
            // - 推断成立的部分：这里确实没有任何「谁拥有这次会话」的判断，
            //   而三个源共用会话是事实（`AudioSourceRouter` 只选源，不记归属）。
            // - **未实证的部分**：鼠标那档抑制策略是 `.allExcept([Esc])`，
            //   `D` 键很可能在会话期间就被 tap 吃掉了，⌥D 根本到不了这里。
            //   遥控器那档是 `.only([F5])`，理论上 ⌥D 能穿过去。
            //   两种情形都没有真机日志佐证——**不要假装验证过**。
            //
            // 独立验收同时提到「这条路不调 endSuppressing()」。那一半已经不成立了：
            // 抑制器现在跟着会话状态自己收（`RemoteKeySuppressor.update(for:)`），
            // 会话一离开 `.listening` 就还键盘，无论是谁结束的它。
            //
            // 剩下那一半（归属判断）没有修，因为**修法本身要先定语义**：
            // 「⌥D 结束别人的会话」到底算 bug 还是算逃生口？用户可能正想用
            // 键盘把一次失控的鼠标录音停掉。定不了语义就改，等于拿掉一个
            // 可能有用的出口。等真机上先确认它到底触发不触发。
            log.log("结束录音，进入转写")
            Task { await session.finish() }
        case .transcribing, .correcting, .translating, .injecting:
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
            // 三个条件缺一不可，判据见 AppModel.voiceDeviceStartAllowed。
            // 基准集那条以前漏了，而注释却写着「与 ⌥D 的守卫保持一致」。
            guard Self.voiceDeviceStartAllowed(
                modelLoading: self.loadingModelName != nil,
                benchRecording: self.benchIsRecording,
                dictationIdle: session.state == .idle
            ) else {
                AppLogger.shared.log(
                    "遥控器录音被拒：模型加载中=\(self.loadingModelName != nil) "
                        + "基准集录制中=\(self.benchIsRecording) "
                        + "听写状态=\(session.state)"
                )
                // 状态退回去，但不发任何回调——见 RemoteCoordinator.abandonSession。
                self.remoteCoordinator?.abandonSession()
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
        // 关机键 → 退格（2026-08-20 侦察后接的，依据见
        // HIDReportParser.powerButtonUsage：短按系统零投递，注入即可）。
        hidListener.onPowerPressed = { [weak self] in
            guard let self else { return }
            guard Self.powerKeyPostsBackspace(
                dictationIdle: (self.session?.state ?? .idle) == .idle)
            else {
                AppLogger.shared.log("关机键按下，但正在听写，忽略")
                return
            }
            AppLogger.shared.log("关机键按下，注入退格")
            self.remoteKeyPoster.postBackspace()
        }
        // 「·」键 → 空格（2026-08-21 用户提的：想在 Finder 里选中图片按它
        // 弹 Quick Look）。依据见 HIDReportParser.graveButtonUsage。
        //
        // **与关机键不同，这里要做两件事**：系统会真的投递这个键（那就是
        // 用户看到的「·」），所以既要注入空格，也要吞掉原始按键。
        hidListener.onGravePressed = { [weak self] in
            guard let self else { return }
            // **先武装吞键器，且无条件武装。** 那个「·」在任何情况下都不该
            // 落到应用里——录音中按了它，正确的结果是什么都没发生。
            // 放在最前面还有一层理由：系统投递出的按键只落后 HID 报文
            // 约 2 毫秒，这之前每多做一件事都是风险。
            self.echoSwallower.arm(.grave)
            guard Self.graveKeyPostsSpace(
                dictationIdle: (self.session?.state ?? .idle) == .idle)
            else {
                AppLogger.shared.log("「·」键按下，但正在听写，忽略")
                return
            }
            AppLogger.shared.log("「·」键按下，注入空格")
            self.remoteKeyPoster.postSpace()
        }
        // 菜单键 → Command+Tab，切到上一个应用（2026-08-21 用户提的，
        // 2026-08-22 认出是 usage 0x65）。依据见
        // HIDReportParser.contextMenuButtonUsage。
        //
        // **与「·」键同型，也是两件事**：系统会真的投递这个键（那就是用户
        // 说的「唤醒菜单」），所以既要发 Command+Tab，也要吞掉原始按键。
        hidListener.onContextMenuPressed = { [weak self] in
            guard let self else { return }
            // **先武装吞键器，且无条件武装。** 那次右键菜单在任何情况下都不该
            // 弹出来——听写中按了它，正确的结果是什么都没发生。
            // 放在最前面还有一层理由：系统投递出的按键只落后 HID 报文
            // 约 2 毫秒，这之前每多做一件事都是风险。
            self.echoSwallower.arm(.contextualMenu)
            guard Self.contextMenuKeyPostsAppSwitch(
                dictationIdle: (self.session?.state ?? .idle) == .idle)
            else {
                AppLogger.shared.log("菜单键按下，但正在听写，忽略")
                return
            }
            AppLogger.shared.log("菜单键按下，推进应用切换器")
            // **不是「发一次 Command+Tab」，是「推进一次切换器会话」。**
            // Command 会一直按着，停手 0.7 秒才提交——这样连按才能在最近
            // 使用列表里一格一格往后翻。理由与五道兜底见 `AppSwitcher`。
            self.appSwitcher.press()
        }
        hidListener.start()
        keySuppressor.start()
        echoSwallower.start()
        // 挂上「应用失活就把 Command 抬起来」那条兜底。
        appSwitcher.start()

        // 把鼠标桥当前占着的那台排除掉。遥控器桥的连接判据是「服务 UUID
        // 匹配**或**名字匹配」，若某设备广播了 ATVV 服务 UUID 它就会去连
        // ——Roadmap 的「双设备共存」隐患。这支鼠标不讲 ATVV，当前撞不上，
        // 但两座桥都在跑的时候，把这条堵上的成本只有这几行。
        let bridge = XiaomiBluetoothBridge(
            delegate: self,
            excludedIdentifiers: { [weak self] in
                guard let identifier = self?.mouseBridge?.deviceIdentifier else { return [] }
                return [identifier]
            }
        )
        bluetoothBridge = bridge
        bridge.start()
    }

    private func stopRemote() {
        hidListener.stop()
        keySuppressor.stop()
        // 没有 HID 监听就没人来武装它，常开的 tap 也该一起收——
        // 「tap 不能活得比它的用途久」同 `RemoteKeySuppressor` 那条教训。
        echoSwallower.stop()
        // **同一条教训的另一半：合成的 Command 更不能活得比它的用途久。**
        // 遥控器都停了还留着一个按住的 Command，用户敲什么都是快捷键，
        // 而且他没法自己解除。`stop()` 摘观察者 + 无条件释放，幂等。
        appSwitcher.stop()
        bluetoothBridge?.stop()
        bluetoothBridge = nil
        remoteCoordinator = nil
    }

    // MARK: - 蓝牙鼠标（第三个音频源）

    /// 本次启动该不该拉起鼠标桥。判据在 `MouseVoiceGate.shouldStart`。
    nonisolated static var mouseEnabled: Bool {
        MouseVoiceGate.shouldStart(
            mouseEnabled: MouseVoiceGate.isEnabled,
            bleScanEnabled: BLEScanGate.isEnabled
        )
    }

    private func startMouse() {
        guard Self.mouseEnabled else {
            AppLogger.shared.log(
                "鼠标音频源未启用（\(MouseVoiceGate.disableKey)=0 或 BLE 扫描诊断开着）"
            )
            return
        }

        let coordinator = MouseCoordinator(source: mouseSource)

        coordinator.onStartSession = { [weak self] in
            guard let self, let session = self.session else { return }
            // **与遥控器同一套守卫，一条不少。** M6 那次的教训就是这里：
            // ⌥D 有两条 guard 而遥控器只有一条，注释还写着「保持一致」。
            guard Self.voiceDeviceStartAllowed(
                modelLoading: self.loadingModelName != nil,
                benchRecording: self.benchIsRecording,
                dictationIdle: session.state == .idle
            ) else {
                AppLogger.shared.log(
                    "鼠标录音被拒：模型加载中=\(self.loadingModelName != nil) "
                        + "基准集录制中=\(self.benchIsRecording) "
                        + "听写状态=\(session.state)"
                )
                // 状态退回去，但不发任何回调——见 MouseCoordinator.abandonSession。
                self.mouseCoordinator?.abandonSession()
                return
            }
            self.audioRouter?.select(.mouse)
            // 鼠标那一档 2026-08-20 起是空集（不吞任何键）：两轮真机证明
            // 它的按键走 GATT 控制帧、不产生键盘事件。仍然 begin 是为了
            // 保住 tap 与按下沿日志——那是唯一的观测通道，证据与取舍见
            // RemoteKeySuppressor.mousePolicy。
            self.keySuppressor.beginSuppressing(policy: RemoteKeySuppressor.mousePolicy)
            Task {
                do {
                    try await session.start()
                    AppLogger.shared.log("鼠标语音键按下，开始录音")
                } catch {
                    AppLogger.shared.log("鼠标录音启动失败：\(error)")
                }
            }
        }
        coordinator.onFinishSession = { [weak self] in
            self?.keySuppressor.endSuppressing()
            guard let session = self?.session else { return }
            AppLogger.shared.log("鼠标语音键松开，进入转写")
            Task { await session.finish() }
        }
        mouseCoordinator = coordinator

        // 鼠标桥没有 keepalive：这支设备的问题方向与 RC003 相反——
        // RC003 是固件 60 秒切断需要续期，鼠标是 0x31 不会停需要我们喊停。
        // 上限机制在 MouseVoiceSession，由桥自己每秒 tick。
        let bridge = MouseBluetoothBridge(
            delegate: self,
            excludedIdentifiers: { [weak self] in
                // 遥控器桥占着的那台一律排除。「不打断 RC003」这条约束在
                // 代码里的第二个落点，第一个是名字禁止名单。
                guard let identifier = self?.bluetoothBridge?.deviceIdentifier else { return [] }
                return [identifier]
            }
        )
        mouseBridge = bridge
        bridge.start()
    }

    private func stopMouse() {
        mouseBridge?.stop()
        mouseBridge = nil
        mouseCoordinator = nil
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

        // **两条路写的是同一个 fileLog，所以撞到失控流上限时必须一起停。**
        // 原来只有扫描器有守卫，而它 `stop()` 的只是自己——探针照样往同一个
        // 文件里写。独立验收 2026-08-18 指出。
        scanner.onRunawayStop = { [weak self] in
            self?.hidProbe?.stop()
            self?.hidProbe = nil
        }
        probe.onRunawayStop = { [weak self] in
            self?.bleScanner?.stop()
            self?.bleScanner = nil
        }

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

// MARK: - MouseBluetoothBridgeDelegate

extension AppModel: @MainActor MouseBluetoothBridgeDelegate {
    func mouseBridge(_ bridge: MouseBluetoothBridge, didChange state: MouseBridgeState) {
        mouseState = state
    }

    func mouseBridgeDidStartVoice(_ bridge: MouseBluetoothBridge) {
        mouseCoordinator?.handleVoiceStart()
    }

    func mouseBridge(_ bridge: MouseBluetoothBridge, didStopVoice reason: MouseSessionEndReason) {
        mouseCoordinator?.handleVoiceStop()
    }

    func mouseBridge(_ bridge: MouseBluetoothBridge, didReceiveAudio packet: Data) {
        mouseCoordinator?.handleAudio(packet)
    }

    func mouseBridge(_ bridge: MouseBluetoothBridge, didUpdateBatteryLevel level: Int?) {
        mouseBattery = level
    }

    func mouseBridgeDidDisconnect(_ bridge: MouseBluetoothBridge) {
        mouseCoordinator?.handleDisconnected()
    }
}
