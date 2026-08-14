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
        // 加载模型可能持续一两分钟，而菜单一点即关——状态藏在菜单里
        // 等于没有反馈。图标是加载期唯一可见的信号，必须优先反映它。
        if delegate.model.loadingModelName != nil {
            return "arrow.trianglehead.2.clockwise.rotate.90"
        }
        return switch delegate.model.phase {
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
        Text(model.remoteState.menuLabel(battery: model.remoteBattery))

        if !model.lastText.isEmpty {
            Divider()
            Text("上次：\(model.lastText.prefix(40))")
        }

        Divider()
        Button("开始 / 结束听写  ⌥D") { model.toggle() }

        Divider()
        modelMenu

        Divider()
        Button("打开日志") {
            NSWorkspace.shared.selectFile(
                AppLogger.shared.path,
                inFileViewerRootedAtPath: ""
            )
        }
        Button("退出") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var modelMenu: some View {
        Menu(modelMenuTitle) {
            ForEach(model.availableModels) { candidate in
                Button {
                    model.selectModel(candidate)
                } label: {
                    // 用前缀标记当前生效的模型；菜单项无法直接加勾选标记。
                    Text(candidate.name == model.activeModelName
                         ? "✓ \(candidate.name)"
                         : "   \(candidate.name)")
                }
                .disabled(!model.canSwitchModel)
            }

            if model.availableModels.isEmpty {
                Text("vendor/models 下没有模型")
            }

            Divider()
            Button("其他目录…") { chooseModelFolder() }
                .disabled(!model.canSwitchModel)
        }
        .onAppear { model.refreshAvailableModels() }
    }

    private var modelMenuTitle: String {
        if let loading = model.loadingModelName {
            return "模型：正在加载 \(loading)…"
        }
        return "模型：\(model.activeModelName)"
    }

    /// 打开目录选择器。
    ///
    /// LSUIElement 应用默认不激活，不先 activate 的话面板会出现在
    /// 其他窗口后面且不接受键盘输入。这里是设置类操作，抢焦点无妨——
    /// 听写路径上的 HUD 才必须避免抢焦点。
    private func chooseModelFolder() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "选择 Whisper 模型目录"
        panel.message = "选择包含 AudioEncoder.mlmodelc、TextDecoder.mlmodelc、MelSpectrogram.mlmodelc 的目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            model.selectModelFromFolder(url.path)
        }
    }

    private var statusText: String {
        if let loading = model.loadingModelName {
            return "正在加载模型 \(loading)…首次可能需要一两分钟"
        }
        return switch model.phase {
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
