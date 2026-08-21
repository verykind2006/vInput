import AppKit
import SwiftUI

@main
struct vInputApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// `.window` 样式：内容是一个自绘面板（`MenuPanelView`），不是原生菜单。
    ///
    /// 菜单栏图标走 `StatusIcon`（自绘的 V 字声波 mark，五种状态），不再用
    /// SF Symbol：加载模型可能持续一两分钟，而面板一点即关——状态藏在面板里
    /// 等于没有反馈。图标是加载期唯一可见的信号，必须优先反映它，
    /// 这条判断在 `StatusIcon.state(loadingModelName:phase:)` 里。
    var body: some Scene {
        MenuBarExtra {
            MenuPanelView(model: delegate.model)
        } label: {
            // 包成真正的 View（`StatusIconLabel`），不要在这里直接算图。
            // `Image` 没有自己的 body，写在这里等于把状态读取放进 Scene 的
            // body——Scene 只在启动时求值一次，图标从此不再跟着状态变
            // （2026-08-21 实测：听写中图标全程不变琥珀橙）。理由写在
            // `StatusIconLabel` 的注释里。
            StatusIconLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 承载应用级生命周期。快捷键注册必须在启动时完成，
/// 而不是等用户点开菜单栏——否则后台快捷键在首次点击前不可用。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    /// 首次启动向导。**必须由 delegate 持有**：它自己持有窗口，
    /// 局部变量走完 `applicationDidFinishLaunching` 就被释放，窗口跟着没。
    private var onboarding: OnboardingCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 越早越好：它要记的是「vInput 抢到前台之前用户在用哪个应用」，
        // 而这一刻（LSUIElement 应用启动、尚未激活自己）的前台恰好就是答案。
        // 不启动它的话 `dismissMenuPanel()` 无处可还，从面板起的听写会把
        // 文字注进面板自己（R-1）。
        ForegroundAppTracker.shared.start()
        // 在 bootstrap 之前注入：开启校正而没有合法模型时 AppModel 要弹这个
        // 面板。放在这里而不是菜单视图里，是因为它与视图的生命周期无关，
        // 而菜单视图每次打开都会重建。
        model.chooseCorrectionModelFolder = { presentCorrectionModelFolderPanel() }
        model.chooseTranslationModelFolder = { presentCorrectionModelFolderPanel() }
        model.promptForCloudAPIKey = { presentCloudAPIKeyPanel() }
        model.promptForCloudModelIdentifier = { presentCloudModelPanel(current: $0) }
        // 同上，也在 bootstrap 之前：开启云端翻译要先弹一次确认，而
        // `AppModel` 不该知道 `NSAlert` 的存在。没接上时 `useCloudBackend`
        // 的失败方向是「不开」。
        model.confirmCloudBackend = { presentCloudBackendConfirmation() }
        model.bootstrap()
        presentOnboardingIfNeeded()
    }

    /// 首次启动向导。
    ///
    /// **排在 `bootstrap()` 之后**：向导要把下载好的模型交给应用去加载
    /// （`adoptModelFolder`），而 `selectModelFromFolder` 依赖 bootstrap 建好的
    /// transcriber；反过来的话手动导入与下载完成两条路都会静默无效。
    ///
    /// 完成过就不再弹，判据是 `OnboardingState.shouldPresent(isComplete:)`
    /// ——这一条是本批存在的全部理由，没有它向导永远不会出现。
    private func presentOnboardingIfNeeded() {
        let state = OnboardingState()
        guard OnboardingState.shouldPresent(isComplete: state.isComplete) else { return }

        var wiring = OnboardingCoordinator.Wiring()
        // 与 AppModel 用同一个模型根目录。各算各的就会「下载 1.5GB 然后
        // 报告找不到模型」——那正是 `ModelCatalog.resolveRoot` 存在的理由。
        wiring.modelRoot = { [weak self] in self?.model.modelRootPath ?? "" }
        // 先重扫再切换（`adoptDownloadedModel` 里做的第一件事）：切换那一步要
        // 拿到刚落盘的目录，不重扫的话菜单里也看不到它。
        //
        // **走 `adoptDownloadedModel` 而不是直接 `selectModelFromFolder`**：
        // 下载可能在用户正说着话的时候完成，那时换模型会被 `canSwitchModel`
        // 挡下来，而挡下来之后原先再也没有人重试——刚下的 1.5GB 要到下次启动
        // 才生效。现在被推迟的那一次由会话结束时补做，面板上也看得见。
        wiring.adoptModelFolder = { [weak self] folder in
            self?.model.adoptDownloadedModel(folder)
        }
        // 在飞的下载报一份给面板：关掉向导不取消下载，不接这一路的话
        // 那十几分钟里应用看上去什么都没在做。
        wiring.onDownloadProgress = { [weak self] progress in
            self?.model.reportModelDownload(progress: progress)
        }
        wiring.isDictationReady = { [weak self] in self?.model.loadingModelName == nil }
        wiring.toggleDictation = { [weak self] in self?.model.toggle() }
        // 「试说一句」的文字落进向导自己的输入框，不投递任何 CGEvent、
        // 不经 TypingSink，因此不可能打进别的应用。见 RedirectableTextSink。
        wiring.setTranscriptRedirect = { [weak self] handler in
            self?.model.setTranscriptRedirect(handler)
        }

        let coordinator = OnboardingCoordinator(state: state, wiring: wiring)
        onboarding = coordinator
        // present() 开窗的**同时**就把模型下载踢起来（探源 → ModelDownloader.run）。
        // 不是等走到第四步：1.5GB 的等待要被前面三步吸收掉，否则用户就是
        // 干瞪着进度条等十几分钟。
        coordinator.present()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
