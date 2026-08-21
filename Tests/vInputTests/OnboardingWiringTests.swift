import AppKit
import Foundation
import SwiftUI
import Testing

@testable import vInput

/// 首次启动向导的接线不变量。
///
/// # 两种断言，界限画清楚
///
/// **一、真跑一遍**（本文件的大半）。向导的接线被刻意做成不认识 `AppModel`
/// （它 `init` 里就要真麦克风、真快捷键、真 CGEvent tap，测试进程构造不出来）
/// ——`OnboardingCoordinator.Wiring` 的每一项都是闭包，于是「开窗就开下载」
/// 「授权后自己翻页」「试说不走 TypingSink」这几条能被真正驱动一遍，
/// 而不是只证明源码里那一行还在。`OnboardingWindowController` 也真的建得出
/// `NSWindow`（`BenchRecordingWindowTests` 早就这么干了）。
///
/// **二、扫源码**（四条，钉的是「这一行在不在」）。窗口渲染成什么样、系统
/// 权限对话框弹没弹、⌥D 真按下去会怎样——这些在测试进程里没有对应物，
/// 只能钉住源码里那处调用还在，防的是「被后来的人顺手删掉」。
/// 扫源码证明不了它长得对，也证明不了它在真机上能跑，那部分在 Task 8
/// 的真机清单上（见本文件末尾那份清单）。
///
/// # 断言一律先算成 Bool
///
/// 不要把整份源码交给 `#expect`：一旦红了，失败输出会原样打出整个文件，
/// 变异验证时「没红」和「红了但找不到」就分不开了。规矩来自
/// `MenuPanelViewWiringTests`。
@MainActor
@Suite("首次启动向导接线")
struct OnboardingWiringTests {

    // MARK: - 扫源码用的工具（与 MenuPanelViewWiringTests 同一套）

    static func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // vInputTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
        return try String(
            contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 扫源码前先把 `//` 行注释去掉。
    ///
    /// 本文件里那几条注释密度极高的文件（向导窗口、视图）必须能在注释里
    /// 写清「为什么不走 TypingSink」，而整份 `contains` 分不清注释和代码
    /// ——不去掉注释的话，第 4 条（不许出现 TypingSink）会被注释里的说明
    /// 直接判红，而为了让测试绿去删注释是更坏的结果。
    static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else { return line }
                return line[line.startIndex..<slashes.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// 截出某个函数的函数体（从 `签名` 那一行到缩进相同的收尾 `}`）。
    ///
    /// 「下载在开窗时就踢起来」这条不变量的要害是**位置**：`startModelDownload`
    /// 出现在文件里毫无意义，它必须出现在 `present()` 里。整份 `contains`
    /// 分不出这个差别，所以这里按缩进配对括号切一刀。
    static func functionBody(_ source: String, signature: String) -> String? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.contains(signature) }) else { return nil }
        let indent = String(lines[start].prefix { $0 == " " })
        let closing = indent + "}"
        guard
            let end = lines[(start + 1)...].firstIndex(where: { $0 == Substring(closing) })
        else { return nil }
        return lines[start...end].joined(separator: "\n")
    }

    // MARK: - ① 向导到底会不会出现（本批存在的全部理由）

    /// `AppDelegate` 必须问 `OnboardingState.shouldPresent(`。
    ///
    /// 这一条钉的不是风格，是这一批工作有没有意义：删掉它，向导永远不出现，
    /// 而全仓其余 1200 多条测试一条都不会红——「只会双击安装包的人装完能自己
    /// 说出第一句话」这个验收标准直接落空。
    @Test("AppDelegate 启动时问 shouldPresent")
    func appDelegateAsksShouldPresent() throws {
        let source = Self.codeOnly(try Self.source("Sources/vInput/App/vInputApp.swift"))
        let asks = source.contains("OnboardingState.shouldPresent(")
        #expect(
            asks,
            """
            vInputApp.swift 里没有 OnboardingState.shouldPresent( 的调用。
            没有它，首次启动向导永远不会出现——新用户装完之后，
            麦克风权限、辅助功能权限、1.5GB 模型三件事全部无人引导。
            """
        )
        let presents = source.contains("coordinator.present()")
        #expect(
            presents,
            "vInputApp.swift 问过 shouldPresent 却没有 present()：判断做了，窗口没开。"
        )
    }

    // MARK: - ② 下载在开窗时就踢起来，不是走到那一步才踢

    /// `present()` 的函数体里必须有 `startModelDownload()`。
    ///
    /// 挪到第四步的视图里去调也能跑通、界面也不会报错——只是用户要在进度条
    /// 前面干等 1.5GB（慢网络下十几分钟）。这正是「能跑」与「能用」的差别，
    /// 而它只在真机慢网络上才显形，本地测不出来，所以钉源码位置。
    @Test("下载在 present() 里就踢起来")
    func downloadStartsAtPresentTime() throws {
        let source = Self.codeOnly(
            try Self.source("Sources/vInput/Onboarding/OnboardingWindow.swift"))
        let body = Self.functionBody(source, signature: "func present()")
        #expect(body != nil, "OnboardingWindow.swift 里找不到 present() 的函数体。")
        let kicksOff = body?.contains("startModelDownload()") ?? false
        #expect(
            kicksOff,
            """
            OnboardingCoordinator.present() 里没有 startModelDownload()。
            下载改成走到第四步才开始的话，欢迎/麦克风/辅助功能三步的时间白白
            浪费，用户要盯着进度条干等 1.5GB。
            """
        )

        // 反面：第四步的视图不许自己去踢下载。踢了就等于把上面那条绕开，
        // 而且两处各踢一次还会重复下载。
        let viewSource = Self.codeOnly(
            try Self.source("Sources/vInput/Onboarding/OnboardingView.swift"))
        let viewKicksOff = viewSource.contains("startModelDownload()")
        #expect(
            !viewKicksOff,
            "OnboardingView 自己调了 startModelDownload()：下载的起点必须只有 present() 一处。"
        )
    }

    // MARK: - ③ 辅助功能那一步必须轮询

    /// 辅助功能没有对话框、没有回调、没有通知——不轮询的话，用户在系统设置里
    /// 勾完开关切回来，向导还停在原地，他无从判断向导察觉了没有。
    @Test("辅助功能步骤轮询授权状态")
    func accessibilityStepPolls() throws {
        let source = Self.codeOnly(
            try Self.source("Sources/vInput/Onboarding/OnboardingWindow.swift"))
        let hasPoller = source.contains("poller.start(trusted:")
        #expect(
            hasPoller,
            """
            OnboardingCoordinator 没有启动辅助功能轮询（poller.start(trusted:)）。
            辅助功能授权没有任何系统回调，不轮询的话用户勾完开关切回来，
            向导会一直停在「请去开启权限」那一屏。
            """
        )
        // 间隔是真值断言，不是扫源码：0.5 秒是「勾完切回来就已经过了」
        // 与「别空转」之间的取值，被改大到几秒就退化成「看着像没反应」。
        #expect(
            AccessibilityPoller.interval == 0.5,
            "辅助功能轮询间隔不是 0.5 秒，用户勾完开关切回来会看到向导发呆。"
        )
    }

    // MARK: - ④ 试说一句落进向导自己的输入框

    /// 向导这两份源码里**不许出现** `TypingSink` / `ClipboardSink`。
    ///
    /// 走那条路的话，文字去哪由「当前焦点是谁」决定——用户在录音途中点一下
    /// 别的窗口，这句话就打进了别人的文档里。向导是给第一次用这个应用的人
    /// 看的，不能拿「向导此刻碰巧是前台」当保证。
    @Test("试说一句不经 TypingSink")
    func testDictationDoesNotUseTypingSink() throws {
        let window = Self.codeOnly(
            try Self.source("Sources/vInput/Onboarding/OnboardingWindow.swift"))
        let view = Self.codeOnly(
            try Self.source("Sources/vInput/Onboarding/OnboardingView.swift"))

        let windowTypes = window.contains("TypingSink")
        #expect(
            !windowTypes,
            """
            OnboardingWindow.swift 里出现了 TypingSink。
            「试说一句」必须改道到向导自己的输入框；走 TypingSink 就是往
            「当前焦点」投递 CGEvent，用户中途点了别的窗口就会打进别人的文档。
            """
        )
        let viewTypes = view.contains("TypingSink") || view.contains("ClipboardSink")
        #expect(!viewTypes, "OnboardingView.swift 里出现了 TypingSink/ClipboardSink。")

        // 正面：改道必须真的被挂上。只证明「没走那条路」还不够——
        // 两条路都不走的话，试说一句什么都不会发生。
        let redirects = window.contains("setTranscriptRedirect")
        #expect(
            redirects,
            "OnboardingCoordinator 没有挂转写改道，「试说一句」的文字无处可去。"
        )
    }

    // MARK: - 窗口本身（真的建 NSWindow）

    @Test("打开前没有窗口")
    func windowStartsClosed() {
        #expect(OnboardingWindowController().isOpen == false)
    }

    @Test("打开后窗口存在、关闭后放掉引用")
    func windowOpensAndCloses() {
        let controller = OnboardingWindowController()
        controller.show(Text("向导"))
        #expect(controller.isOpen)
        controller.close()
        #expect(controller.isOpen == false)
        #expect(controller.window == nil)
    }

    /// 关窗必须通知调用方收尾：不收的话轮询会一直空转，
    /// 转写改道会一直挂着——此后每一次听写的文字都被送进一个已经不存在的
    /// 界面，日志还写着「注入成功」。
    @Test("关闭时通知调用方收尾，且只通知一次")
    func windowNotifiesOnClose() {
        let controller = OnboardingWindowController()
        var closed = 0
        controller.onClose = { closed += 1 }
        controller.show(Text("向导"))
        #expect(closed == 0)
        controller.close()
        #expect(closed == 1)
        // close() 与 windowWillClose 两条路都会走到收尾，重复回调必须是空操作。
        controller.close()
        #expect(closed == 1)
    }

    @Test("已经开着时重复调用不换窗口")
    func windowShowTwiceKeepsSameWindow() {
        let controller = OnboardingWindowController()
        controller.show(Text("第一次"))
        let first = controller.window
        controller.show(Text("第二次"))
        #expect(controller.window === first)
        controller.close()
    }

    /// **与录制窗的唯一有意差别**：向导不锁死外观，跟随系统。
    ///
    /// 录制窗锁 `.aqua` 是因为用户要求那扇窗白底黑字。向导是新用户对这个应用
    /// 的第一印象，深色模式下弹出一扇突兀的白窗只会显得没做完。
    @Test("窗口不锁死浅色外观")
    func windowFollowsSystemAppearance() {
        let controller = OnboardingWindowController()
        controller.show(Text("向导"))
        let appearance = controller.window?.appearance
        #expect(
            appearance == nil,
            "向导窗口锁死了外观（\(String(describing: appearance?.name))）。它应该跟随系统深浅色。"
        )
        controller.close()
    }

    /// ARC 下窗口由控制器持有，保持 `isReleasedWhenClosed` 的默认值 true 会
    /// 造成过度释放。这是从录制窗那边继承的三条硬约束之一——它平时不出事，
    /// 出事就是关窗时崩溃，而崩溃点离原因很远。
    @Test("窗口不由系统释放")
    func windowIsNotReleasedWhenClosed() {
        let controller = OnboardingWindowController()
        controller.show(Text("向导"))
        #expect(
            controller.window?.isReleasedWhenClosed == false,
            "窗口 isReleasedWhenClosed 是 true：ARC 已经持有它了，会过度释放。"
        )
        controller.close()
    }

    // MARK: - 轮询器本身

    /// 没授权时不回调，授权后回调**一次**并自己停掉。
    ///
    /// 不停的话，翻到下一步之后定时器还在跑，每 0.5 秒把向导再往前推一步
    /// ——用户会看到向导自己一路翻到底。
    @Test("授权后回调一次并自动停")
    func pollerFiresOnceThenStops() {
        let poller = AccessibilityPoller()
        var trusted = false
        var granted = 0
        poller.start(trusted: { trusted }, onGranted: { granted += 1 })

        poller.tick()
        #expect(granted == 0)
        #expect(poller.isRunning)

        trusted = true
        poller.tick()
        #expect(granted == 1)
        #expect(poller.isRunning == false)

        // 停掉之后再被驱动一次也不许再回调：invalidate 与已经排进队列的
        // 那一次触发之间有窗口。
        poller.tick()
        #expect(granted == 1)
    }

    @Test("stop 之后不再回调")
    func pollerStopSilencesIt() {
        let poller = AccessibilityPoller()
        var granted = 0
        poller.start(trusted: { true }, onGranted: { granted += 1 })
        poller.stop()
        poller.tick()
        #expect(granted == 0)
    }

    // MARK: - 改道注入口

    /// 挂上改道时，文本不再交给平常那条路——**一个 CGEvent 都不会被投递**。
    @Test("挂上改道后文本不再流向平常那条路")
    func redirectKeepsTextInsideTheApp() throws {
        let fallback = RecordingSink()
        let sink = RedirectableTextSink(fallback: fallback)

        var received: [String] = []
        sink.redirect = { received.append($0) }
        try sink.send("你好")
        #expect(received == ["你好"])
        #expect(
            fallback.sent.isEmpty,
            "改道挂着的时候文本仍然走了平常那条路：会被打进别的应用。"
        )

        // 摘掉之后必须原样回到平常那条路，否则此后每一次听写都静默消失。
        sink.redirect = nil
        try sink.send("再见")
        #expect(fallback.sent == ["再见"])
        #expect(received == ["你好"])
    }

    // MARK: - 接线：真跑一遍

    private func makeDefaults() -> UserDefaults {
        let name = "onboarding-wiring-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// 造一个全部依赖都是假的向导。
    private func makeCoordinator(
        microphone: Bool = true,
        accessibility: Bool = true,
        alreadyPresent: Bool = false,
        backend: FakeDownloadBackend? = nil,
        reachable: Set<DownloadSource> = [.official, .mirror],
        chooseFolder: URL? = nil,
        onAdopt: @escaping (String) -> Void = { _ in },
        probeCounter: ProbeCounter = ProbeCounter(),
        onRedirect: @escaping (((String) -> Void)?) -> Void = { _ in }
    ) -> (OnboardingCoordinator, OnboardingState) {
        // 默认参数表达式在 nonisolated 上下文里求值，而 FakeDownloadBackend
        // 是 @MainActor 的——只能在这里造。
        let backend = backend ?? FakeDownloadBackend()
        let state = OnboardingState(defaults: makeDefaults())
        var wiring = OnboardingCoordinator.Wiring()
        var permissions = Permissions()
        permissions.microphoneAuthorized = { microphone }
        permissions.accessibilityTrusted = { accessibility }
        wiring.permissions = permissions
        wiring.modelRoot = { "/tmp/vinput-onboarding-test" }
        wiring.alreadyPresent = { _ in alreadyPresent }
        wiring.probe = { source in
            probeCounter.bump()
            return reachable.contains(source) ? .responded(millis: source == .mirror ? 10 : 20)
                : .unreachable
        }
        wiring.makeBackend = { backend }
        wiring.chooseModelFolder = { chooseFolder }
        wiring.adoptModelFolder = onAdopt
        wiring.setTranscriptRedirect = onRedirect
        return (OnboardingCoordinator(state: state, wiring: wiring), state)
    }

    /// **本批的核心不变量**：开窗那一下下载就动了，此刻还停在欢迎页。
    ///
    /// 这一条是真跑的，不是扫源码：present() 之后 backend 真的被调到了，
    /// 而 `state.step` 仍是 `.welcome`。
    @Test("present() 当场就把下载踢起来，人还在欢迎页")
    func presentKicksOffDownloadWhileStillOnWelcome() async throws {
        let backend = FakeDownloadBackend()
        let (coordinator, state) = makeCoordinator(backend: backend)

        coordinator.present()
        #expect(state.step == .welcome, "开窗时不该已经翻到下载页。")

        try await waitUntil { coordinator.downloadFinished }
        #expect(
            backend.calls.count == 1,
            """
            开窗之后下载没有动（backend 一次都没被调到）。
            下载必须在 present() 时就开始，否则用户要在第四步干等 1.5GB。
            """
        )
        #expect(state.step == .welcome, "下载跑完不该自己翻页——翻页是用户点出来的。")
        coordinator.close()
    }

    /// 已经有模型就**一个包都不出**：不探测，也不下载。
    ///
    /// 这条同时是 `TranslationAttachmentCoordinatorTests` 那份出站面清单里
    /// 给 `EndpointProbe.swift` 写的那句「默认就不发」的证据。
    @Test("模型已在本地时不探测、不下载")
    func skipsDownloadWhenModelPresent() {
        let backend = FakeDownloadBackend()
        let probes = ProbeCounter()
        let (coordinator, _) = makeCoordinator(
            alreadyPresent: true, backend: backend, probeCounter: probes)
        coordinator.present()
        #expect(coordinator.downloadFinished)
        #expect(backend.calls.isEmpty)
        #expect(
            probes.count == 0,
            "模型已经在本地却还是探测了下载源：本该一个网络包都不出。"
        )
        coordinator.close()
    }

    /// 谁快用谁：镜像 10ms、官方 20ms，该选镜像。
    @Test("下载走探测选出来的那个源")
    func downloadUsesProbedSource() async throws {
        let backend = FakeDownloadBackend()
        let (coordinator, _) = makeCoordinator(backend: backend)
        coordinator.present()
        try await waitUntil { coordinator.downloadFinished }
        #expect(backend.calls == [DownloadSource.mirror.endpoint])
        coordinator.close()
    }

    /// 下完了要**交给应用真的用上**，否则用户下了 1.5GB，
    /// 菜单里还是「没有模型」，得重启才认。
    @Test("下载完成后把模型交给应用")
    func downloadAdoptsTheModelFolder() async throws {
        var adopted: [String] = []
        let (coordinator, _) = makeCoordinator(onAdopt: { adopted.append($0) })
        coordinator.present()
        try await waitUntil { coordinator.downloadFinished }
        #expect(
            adopted == ["/tmp/vinput-onboarding-test/\(ModelDownloader.variant)"],
            "下载完成后没有把模型目录交给应用：用户下完 1.5GB 还得重启才能用。"
        )
        coordinator.close()
    }

    /// 失败的话必须说清是哪个源失败的——用户只会转述他看到的那句话。
    @Test("下载失败的提示点名是哪个源")
    func downloadFailureNamesTheSource() async throws {
        let backend = FakeDownloadBackend()
        backend.shouldFail = true
        let (coordinator, _) = makeCoordinator(backend: backend, reachable: [.official])
        coordinator.present()
        try await waitUntil { coordinator.downloadFailure != nil }
        let mentionsSource =
            coordinator.downloadFailure?.contains(DownloadSource.official.displayName) ?? false
        #expect(
            mentionsSource,
            """
            下载失败的提示里没有出现「\(DownloadSource.official.displayName)」。
            不点名的话，用户转述过来的只有「下载失败了」，分不清是模型坏了
            还是这个源不通。
            """
        )
        coordinator.close()
    }

    /// 两个源都不通时，两个名字都要出现，且要给手动导入的活路。
    @Test("两个源都不通时点两个源的名")
    func bothSourcesUnreachableNamesBoth() async throws {
        let (coordinator, _) = makeCoordinator(reachable: [])
        coordinator.present()
        try await waitUntil { coordinator.downloadFailure != nil }
        let text = coordinator.downloadFailure ?? ""
        #expect(text.contains(DownloadSource.official.displayName))
        #expect(text.contains(DownloadSource.mirror.displayName))
        coordinator.close()
    }

    /// 「我已经有模型文件」：目录合法就采纳、翻页；不合法要说缺了什么。
    @Test("手动导入合法目录会被采纳")
    func manualImportAcceptsValidFolder() throws {
        let folder = try makeFakeModelFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var adopted: [String] = []
        let state = OnboardingState(defaults: makeDefaults())
        var wiring = OnboardingCoordinator.Wiring()
        var permissions = Permissions()
        permissions.microphoneAuthorized = { true }
        permissions.accessibilityTrusted = { true }
        wiring.permissions = permissions
        wiring.modelRoot = { "/tmp/vinput-onboarding-test" }
        wiring.alreadyPresent = { _ in true }
        wiring.chooseModelFolder = { folder }
        wiring.adoptModelFolder = { adopted.append($0) }
        let coordinator = OnboardingCoordinator(state: state, wiring: wiring)

        coordinator.present()
        coordinator.advance()  // welcome → downloadModel（两项权限都已给）
        #expect(state.step == .downloadModel)
        coordinator.importExistingModel()
        #expect(adopted == [folder.path])
        #expect(state.step == .testDictation)
        coordinator.close()
    }

    @Test("手动导入选错目录会说清缺什么")
    func manualImportRejectsWrongFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let (coordinator, _) = makeCoordinator(alreadyPresent: true, chooseFolder: folder)
        coordinator.present()
        coordinator.importExistingModel()
        let says = coordinator.downloadFailure?.contains("AudioEncoder.mlmodelc") ?? false
        #expect(says, "选错目录时没有说清缺了哪几个文件夹。")
        coordinator.close()
    }

    /// 进到辅助功能那一步就开始轮询，走掉就停。
    ///
    /// 「走掉就停」不停的后果是纯空转，真机上完全看不出来。
    @Test("进辅助功能步开轮询，离开就停")
    func pollingStartsAndStopsWithTheStep() {
        var trusted = false
        let state = OnboardingState(defaults: makeDefaults())
        var wiring = OnboardingCoordinator.Wiring()
        var permissions = Permissions()
        permissions.microphoneAuthorized = { true }
        permissions.accessibilityTrusted = { trusted }
        wiring.permissions = permissions
        wiring.alreadyPresent = { _ in true }
        let coordinator = OnboardingCoordinator(state: state, wiring: wiring)

        coordinator.present()
        coordinator.advance()  // welcome → accessibility（麦克风已给、辅助功能没给）
        #expect(state.step == .accessibility)
        #expect(coordinator.isPollingAccessibility)

        // 用户在系统设置里勾上了开关：下一格轮询就该自己翻页。
        trusted = true
        coordinator.pollAccessibilityOnce()
        #expect(
            state.step == .downloadModel,
            "辅助功能授权之后向导没有自己往前走，用户会一直盯着「请去开启权限」。"
        )
        #expect(
            coordinator.isPollingAccessibility == false,
            "离开辅助功能步之后轮询还在跑：纯空转，而且会把向导一路推到底。"
        )
        coordinator.close()
    }

    /// **不经轮询地离开辅助功能步，轮询同样要停。**
    ///
    /// 上一条走的是「轮询自己发现授权了」那条路——`AccessibilityPoller.tick()`
    /// 在回调前就把自己停了，所以它证明不了「切步骤会收掉轮询」这件事。
    /// 这一条直接调 `advance()` 翻页（真机上的对应情形：用户在系统设置里勾完
    /// 开关、但恰好在下一格轮询之前点了什么导致向导前进）。
    /// 不停的后果是定时器一直空转，而且下一次授权会把向导再往前推一步。
    @Test("不经轮询地翻页也要停掉轮询")
    func leavingAccessibilityStepStopsPollingEvenWithoutATick() {
        var trusted = false
        let state = OnboardingState(defaults: makeDefaults())
        var wiring = OnboardingCoordinator.Wiring()
        var permissions = Permissions()
        permissions.microphoneAuthorized = { true }
        permissions.accessibilityTrusted = { trusted }
        wiring.permissions = permissions
        wiring.alreadyPresent = { _ in true }
        let coordinator = OnboardingCoordinator(state: state, wiring: wiring)

        coordinator.present()
        coordinator.advance()
        #expect(state.step == .accessibility)
        #expect(coordinator.isPollingAccessibility)

        // 直接翻页，一格轮询都不走。
        trusted = true
        coordinator.advance()
        #expect(state.step == .downloadModel)
        #expect(
            coordinator.isPollingAccessibility == false,
            "切步骤没有收掉辅助功能轮询：定时器会一直空转，而且会再把向导推一步。"
        )
        coordinator.close()
    }

    /// **关窗也要停掉轮询。**
    ///
    /// 用户停在辅助功能那一步、决定「以后再说」直接关窗——不收的话定时器
    /// 由 runloop 持有，会在整个应用生命周期里每 0.5 秒空转一次，
    /// 而且他之后真去开了权限时，还会去推一个已经不存在的向导。
    /// 这条与上面两条是不同的出口，`enter()` 里那次 stop 管不到它。
    @Test("关窗停掉辅助功能轮询")
    func closingWindowStopsPolling() {
        let (coordinator, state) = makeCoordinator(
            accessibility: false, alreadyPresent: true)
        coordinator.present()
        coordinator.advance()
        #expect(state.step == .accessibility)
        #expect(coordinator.isPollingAccessibility)

        coordinator.close()
        #expect(
            coordinator.isPollingAccessibility == false,
            "关窗之后辅助功能轮询还在跑：定时器由 runloop 持有，会一直空转到应用退出。"
        )
    }

    /// 进「试说一句」挂改道，走掉/关窗摘掉。
    ///
    /// 忘了摘的后果最难查：此后每一次听写的文字都被送进一个已经关掉的窗口，
    /// 而日志里还写着「注入成功」。
    @Test("试说一句挂改道，关窗摘掉")
    func redirectIsAttachedOnTestStepAndDetachedOnClose() {
        var attached: [Bool] = []
        let (coordinator, state) = makeCoordinator(
            alreadyPresent: true,
            onRedirect: { attached.append($0 != nil) })

        coordinator.present()
        coordinator.advance()  // → downloadModel
        coordinator.advance()  // → testDictation
        #expect(state.step == .testDictation)
        #expect(attached.last == true, "进「试说一句」没有挂上改道，说出来的话无处可去。")

        coordinator.close()
        #expect(
            attached.last == false,
            """
            关窗之后转写改道还挂着。此后每一次听写的文字都会被送进一个已经
            不存在的界面，而日志里还写着「注入成功」。
            """
        )
    }

    /// 试说出来的字落进 coordinator 自己的字段（就是向导那个输入框），
    /// 说出来了才允许「完成」。
    @Test("试说的文字落进向导自己的输入框，说了才算过")
    func dictationLandsInTheWizardsOwnField() {
        var handler: ((String) -> Void)?
        let (coordinator, state) = makeCoordinator(
            alreadyPresent: true,
            onRedirect: { handler = $0 })

        coordinator.present()
        coordinator.advance()
        coordinator.advance()
        #expect(state.step == .testDictation)
        #expect(coordinator.canFinish == false, "一个字都没说就能点「完成」。")

        // 模拟会话把转写结果交给改道口。
        handler?("今天天气不错")
        #expect(coordinator.dictationText == "今天天气不错")
        #expect(coordinator.canFinish)

        coordinator.complete()
        #expect(state.isComplete, "完成向导之后 isComplete 没有落盘，下次启动会再弹一次。")
        #expect(coordinator.isWindowOpen == false)
    }

    // MARK: - 「一共几步」

    /// 全新用户走满 5 步；两项权限都已给的（重装、或早就手动开过）只走 3 步。
    ///
    /// 写死「一共 5 步」的话，第一屏那句话对后一种人就是错的。
    @Test("步数按实际要走的算，不是写死 5")
    func plannedStepsFollowGrantedPermissions() {
        let fresh = OnboardingCoordinator.plannedSteps(microphone: false, accessibility: false)
        #expect(fresh == [.welcome, .microphone, .accessibility, .downloadModel, .testDictation])

        let granted = OnboardingCoordinator.plannedSteps(microphone: true, accessibility: true)
        #expect(
            granted == [.welcome, .downloadModel, .testDictation],
            "权限都已给的人也被告知要走 5 步：第一句话就不准。"
        )

        let micOnly = OnboardingCoordinator.plannedSteps(microphone: true, accessibility: false)
        #expect(micOnly == [.welcome, .accessibility, .downloadModel, .testDictation])
    }

    @Test("步骤指示按计划里的位置算")
    func stepIndicatorCountsWithinThePlan() {
        let planned: [OnboardingState.Step] = [.welcome, .downloadModel, .testDictation]
        #expect(
            OnboardingCoordinator.stepIndicator(step: .downloadModel, planned: planned)
                == "第 2 / 3 步")
        // 不在计划里就不显示，宁可不显示也不显示一个错的。
        #expect(OnboardingCoordinator.stepIndicator(step: .microphone, planned: planned) == nil)
    }

    // MARK: - 网络探测里能榨出来的那部分

    /// 探测请求的形状。真发请求那一层测不了（要联网），但「探哪个 URL、
    /// 用什么方法、超时多久、绕不绕缓存」全是会写错的部分。
    @Test("探测请求是短超时的 HEAD，且绕开缓存")
    func probeRequestShape() throws {
        let request = try #require(EndpointProbe.request(for: .mirror))
        #expect(request.httpMethod == "HEAD")
        #expect(request.timeoutInterval == EndpointProbe.timeout)
        #expect(
            request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData,
            "探测走了缓存：量到的是本机磁盘速度，两个源会双双报出个位数毫秒，选源从此无意义。"
        )
        #expect(request.url?.absoluteString.hasPrefix(DownloadSource.mirror.endpoint) == true)
        #expect(request.url?.absoluteString.contains("whisperkit-coreml") == true)
    }

    /// 只有传输层没回来才算不通。
    ///
    /// 早一版把非 2xx 也判成 unreachable，结果 huggingface.co 对 HEAD 回 405
    /// 就被判死——一个其实能用的源被排除掉，向导只好去要用户手动导入模型。
    @Test("只有传输层失败才算不通")
    func probeResultMapping() {
        #expect(EndpointProbe.result(elapsed: 0.12, failed: false) == .responded(millis: 120))
        #expect(EndpointProbe.result(elapsed: 0.12, failed: true) == .unreachable)
        // 至少 1 毫秒：两个源都量到 0 的话，min 的结果取决于数组顺序。
        #expect(EndpointProbe.result(elapsed: 0, failed: false) == .responded(millis: 1))
    }

    // MARK: - 测试工具

    /// 等一个条件成立。向导里的下载是 `Task`，没有可 await 的句柄
    /// （有意如此：关窗不该取消已经下了几百 MB 的下载）。
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                Issue.record("等待超时：条件始终不成立")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func makeFakeModelFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-model-\(UUID().uuidString)")
        for entry in ModelCatalog.requiredEntries {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(entry), withIntermediateDirectories: true)
        }
        return folder
    }
}

/// 数一数探测发了几次。
///
/// 用引用类型是因为 `Wiring.probe` 是 `@Sendable` 的，闭包里改不了局部变量。
final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

/// 只记下收到过什么的假注入口。
@MainActor
private final class RecordingSink: TextSink {
    var sent: [String] = []
    func send(_ text: String) throws { sent.append(text) }
}

@MainActor
private final class FakeDownloadBackend: ModelDownloadBackend {
    var calls: [String] = []
    var shouldFail = false
    func download(
        variant: String, into root: String, endpoint: String,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        calls.append(endpoint)
        onProgress(0.5)
        if shouldFail { throw ModelDownloadError.transportFailed }
    }
}
