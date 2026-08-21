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
            Image(nsImage: StatusIcon.image(for: StatusIcon.state(
                loadingModelName: delegate.model.loadingModelName,
                phase: delegate.model.phase)))
        }
        .menuBarExtraStyle(.window)
    }
}

/// 承载应用级生命周期。快捷键注册必须在启动时完成，
/// 而不是等用户点开菜单栏——否则后台快捷键在首次点击前不可用。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
