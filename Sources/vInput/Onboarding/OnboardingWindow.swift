import AppKit
import Foundation
import Observation
import SwiftUI

/// 承载首次启动向导的独立窗口。
///
/// 结构照抄 `BenchRecordingWindowController`（同样的三条硬约束，见下面各自的
/// 注释），只有一处**有意不同**：不锁死外观。
///
/// **为什么不是 `NSPanel`**：`HUDPanel` 那种无焦点浮动面板的硬约束是「不抢
/// 焦点」（听写时焦点必须留在别的应用的输入框里）。向导正相反——用户此刻就在
/// 跟它交互，最后一步还要往它自己的输入框里落字，它就该能成为 key window。
///
/// **为什么不是 SwiftUI 的 `Window` 场景**：关窗时要停掉辅助功能轮询、摘掉
/// 转写改道；这些生命周期动作在 `Window` 场景里没有干净的接入点，也没法在
/// 单测里驱动。而这里恰恰是本批唯一能被测试进程真正驱动起来的 UI 层。
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    /// 窗口内容区尺寸。
    ///
    /// 比录制窗小、比菜单面板大得多：向导一屏只讲一件事（一句说明 + 一个
    /// 按钮），但读它的人是第一次见这个应用，字号比面板大一档，
    /// 最长的那步（下载失败 + 两个补救入口）要放得下三行说明加两个按钮。
    static let defaultContentSize = CGSize(width: 560, height: 400)

    /// 窗口关闭时的回调。
    ///
    /// **不可省**：向导关掉时若不收尾，辅助功能轮询会一直每 0.5 秒跑一次，
    /// 而转写改道会一直挂着——此后每一次听写的文字都被送进一个已经不存在的
    /// 界面里，日志还写着「注入成功」。调用方据此收尾。
    var onClose: (() -> Void)?

    /// 当前窗口。对外只读——测试要据此确认「关掉再开建的是新窗口」。
    private(set) var window: NSWindow?

    var isOpen: Bool { window != nil }

    /// 向导此刻是不是 key window。
    ///
    /// 「试说一句」用它判断这次听写归不归自己——不判的话，向导开着期间
    /// **别的应用里的每一次听写都会被吞掉**（见 `handleDictation`）。
    var isKey: Bool { window?.isKeyWindow ?? false }

    /// 打开窗口；已经开着时只把它带到前台。
    ///
    /// 不重建是有意的：重建会把用户从第四步弹回第一步，而第四步可能已经
    /// 下了半个模型。
    func show<Content: View>(_ content: Content, title: String = "欢迎使用 vInput") {
        if let window {
            bringToFront(window)
            return
        }

        let window = makeWindow(title: title)

        let hosting = NSHostingController(rootView: content)
        // 清空 sizingOptions：默认的 .preferredContentSize 会拿 SwiftUI 的固有
        // 尺寸反过来定窗口大小，而各步骤的固有高度差得很远（欢迎步两行字，
        // 下载失败步七八行）——不清的话窗口会随步骤跳大跳小。设成空之后
        // 尺寸由下面那行说了算，切步骤时窗口纹丝不动。
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(Self.defaultContentSize)
        window.center()
        self.window = window
        bringToFront(window)
    }

    func close() {
        guard let window else { return }
        window.close()
        // `close()` 对未上屏的窗口不保证发出 windowWillClose（没有窗口服务器的
        // 测试进程里就是如此），这里补一次收尾。两条路都走 finishClose，
        // 重复调用是空操作。
        finishClose()
    }

    func windowWillClose(_ notification: Notification) {
        finishClose()
    }

    private func finishClose() {
        guard window != nil else { return }
        window = nil
        onClose?()
    }

    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.defaultContentSize),
            // 不给 .miniaturizable：向导缩到 Dock 里就再也找不回来了
            // ——这是个 LSUIElement 应用，Dock 上没有它的图标可点。
            // 可缩放留着：想把字看得更大时能拉大窗口。
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.delegate = self
        // ARC 下窗口由本控制器持有；保持默认的 true 会造成过度释放。
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: 480, height: 340)
        // **这里不设 appearance，也不设 backgroundColor——与录制窗的唯一区别。**
        //
        // 录制窗把外观锁成 `.aqua` 是因为用户明确要求那扇窗白底黑字，锁不住的话
        // 深色模式下的标题栏会跟纯白正文拼在一起。向导没有那条要求：它是这个
        // 应用给新用户的第一印象，跟随系统才是对的，而深色模式下的用户看到一扇
        // 突兀的白窗只会觉得这个应用没做完。视图层因此也不能钉死
        // `colorScheme`（菜单面板钉了，因为它的底色是写死的深色）。
        return window
    }

    /// LSUIElement 应用默认不激活，不先 activate 的话窗口会躲在别的应用后面
    /// 且不接受键盘输入。向导该抢焦点——用户此刻正在跟它交互，
    /// 而且最后一步的输入框必须能拿到键盘。
    private func bringToFront(_ window: NSWindow) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// 辅助功能授权的轮询。
///
/// **为什么必须轮询**：辅助功能没有系统对话框，也没有任何回调或通知——
/// 用户是去「系统设置 → 隐私与安全性 → 辅助功能」里勾一个开关，勾完之后
/// 本进程不会收到任何东西。不轮询的话，用户勾完切回来，向导还停在
/// 「请去开启权限」那一屏：他不知道向导有没有察觉，只能瞎点。
///
/// 0.5 秒是「勾完切回来就已经过了」与「别空转」之间的取值：用户从系统设置
/// 切回向导至少要几百毫秒，这个间隔下他看到的就是已经翻页的向导。
///
/// `tick()` 是 internal 的：测试进程里没有跑着的 runloop，定时器永远不会响。
/// 把「响一次要做什么」和「谁让它响」分开，前者就测得到。
@MainActor
final class AccessibilityPoller {
    /// 轮询间隔。理由见类型注释。
    static let interval: TimeInterval = 0.5

    private var timer: Timer?
    private var trusted: () -> Bool = { false }
    private var onGranted: () -> Void = {}

    var isRunning: Bool { timer != nil }

    /// 开始轮询。重复调用先停掉上一轮，不会叠出两个定时器。
    func start(trusted: @escaping () -> Bool, onGranted: @escaping () -> Void) {
        stop()
        self.trusted = trusted
        self.onGranted = onGranted
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// 走一格。
    ///
    /// **先停再回调**：回调会把向导推到下一步，而下一步的入场动作里又会
    /// `stop()`；顺序反过来的话，授权后的那一格与切步骤之间还夹着一次
    /// 已经没有意义的轮询。`isRunning` 那道 guard 挡的是「停了之后又被驱动」
    /// ——定时器 invalidate 与已经排进队列的那一次触发之间有窗口。
    func tick() {
        guard isRunning, trusted() else { return }
        stop()
        onGranted()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        // 不能在 deinit 里碰 @MainActor 的 stop()，但定时器必须收掉：
        // repeats 的 Timer 由 runloop 持有，不 invalidate 就会一直跑下去，
        // 回调里的 `self?` 已经是 nil，纯空转。
        timer?.invalidate()
    }
}

/// 向导的接线与运行时状态。
///
/// ## 为什么它不认识 `AppModel`
///
/// `AppModel` 在 `init` 里就要真麦克风、真快捷键、真 CGEvent tap，测试进程里
/// 构造不出来。向导只需要它的四件事（模型根目录、换模型、开始/结束听写、
/// 转写改道），全部走 `Wiring` 的闭包传进来——于是「present 时就开下载」
/// 「授权后自己翻页」「试说不走 TypingSink」这几条能被真正跑一遍，
/// 而不是只扫源码证明某一行还在。
///
/// 接线的实处在 `AppDelegate.applicationDidFinishLaunching`。
@MainActor
@Observable
final class OnboardingCoordinator {
    /// 向导需要外界提供的一切。默认值是生产实现，测试逐项替换。
    struct Wiring {
        var permissions = Permissions()
        /// 模型下载到哪、去哪找。必须与 `AppModel` 用的是同一个地方。
        var modelRoot: () -> String = {
            ModelCatalog.resolveRoot(
                appSupport: ModelCatalog.applicationSupportRoot(home: NSHomeDirectory()),
                developmentRoot: ModelCatalog.defaultRoot(appBundleURL: Bundle.main.bundleURL),
                exists: { FileManager.default.fileExists(atPath: $0) })
        }
        var alreadyPresent: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        var probe: @Sendable (DownloadSource) async -> DownloadSource.ProbeResult = {
            await EndpointProbe.probe($0)
        }
        /// 面板「高级 → 下载源」里选的那一档。nil = 自动（并发探测，谁快用谁）。
        ///
        /// **必须与面板写进去的是同一个 key**，两边都经由
        /// `DownloadSourcePreference`（key 只在那里写一次）。各写一个字面量的
        /// 话，拼错一个字母的表现是「这个设置什么都不做」，而界面上打着勾。
        var forcedDownloadSource: () -> DownloadSource? = { DownloadSourcePreference().forced }
        /// 探测定下这次用哪个源之后记一笔。
        ///
        /// **不只是记账，它当场就改本进程的 `HF_ENDPOINT`。** 传给
        /// `WhisperKit.download` 的 `endpoint:` 只管模型权重；tokenizer 是
        /// `prepare()` 时另一个没有 endpoint 参数的入口去取的，只认环境变量。
        /// 不接这一路的话，国内用户经镜像顺利下完 1.5 GB，然后在第五步
        /// 「试说一句」上为了 2.8 MB 的 tokenizer 去连 huggingface.co。
        /// 全部理由在 `HuggingFaceEndpoint` 的类型注释里。
        var recordResolvedSource: (DownloadSource) -> Void = { HuggingFaceEndpoint.adopt($0) }
        /// 下载进度往外报一份，`nil` 表示「此刻没有下载在跑」。
        ///
        /// 关窗**不取消下载**（扔掉几百 MB 更糟），于是它会变成一个没人看得见
        /// 的后台任务：菜单栏图标的加载态说的是「模型正在加载」，不是「正在
        /// 下载」。接上这一路之后，面板上有一行「正在下载模型 42%」。
        var onDownloadProgress: (Double?) -> Void = { _ in }
        var makeBackend: @MainActor () -> ModelDownloadBackend = { WhisperKitDownloadBackend() }
        /// 复用菜单里那个模型目录选择器，不另造一个。
        var chooseModelFolder: @MainActor () -> URL? = { presentWhisperModelFolderPanel() }
        /// 拿到可用模型目录后让应用真的用上它（重扫 + 切换），无需重启。
        var adoptModelFolder: (String) -> Void = { _ in }
        /// 模型是否已经加载完、可以开始听写。
        var isDictationReady: () -> Bool = { true }
        /// 最近一次模型加载失败的整句话；nil = 没失败。第五步据此说清
        /// 「为什么还没好」，而不是永远的「还在准备」。
        var modelLoadFailure: () -> String? = { nil }
        /// 开始 / 结束一次听写。就是 ⌥D 那一支。
        var toggleDictation: () -> Void = {}
        /// 挂上/摘掉转写改道。传 nil 表示摘掉，文本回到平常那条路。
        /// 闭包返回 `true` 表示「这次归向导」，`false` 表示照常注入目标应用。
        var setTranscriptRedirect: (((String) -> Bool)?) -> Void = { _ in }
        /// 「这次听写是不是向导发起的」。nil 表示问窗口自己（真判据）。
        /// 注入点只为测试而存在，理由见 `wizardOwnsThisDictation`。
        var wizardOwnsDictation: (() -> Bool)?
        /// 当前输入语言。语言页据此显示选中项——写死中文的话，一个先在
        /// 面板里改成英文又回头走向导的人，会被告知「你选的是中文」。
        var inputLanguage: () -> Language = { InputLanguagePreference().language }
        /// 改输入语言。**必须走 `AppModel.selectInputLanguage`**，不能直接写
        /// `InputLanguagePreference`：后者只存值，校正的摘挂、翻译矩阵、
        /// 转写器重建都不会发生，紧接着的「试说一句」仍按旧语言解码。
        var selectInputLanguage: (Language) -> Void = { _ in }
    }

    let state: OnboardingState
    private let wiring: Wiring
    private let window = OnboardingWindowController()
    private let poller = AccessibilityPoller()

    // MARK: - 下载的运行时状态（视图读这几个）

    private(set) var downloadProgress: Double = 0
    private(set) var downloadFinished = false
    /// 失败时给用户看的整句话，**必须说清是哪个源**。nil 表示当前没有失败。
    private(set) var downloadFailure: String?
    private(set) var isDownloading = false
    /// 本次会话里下载失败过的源。选源时让位（`DownloadSource.choose` 的
    /// `demoted`），不持久化——下次启动网络可能完全不同。
    private(set) var failedSources: Set<DownloadSource> = []

    var progressText: String { ModelDownloader.percentText(downloadProgress) }

    // MARK: - 试说一句

    /// 试说出来的那句话。它就是向导输入框里的内容——**没有任何 CGEvent
    /// 被投递到任何应用**，见 `RedirectableTextSink`。
    var dictationText: String = ""

    // MARK: - ⑤ 输入语言

    /// 语言页上此刻选中的那一档。开窗时从当前偏好取，用户点一下就跟着变。
    private(set) var selectedInputLanguage: Language = .chinese

    /// 用户在语言页上点了某一档。
    ///
    /// 立刻生效、不等「下一步」：紧接着的「试说一句」要用它解码，
    /// 攒到翻页时才提交的话，用户选完英文、当场试说，出来的还是中文。
    func selectInputLanguage(_ language: Language) {
        selectedInputLanguage = language
        wiring.selectInputLanguage(language)
        AppLogger.shared.log("向导：输入语言选为 \(language.displayName)")
    }

    init(state: OnboardingState, wiring: Wiring = Wiring()) {
        self.state = state
        self.wiring = wiring
    }

    // MARK: - 「一共几步、现在第几步」

    /// 这一次实际要走的步骤序列。
    ///
    /// **不能写死「一共五步」**：`OnboardingState.next` 会跳过已经给过的权限
    /// （重装的人、早就手动开过权限的人），写死的话第一屏说「一共 5 步」而
    /// 实际只走 3 步——第一句话就不准，后面说什么都打折。
    ///
    /// 用 `next` 自己推一遍而不是另立一张表：两处各写一份，迟早对不上。
    nonisolated static func plannedSteps(
        microphone: Bool, accessibility: Bool
    ) -> [OnboardingState.Step] {
        var steps: [OnboardingState.Step] = [.welcome]
        var current = OnboardingState.Step.welcome
        // 上界防死循环：`next` 万一被改成有环的，这里也不会挂住界面。
        for _ in 0..<OnboardingState.Step.allCases.count {
            guard
                let next = OnboardingState.next(
                    after: current, microphone: microphone, accessibility: accessibility)
            else { break }
            steps.append(next)
            current = next
        }
        return steps
    }

    /// 「第 2 / 4 步」。当前步不在计划里（用户是从别处回来的）时返回 nil，
    /// 宁可不显示，也不显示一个错的。
    nonisolated static func stepIndicator(
        step: OnboardingState.Step, planned: [OnboardingState.Step]
    ) -> String? {
        guard let index = planned.firstIndex(of: step) else { return nil }
        return "第 \(index + 1) / \(planned.count) 步"
    }

    /// 开窗那一刻定下来的计划，之后**不再重算**。
    ///
    /// 重算会让分母越走越小：走到麦克风那步时权限已经给了，重算出来的计划
    /// 里就没有麦克风这一步了，于是「第 2 / 5 步」下一屏变成「第 2 / 4 步」
    /// ——进度条往回跳，看着像出了错。
    private(set) var plannedSteps: [OnboardingState.Step] = OnboardingState.Step.allCases

    var stepIndicator: String? {
        Self.stepIndicator(step: state.step, planned: plannedSteps)
    }

    // MARK: - 打开与关闭

    /// 开窗，**并且当场把模型下载踢起来**。
    ///
    /// 「当场」是这个函数存在的理由。模型 1.5GB，慢网络下十几分钟起步；
    /// 等走到第四步再开始下，用户就是干瞪着进度条等那十几分钟。放在这里，
    /// 欢迎、麦克风、辅助功能三步的时间全部被下载吃掉——走到第四步时
    /// 进度条往往已经过半，甚至已经完事直接翻页。
    ///
    /// 这条不变量由 `OnboardingWiringTests` 真跑一遍钉住（present 之后
    /// 在 `.welcome` 步上就要看到下载动起来）。
    func present() {
        plannedSteps = Self.plannedSteps(
            microphone: wiring.permissions.microphoneAuthorized(),
            accessibility: wiring.permissions.accessibilityTrusted())
        window.onClose = { [weak self] in self?.teardown() }
        window.show(OnboardingView(coordinator: self))
        // **恢复到中途某一步时，入场动作必须补做**（2026-08-22 复审的 C-1）。
        //
        // `OnboardingState.init` 会从 UserDefaults 把 step 读回来，但入场动作
        // 全在 `enter()` 里，而重启这条路一次都不会走 `enter()`。两条真实的
        // 失效链：
        //
        // - 恢复到 `.accessibility`：轮询没起来，而那一页上白纸黑字写着
        //   「打开之后直接切回来就行，这个窗口会自己继续」——那句话就成了
        //   假话。偏偏这是最可能重启的一步：macOS 授予辅助功能后经常要求
        //   重开应用。
        // - 恢复到 `.testDictation`：改道没挂，试说一句直接落到 `TypingSink`，
        //   而它「看起来还能用」（向导在前台，CGEvent 恰好落进它自己的
        //   输入框）——正是设计明确拒绝的那种「碰巧」。
        attachStepActions(state.step)
        startModelDownload()
    }

    var isWindowOpen: Bool { window.isOpen }

    func close() {
        window.close()
    }

    /// 关窗收尾。**下载不取消**——用户可能只是想先关掉窗口，
    /// 而取消等于把已经下了的几百 MB 扔掉；文件落盘后菜单面板重扫就能看到。
    private func teardown() {
        poller.stop()
        setRedirect(nil)
    }

    // MARK: - 步骤推进

    /// 走到下一步。已经满足的权限步骤由 `OnboardingState.next` 跳过。
    func advance() {
        let next = OnboardingState.next(
            after: state.step,
            microphone: wiring.permissions.microphoneAuthorized(),
            accessibility: wiring.permissions.accessibilityTrusted())
        guard let next else {
            finish()
            return
        }
        enter(next)
    }

    /// 进入某一步：先把上一步的常驻动作收掉，再挂这一步的。
    ///
    /// 收在这一处而不是各步骤自己收：轮询和改道各有三四个离场出口
    /// （点按钮翻页、授权后自动翻页、关窗），逐个出口去收迟早漏一个，
    /// 而漏掉的表现分别是「空转」和「此后所有听写静默消失」。
    private func enter(_ step: OnboardingState.Step) {
        detachStepActions()
        state.advance(to: step)
        AppLogger.shared.log("向导进入步骤：\(step.rawValue)")
        attachStepActions(step)
    }

    /// 某一步的入场动作。
    ///
    /// **两个调用方**：`enter()`（正常翻页）与 `present()`（重启后恢复到
    /// 中途某一步）。抽出来正是因为原先只有前者，重启那条路整条断掉。
    private func attachStepActions(_ step: OnboardingState.Step) {
        switch step {
        case .accessibility:
            startAccessibilityPolling()
        case .testDictation:
            setRedirect { [weak self] text in self?.handleDictation(text) ?? false }
        case .inputLanguage:
            // 每次进这一页都重新取：用户可能在向导开着的时候去面板改过。
            selectedInputLanguage = wiring.inputLanguage()
        case .welcome, .microphone, .downloadModel:
            break
        }
    }

    /// 离场动作。
    ///
    /// **`setRedirect(nil)` 这一行目前不可达**，如实标注而不是让注释说假话：
    /// 唯一挂着改道的步骤是最后一步，而从最后一步出发的 `advance()` 会走
    /// `finish()`（那边经由 `teardown()` 摘，那条路是被测着的），不会回到
    /// `enter()`。保留它是因为它与 `poller.stop()` 是同一件事的两半——将来
    /// 加一个「上一步」按钮时漏掉它的代价，是改道一直挂着。
    /// `poller.stop()` 那一半是真的会走到的（辅助功能 → 下载模型），有测试钉着。
    private func detachStepActions() {
        poller.stop()
        setRedirect(nil)
    }

    private func finish() {
        state.markComplete()
        AppLogger.shared.log("向导已完成")
        teardown()
        close()
    }

    // MARK: - 第二步：麦克风

    /// 弹系统麦克风对话框；给了就自己翻页。
    ///
    /// 不给就停在原地：这一步没有可跳过的余地，没有麦克风连录音都开始不了。
    func requestMicrophone() {
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.wiring.permissions.requestMicrophone()
            AppLogger.shared.log("向导：麦克风授权结果=\(granted)")
            if granted { self.advance() }
        }
    }

    // MARK: - 第三步：辅助功能

    /// 打开系统设置，并确保轮询在跑。
    ///
    /// 轮询在 `enter(.accessibility)` 时就已经起来了，这里再确保一次：
    /// 用户可能是从别处回到这一步的。
    func openAccessibilitySettings() {
        wiring.permissions.openAccessibilitySettings()
        startAccessibilityPolling()
    }

    private func startAccessibilityPolling() {
        let trusted = wiring.permissions.accessibilityTrusted
        // 已经给过了就别开定时器，直接翻页。
        guard !trusted() else {
            advance()
            return
        }
        poller.start(trusted: trusted) { [weak self] in
            AppLogger.shared.log("向导：检测到辅助功能已授权，自动进入下一步")
            self?.advance()
        }
    }

    /// 测试用：轮询在不在跑。真机上看不到，但「离开这一步有没有停掉」
    /// 出问题就是纯空转，查不出来。
    var isPollingAccessibility: Bool { poller.isRunning }

    /// 测试用：驱动一格轮询（测试进程里没有跑着的 runloop）。
    func pollAccessibilityOnce() { poller.tick() }

    // MARK: - 第四步：下载模型

    /// 踢一次下载。已经在下就什么都不做。
    ///
    /// 先查本地再探网络：模型已经在了的话（重装、或者开发机上本来就有），
    /// 连探测都不必发，向导第四步一进去就是完成态。
    func startModelDownload() {
        guard !isDownloading, !downloadFinished else { return }

        let root = wiring.modelRoot()
        let folder = (root as NSString).appendingPathComponent(ModelDownloader.variant)
        if wiring.alreadyPresent(folder) {
            downloadProgress = 1
            downloadFinished = true
            AppLogger.shared.log("向导：模型已在本地，跳过下载")
            return
        }

        isDownloading = true
        downloadFailure = nil
        // 报一次 0：探测那几秒里面板上也该有话说，否则用户看到的是「什么都
        // 没发生」，然后忽然从 30% 开始。
        wiring.onDownloadProgress(0)
        AppLogger.shared.log("向导：开始探测下载源")

        // 用户在「高级 → 下载源」里强制过的话，探测整个跳过（`choose` 拿到
        // 非 nil 的 forced 直接返回它）——这个逃生口存在的意义就是「探测选错
        // 了，我自己指定」，再探一遍等于没给。
        let forced = wiring.forcedDownloadSource()
        if let forced {
            AppLogger.shared.log("向导：下载源被用户强制为 \(forced.displayName)，跳过探测")
        }

        Task { [weak self] in
            guard let self else { return }
            guard
                let source = await DownloadSource.choose(
                    probe: self.wiring.probe, forced: forced, demoted: self.failedSources)
            else {
                AppLogger.shared.log("向导：两个下载源都不通")
                self.downloadFailure = Self.noSourceMessage
                self.isDownloading = false
                self.wiring.onDownloadProgress(nil)
                return
            }

            var outcome = await self.download(from: source, root: root)

            // **用户在下载途中手动导入了模型：这一次下载的结果一律不采用。**
            //
            // 第四步的「我已经有模型文件」在下载进行中照样可点（那是故意的
            // ——两个源都慢的时候它就是唯一的出路），导入成功会
            // `adoptModelFolder` + `advance()` 把人送到第五步。而这个 Task
            // 还在飞：成功分支会**第二次** `adoptModelFolder`，把用户刚选的
            // 模型顶成刚下好的；失败分支会在用户已经离开第四步之后，往第四步
            // 补一句红色的失败文案。
            //
            // 2026-08-24 收尾 QA 复现出来的，是个预先存在的缺陷；但**本批把
            // 窗口从约 60 秒拉长到约 125 秒**（换源多一次探测 + 一次完整下载
            // 尝试），而失败文案本身就在劝用户「或者直接用你已经有的模型
            // 文件」——正好把人推进这个缝里。
            //
            // 判据用 `downloadFinished`：`startModelDownload()` 入口的守卫认的
            // 也是它，语义一致（这一步已经完成了，别再下了）。
            guard !self.downloadFinished else {
                AppLogger.shared.log("向导：下载结束时用户已手动导入模型，本次结果不采用")
                self.isDownloading = false
                self.wiring.onDownloadProgress(nil)
                return
            }

            // **下载失败自动换另一个源，只换一轮。** 2026-08-23 太太的机器上，
            // 官方源探测三次都通、下载三次都超时，而用户每次只能点「重试」
            // 再等一分钟。用户强制了源就不换——那是他的明确意愿。
            //
            // 换之前只探另一个源（2.5 秒封顶）：它多半就是刚才探测里输掉或
            // 没响应的那个，不探直接下等于再白等一个 60 秒超时。
            if case .failed(let first) = outcome, forced == nil {
                self.failedSources.insert(first)
                let alternative = first.other
                AppLogger.shared.log(
                    "向导：从\(first.displayName)下载失败，尝试换源 → \(alternative.displayName)")
                if case .responded = await self.wiring.probe(alternative) {
                    outcome = await self.download(from: alternative, root: root)
                    if case .failed = outcome {
                        self.failedSources.insert(alternative)
                        self.downloadFailure = Self.bothFailedMessage
                    }
                } else {
                    AppLogger.shared.log("向导：\(alternative.displayName)也不通，不再自动换源")
                    self.downloadFailure = Self.failureMessage(
                        source: first, alternativeUnreachable: alternative)
                }
            } else if case .failed(let failedSource) = outcome {
                self.downloadFailure = Self.failureMessage(source: failedSource)
            }

            switch outcome {
            case .alreadyPresent, .downloaded:
                self.downloadProgress = 1
                self.downloadFinished = true
                self.wiring.adoptModelFolder(folder)
            case .failed:
                break
            }
            self.isDownloading = false
            // 成败都要收：不收的话面板上会永远挂着一行「正在下载模型 100%」。
            self.wiring.onDownloadProgress(nil)
        }
    }

    /// 从一个定下来的源下载：先记源，再下。
    ///
    /// **记源必须在 run() 之前。** 下载成功会紧接着 adoptModelFolder →
    /// 换模型 → `prepare()` → 取 tokenizer，而取 tokenizer 只认
    /// `HF_ENDPOINT`。排在后面的话，本次向导的最后一步照样走官方源。
    /// 换源那一路也经这里，于是换到的源同样被记住。
    private func download(from source: DownloadSource, root: String) async -> ModelDownloader.Outcome {
        AppLogger.shared.log("向导：选中下载源 \(source.displayName)")
        wiring.recordResolvedSource(source)
        return await ModelDownloader.run(
            root: root,
            alreadyPresent: wiring.alreadyPresent,
            backend: wiring.makeBackend(),
            source: source,
            onProgress: { [weak self] fraction in
                self?.downloadProgress = fraction
                self?.wiring.onDownloadProgress(fraction)
            })
    }

    /// 换个网络再来一次。
    func retryModelDownload() {
        downloadFailure = nil
        startModelDownload()
    }

    /// 「我已经有模型文件」——复用菜单里那个目录选择器，选完照常校验。
    ///
    /// 校验不能省：选错目录的表现原本是「加载时报一个看不懂的错」，
    /// 而这里的用户是第一次开这个应用的人。
    func importExistingModel() {
        guard let url = wiring.chooseModelFolder() else { return }
        switch ModelCatalog.validate(folder: url.path) {
        case .success(let descriptor):
            AppLogger.shared.log("向导：手动导入模型 \(descriptor.name)")
            wiring.adoptModelFolder(descriptor.folder)
            downloadFailure = nil
            downloadProgress = 1
            downloadFinished = true
            advance()
        case .failure(.notAModelFolder(let missing)):
            downloadFailure = Self.importFailureMessage(missing: missing)
        }
    }

    /// 下载失败的整句话。**必须点名是哪个源**——排查时「模型坏了」和
    /// 「这个源不通」是两件完全不同的事，而用户只会转述他看到的那句话。
    nonisolated static func failureMessage(source: DownloadSource) -> String {
        "从\(source.displayName)下载模型失败了。可以换个网络重试，或者直接用你已经有的模型文件。"
    }

    /// 从 A 下载失败、准备换 B 时 B 探不通。两个都点名，各说各的死法。
    nonisolated static func failureMessage(
        source: DownloadSource, alternativeUnreachable alternative: DownloadSource
    ) -> String {
        "从\(source.displayName)下载模型失败了，\(alternative.displayName)也连不上。"
            + "可以换个网络重试，或者直接用你已经有的模型文件。"
    }

    /// 两个源都下载失败了（不是不通，是下到一半断了）。
    nonisolated static let bothFailedMessage =
        "\(DownloadSource.official.displayName)和\(DownloadSource.mirror.displayName)都试过了，"
        + "下载都失败了。可以换个网络重试，或者直接用你已经有的模型文件。"

    /// 两个源都不通。同样点名，且点两个的名。
    nonisolated static let noSourceMessage =
        "\(DownloadSource.official.displayName)和\(DownloadSource.mirror.displayName)都连不上。"
        + "检查一下网络后重试，或者直接用你已经有的模型文件。"

    nonisolated static func importFailureMessage(missing: [String]) -> String {
        "这个目录不是模型目录，缺少：\(missing.joined(separator: "、"))"
    }

    // MARK: - 第五步：试说一句

    var isDictationReady: Bool { wiring.isDictationReady() }

    /// 模型加载失败的原因；nil = 没失败。视图在第五步显示它。
    var modelLoadFailure: String? { wiring.modelLoadFailure() }

    /// 开始 / 结束一次听写。
    ///
    /// **注入的去向已经被改道**（`enter(.testDictation)` 挂上的），
    /// 文本会回到下面的 `receiveDictation`，不经 `TypingSink`、
    /// 不投递任何 CGEvent、不可能落进别的应用。
    func toggleDictation() {
        wiring.toggleDictation()
    }

    /// 这一次听写归不归向导？归就收下（返回 true，文本不出应用），
    /// 不归就返回 false，让它照常注入用户正在用的那个应用。
    ///
    /// **判据是「向导的窗口是不是 key window」，不是「向导停在第几步」**
    /// （2026-08-22 复审的 C-2）。按步骤判的失效链：向导停在第五步、被压在
    /// 别的窗口后面，用户切到微信去试欢迎页刚承诺的那件事，按 ⌥D 说了一句
    /// ——`TargetAppGuard` 一路放行（捕获的是微信、微信仍在前台），
    /// 而这句话被吞进向导的输入框，**微信里什么都没出现**。
    /// 向导可以就这么开着一小时，期间每一次听写都消失。
    private func handleDictation(_ text: String) -> Bool {
        guard wizardOwnsThisDictation else {
            AppLogger.shared.log("向导：这次听写不是从向导发起的（窗口不是 key），照常注入目标应用")
            return false
        }
        dictationText = text
        AppLogger.shared.log("向导：试说一句已落进向导自己的输入框，长度 \(text.count)")
        return true
    }

    /// 向导自己是不是此刻的 key window。
    ///
    /// `Wiring.wizardOwnsDictation` 存在的唯一理由是**测试进程没有窗口服务器**
    /// ——实测（`/tmp/keyprobe`，非应用包进程）`makeKeyAndOrderFront` 之后
    /// `isKeyWindow` 仍是 false，真判据在测试里只能取到一个值。注入点让两个
    /// 分支都跑得到；不注入时走真判据，而它在这个进程里恒为 false，
    /// 也就是**失败方向是「不吞」**——这正是安全的那一边。
    private var wizardOwnsThisDictation: Bool {
        if let override = wiring.wizardOwnsDictation { return override() }
        return window.isKey
    }

    /// 说出来了就算过。
    var canFinish: Bool { !dictationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 完成向导：`markComplete()` 之后关窗，此后再也不弹。
    func complete() {
        finish()
    }

    private func setRedirect(_ handler: ((String) -> Bool)?) {
        wiring.setTranscriptRedirect(handler)
    }
}
