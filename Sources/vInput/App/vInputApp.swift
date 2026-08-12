import AppKit
import SwiftUI

@main
struct vInputApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            Image(systemName: iconName)
        }
    }

    private var iconName: String {
        switch delegate.model.phase {
        case .idle: "mic"
        case .listening: "mic.fill"
        case .working: "waveform"
        case .error: "exclamationmark.triangle"
        }
    }
}

/// 承载应用级生命周期。快捷键注册必须在启动时完成，
/// 而不是等用户点开菜单栏——否则后台快捷键在首次点击前不可用。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.bootstrap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

private struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Text(statusText)

        if !model.lastText.isEmpty {
            Divider()
            Text("上次：\(model.lastText.prefix(40))")
        }

        Divider()
        Button("开始 / 结束听写  ⌥D") { model.toggle() }
        Divider()
        Button("退出") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        switch model.phase {
        case .idle:
            switch model.permissionStatus {
            case .ready: "就绪"
            case .microphoneMissing: "需要麦克风权限"
            case .accessibilityMissing: "需要辅助功能权限"
            }
        case .listening: "正在聆听…"
        case .working: "正在转写…"
        case .error(let message): "出错：\(message)"
        }
    }
}
