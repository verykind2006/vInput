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
        // 在 bootstrap 之前注入：开启校正而没有合法模型时 AppModel 要弹这个
        // 面板。放在这里而不是菜单视图里，是因为它与视图的生命周期无关，
        // 而菜单视图每次打开都会重建。
        model.chooseCorrectionModelFolder = { presentCorrectionModelFolderPanel() }
        model.bootstrap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

/// 弹出校正模型目录选择器，返回用户选中的目录（取消时为 nil）。
///
/// 提到文件作用域而不是留在菜单视图里：两个调用方（菜单里的「指定校正
/// 模型…」，以及 `AppModel` 在开启校正却没有合法模型时的追问）需要同一个
/// 面板，而后者与视图的生命周期无关。
///
/// **`activate` 不能去掉**：LSUIElement 应用默认不激活，不先 activate 的话
/// 面板会出现在其他窗口后面且不接受键盘输入。这里是设置类操作，抢焦点无妨
/// ——听写路径上的 HUD 才必须避免抢焦点。
@MainActor
private func presentCorrectionModelFolderPanel() -> URL? {
    NSApplication.shared.activate(ignoringOtherApps: true)

    let panel = NSOpenPanel()
    panel.title = "选择校正模型目录"
    panel.message = "选择本地 MLX 模型目录（含 config.json、tokenizer_config.json 与 .safetensors 权重文件）"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false

    guard panel.runModal() == .OK else { return nil }
    return panel.url
}

private struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Text(statusText)
        Text(model.remoteState.menuLabel(battery: model.remoteBattery))
        // 鼠标那一行只在功能启用时显示：关掉时多一行「未启用」只是噪音。
        if AppModel.mouseEnabled {
            Text(model.mouseState.menuLabel(battery: model.mouseBattery))
        }

        if !model.lastText.isEmpty {
            Divider()
            Text("上次：\(model.lastText.prefix(40))")
        }

        Divider()
        Button("开始 / 结束听写  ⌥D") { model.toggle() }
        // 转写失败时音频保留着，此前却点不到（Transcriber.swift:17：全仓
        // 只有测试在调 retry()）。禁用而不是隐藏：菜单项时有时无的话，
        // 用户根本不会知道存在这么个东西，也就等不到需要它的那一刻。
        Button(model.canRetry ? "重试上次转写" : "重试上次转写（没有可重试的）") {
            model.retryLastTranscription()
        }
        .disabled(!model.canRetry)

        Divider()
        modelMenu
        correctionMenu

        // 基准集录制。开发期工具，VINPUT_BENCH=1 才显示。
        if AppModel.benchEnabled {
            Divider()
            benchMenu
        }

        // BLE 扫描诊断。开发期工具，VINPUT_BLE_SCAN=1 才显示。
        if AppModel.bleScanEnabled {
            Divider()
            bleScanMenu
        }

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

    /// 校正子菜单。做成子菜单而非顶层两个按钮：开关与模型目录是同一件事的
    /// 两个面，且与上面的「模型：…」子菜单结构对齐，顶层菜单不再变长。
    @ViewBuilder
    private var correctionMenu: some View {
        Menu("校正：\(model.correctionEnabled ? "开" : "关")") {
            Button(model.correctionEnabled ? "关闭校正" : "开启校正") {
                model.toggleCorrection()
            }

            Divider()
            // 让用户知道当前用的是哪个模型——校正效果好坏几乎全由它决定。
            // 未指定时不再说「默认（首次使用时下载）」：开启校正现在必须
            // 先有一个本地合法目录，那句话会让人以为不选也能用。
            Text(model.correctionModelName.map { "模型：\($0)" } ?? "模型：未指定（开启校正时选择）")
            Button("指定校正模型…") {
                if let url = presentCorrectionModelFolderPanel() {
                    model.selectCorrectionModel(directory: url)
                }
            }
        }
    }

    /// 基准集录制。**开发期工具**，只在 `VINPUT_BENCH=1` 时出现在菜单里，
    /// 理由见 `AppModel.benchEnabled`。
    ///
    /// 菜单里只留一个入口，全部录制界面搬到独立窗口
    /// （`BenchRecordingWindowController`）：菜单里的 `Text` 在 macOS 上是
    /// 不可交互的说明文字，字号与颜色都改不动，用户照着它读了 23 条之后
    /// 反馈「字太小、灰字看不清」。
    @ViewBuilder
    private var benchMenu: some View {
        Button("开始录制基准集") { model.startBenchRecording() }
    }

    /// BLE 扫描诊断。**开发期工具**，只在 `VINPUT_BLE_SCAN=1` 时出现。
    ///
    /// 扫描在启动后自动开始（延后几秒让遥控器先连上），所以这里只需要
    /// 两个手动入口：
    ///
    /// - 「结束…并汇总」是**主入口**。合计行（哪个特征来了多少包）只在
    ///   收尾时才产生，用户按完键必须点它一下，日志里才有第三个问题的答案。
    /// - 「重新开始」用于设备当时没醒、或要换一支设备再扫一轮——
    ///   不必退出应用重开。
    @ViewBuilder
    private var bleScanMenu: some View {
        Button("结束 BLE 扫描并汇总") { model.stopBLEScan() }
        Button("重新开始 BLE 扫描") { model.startBLEScan() }
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
