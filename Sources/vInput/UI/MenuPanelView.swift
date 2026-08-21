import AppKit
import SwiftUI

/// 菜单栏面板（`MenuBarExtra` `.window` 样式的内容视图）。
///
/// 布局与视觉见设计定稿 ②；**一切文案与动作复用 model 层现有函数，零增减**
/// ——旧 `MenuContent` 里的每一个按钮、每一条禁用条件、每一道环境变量门控
/// 都在这里有对应的一项（迁移对照清单在 Task 7 的提交信息里）。
///
/// 视图里**不新写任何面向用户的字符串**：拼在视图里就没有任何测试守得住它
/// （与 `HUDViewModel`、`MenuPanelModel` 同一条分工）。唯一的例外是设置四行
/// 的行标题（「模型」「校正」「输出语言」「翻译后端」），它们是旧菜单标题
/// 里那半截前缀搬了个位置——值那侧因此去掉重复的前缀，见 `stripPrefix`。
struct MenuPanelView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            primaryButton
            deviceCards
            lastTranscriptCard
            settingsList
            devTools
            footer
        }
        .frame(width: 300)
        .background(VITheme.panelBackground)
        // 面板底色是写死的深色 #1D1D1F，而 `.primary` / `.secondary` 会跟着
        // 系统外观走——浅色模式下不钉死的话正文会是黑字压深底，读不了。
        .environment(\.colorScheme, .dark)
        // 打开菜单时重扫模型目录，这样新下载的模型无需重启即可出现
        // （旧 MenuContent 挂在「模型」子菜单的 onAppear 上，面板改成整体挂）。
        .onAppear { model.refreshAvailableModels() }
    }

    // MARK: - 头部：VMark + 名字 + 状态

    private var header: some View {
        let status = MenuPanelModel.headerStatus(
            loadingModelName: model.loadingModelName,
            phase: model.phase,
            permission: model.permissionStatus
        )
        return HStack(spacing: 8) {
            VMarkShape(bars: VMark.bars)
                .fill(VITheme.accent)
                .frame(width: 15, height: 15)
            Text("vInput").font(.system(size: 13, weight: .semibold))
            Spacer()
            Circle().fill(toneColor(status.tone)).frame(width: 6, height: 6)
            Text(status.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.init(top: 12, leading: 14, bottom: 10, trailing: 14))
    }

    private func toneColor(_ tone: MenuPanelModel.Tone) -> Color {
        switch tone {
        case .ok: .green
        case .recording: VITheme.accent
        case .busy: .secondary
        case .error: .red
        }
    }

    // MARK: - 主按钮

    private var primaryButton: some View {
        Button {
            model.toggle()
        } label: {
            HStack {
                Text(model.phase == .listening ? "结束听写" : "开始听写")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("⌥D")
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            }
            .foregroundStyle(Color(red: 0.10, green: 0.07, blue: 0.02))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(
                LinearGradient(
                    colors: [VITheme.accentGradientTop, VITheme.accentGradientBottom],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(model.loadingModelName != nil)
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    // MARK: - 设备卡

    @ViewBuilder
    private var deviceCards: some View {
        let cards = MenuPanelModel.deviceCards(
            remote: model.remoteState, remoteBattery: model.remoteBattery,
            mouseEnabled: AppModel.mouseEnabled,
            mouse: model.mouseState, mouseBattery: model.mouseBattery)
        if !cards.isEmpty {
            // alignment: .top —— .muted 那张卡的文案会折成两行，不对齐顶部
            // 会把兄弟卡一起撑歪（Task 6 QA 复核实测）。
            HStack(alignment: .top, spacing: 8) {
                // id 用 kind 不用 title：拿中文文案当身份是个坑
                // （Task 6 QA 复核，DeviceCard 已 Identifiable）。
                ForEach(cards) { card in
                    HStack(spacing: 5) {
                        // 复用头部那只 toneColor，不在视图里再手写一遍颜色判断。
                        Circle().fill(toneColor(card.tone))
                            .frame(width: 5, height: 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(card.title).font(.system(size: 11))
                            Text(card.detail)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(VITheme.contentBackground, in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    // MARK: - 上次转写

    @ViewBuilder
    private var lastTranscriptCard: some View {
        if !model.lastText.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("上次转写").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    // 转写失败时音频保留着，此前却点不到（Transcriber.swift:17：全仓
                    // 只有测试在调 retry()）。禁用而不是隐藏：入口时有时无的话，
                    // 用户根本不会知道存在这么个东西，也就等不到需要它的那一刻。
                    Button("重试 ↻") { model.retryLastTranscription() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(model.canRetry ? VITheme.accent : Color.secondary)
                        .disabled(!model.canRetry)
                }
                Text(model.lastText.prefix(60))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VITheme.contentBackground, in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    // MARK: - 设置四行（旧的四个子菜单，一比一搬进面板内展开）

    private var settingsList: some View {
        VStack(spacing: 0) {
            settingRow(title: "模型", value: modelValueLabel) { modelSection }
            rowSeparator
            settingRow(title: "校正", value: model.correctionEnabled ? "开" : "关") {
                correctionSection
            }
            rowSeparator
            settingRow(title: "输出语言", value: outputLanguageValueLabel) {
                outputLanguageSection
            }
            rowSeparator
            settingRow(title: "翻译后端", value: backendValueLabel) { backendSection }
        }
        .background(VITheme.contentBackground, in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    /// 「模型：…」那半截值。取值逻辑照搬旧 `MenuContent.modelMenuTitle`，
    /// 只去掉「模型：」前缀——前缀成了行标题。
    private var modelValueLabel: String {
        if let loading = model.loadingModelName {
            return "正在加载 \(loading)…"
        }
        return model.activeModelName
    }

    /// 输出语言那半截值。**必须走 `AppModel.outputLanguageMenuTitle`**：
    /// 「缺模型目录」那条括号后缀是它算出来的，自己拼语言名的话警示就没了，
    /// 而那时选中的语言根本没生效（见那个函数的注释）。
    ///
    /// 注释里不写那条后缀的原文：`MenuPanelViewWiringTests` 用整份源码
    /// `contains` 判「视图里没有手写它」，而 `contains` 看不出注释和代码的
    /// 区别——写进注释就等于把那条守卫废掉。
    private var outputLanguageValueLabel: String {
        stripPrefix(
            AppModel.outputLanguageMenuTitle(
                target: model.outputLanguage,
                modelMissing: model.translationModelMissing
            ),
            "输出语言："
        )
    }

    /// 翻译后端那半截值。同样走 `AppModel.translationBackendMenuTitle`：
    /// 四格四句话，「开了但不会生效」的两种状态全靠括号里那半句。
    private var backendValueLabel: String {
        stripPrefix(AppModel.translationBackendMenuTitle(model.translationBackend), "翻译后端：")
    }

    /// 去掉行标题已经说过的那截前缀。**只去前缀，不改后面一个字**——
    /// 「缺模型目录」「缺 API key，未生效」这类括号后缀必须原样留着。
    private func stripPrefix(_ text: String, _ prefix: String) -> String {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    /// 模型列表（旧 `modelMenu`）。
    @ViewBuilder
    private var modelSection: some View {
        ForEach(model.availableModels) { candidate in
            // 用前缀标记当前生效的模型（沿用旧菜单的文案，逐字未改）。
            expandedButton(
                candidate.name == model.activeModelName
                    ? "✓ \(candidate.name)"
                    : "   \(candidate.name)"
            ) {
                model.selectModel(candidate)
            }
            .disabled(!model.canSwitchModel)
        }

        if model.availableModels.isEmpty {
            infoLine("vendor/models 下没有模型")
        }

        Divider()
        expandedButton("其他目录…") {
            if let url = presentWhisperModelFolderPanel() {
                model.selectModelFromFolder(url.path)
            }
        }
        .disabled(!model.canSwitchModel)
    }

    /// 校正（旧 `correctionMenu`）：开关与模型目录是同一件事的两个面。
    @ViewBuilder
    private var correctionSection: some View {
        expandedButton(model.correctionEnabled ? "关闭校正" : "开启校正") {
            model.toggleCorrection()
        }

        Divider()
        // 让用户知道当前用的是哪个模型——校正效果好坏几乎全由它决定。
        // 未指定时不再说「默认（首次使用时下载）」：开启校正现在必须
        // 先有一个本地合法目录，那句话会让人以为不选也能用。
        infoLine(model.correctionModelName.map { "模型：\($0)" } ?? "模型：未指定（开启校正时选择）")
        expandedButton("指定校正模型…") {
            if let url = presentCorrectionModelFolderPanel() {
                model.selectCorrectionModel(directory: url)
            }
        }
    }

    /// 输出语言（旧 `outputLanguageMenu`）。
    ///
    /// 六种拉丁字母语种全列（用户 2026-08-19 的决定），但**每一项都带实测
    /// 质量**——第 0 步实测英文术语保留 1.00、西语 0.92、德语 0.89，葡/法/意
    /// 没测过。文案由 `TranslationTarget.menuLabel` 算出，不在视图里拼：
    /// 拼在这里就没有任何测试守得住它（与 `HUDViewModel` 同一条分工）。
    @ViewBuilder
    private var outputLanguageSection: some View {
        ForEach(TranslationTarget.allCases, id: \.rawValue) { target in
            expandedButton(target.menuLabel, checked: target == model.outputLanguage) {
                model.selectOutputLanguage(target)
            }
        }
    }

    /// 翻译后端（旧 `translationBackendMenu`）：**「谁来译」的一切都在这一格里**。
    ///
    /// 用户 2026-08-19 的要求：本机与云端放在同一处，点开二选一；
    /// 本机那侧是「指定模型」，云端那侧是「选哪个模型」加「API Key」。
    ///
    /// 两个后端的设置**互斥显示**，只出当前那一档的：另一档的模型/密钥
    /// 此刻不参与任何事，摆出来只会让人以为它也在起作用。
    ///
    /// 标题、开关文案、说明行全部由 `AppModel` 那三个纯函数算出，不在这里
    /// 拼字符串。而这里要守的恰恰是「面板说的和实际行为一致」：状态由协调器
    /// **真正算出来的挂载结论**推出，见 `AppModel.translationBackendStatus`。
    ///
    /// 面板本身**不读 Keychain**（可能弹系统授权框），只读镜像；
    /// 想立刻刷新的人自己按「重新检查 API key」。
    @ViewBuilder
    private var backendSection: some View {
        // ① 二选一。放最上面，因为这一格存在的理由就是它。
        expandedButton(
            AppModel.backendChoiceLabel(cloud: false),
            checked: model.translationBackend == .local
        ) {
            model.useLocalBackend()
        }
        expandedButton(
            AppModel.backendChoiceLabel(cloud: true),
            checked: model.translationBackend != .local
        ) {
            // 已经在云端时点它什么都不做，不再弹一次确认。
            guard model.translationBackend == .local else { return }
            model.toggleCloudBackend()
        }

        Divider()
        // ② 说明行随状态变：「开了但不会生效」的两种状态各自把话说完，
        // 否则用户只看到一个「开」，无从判断现在到底有没有东西在出站。
        ForEach(
            AppModel.translationBackendDetailLines(
                status: model.translationBackend,
                target: model.outputLanguage
            ),
            id: \.self
        ) { line in
            infoLine(line)
        }

        Divider()
        // ③ 当前那一档的设置。
        if model.translationBackend == .local {
            infoLine(
                AppModel.translationModelMenuLine(
                    name: model.translationModelName,
                    inherited: model.translationModelIsInherited
                )
            )
            expandedButton("指定模型…") {
                if let url = model.chooseTranslationModelFolder?() {
                    model.selectTranslationModel(directory: url)
                }
            }
            // 只在真的单独指过时出现：没指过时它什么都不做。
            if !model.translationModelIsInherited {
                expandedButton("改回跟随校正模型") { model.clearTranslationModel() }
            }
        } else {
            infoLine(AppModel.cloudModelMenuLine(model.cloudModel))
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(CloudTranslationModel.KnownModel.allCases, id: \.rawValue) { known in
                        expandedButton(
                            CloudTranslationModel.known(known).menuLabel,
                            checked: model.cloudModel == .known(known)
                        ) {
                            model.selectCloudModel(.known(known))
                        }
                    }
                    Divider()
                    // 上面那张表迟早过时（Google 改名、下线），
                    // 而用户不该为此等一次发版。
                    expandedButton("自定义…") { model.promptCloudModel() }
                }
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                HStack(spacing: 0) {
                    Text("选择模型").font(.system(size: 11.5))
                    Spacer(minLength: 0)
                }
            }
            .disclosureGroupStyle(PanelDisclosureStyle(horizontalPadding: 0, verticalPadding: 3))

            Divider()
            infoLine(AppModel.cloudAPIKeyMenuLine(hasKey: model.hasCloudAPIKey))
            expandedButton(model.hasCloudAPIKey ? "更换 API Key…" : "输入 API Key…") {
                model.enterCloudAPIKey()
            }
            if model.hasCloudAPIKey {
                expandedButton("删除 API Key") { model.removeCloudAPIKey() }
            }
            expandedButton("重新检查 API Key") { model.recheckCloudAPIKey() }
        }
    }

    // MARK: - 开发期工具

    /// 基准集录制（`VINPUT_BENCH=1`）与 BLE 扫描诊断（`VINPUT_BLE_SCAN=1`）。
    /// 两个门控各管各的按钮，理由分别见 `AppModel.benchEnabled` /
    /// `AppModel.bleScanEnabled`；默认两个都关，这一格整块不出现。
    @ViewBuilder
    private var devTools: some View {
        if AppModel.benchEnabled || AppModel.bleScanEnabled {
            VStack(spacing: 0) {
                settingRow(title: "开发工具", value: "") {
                    // 菜单里只留一个入口，全部录制界面在独立窗口
                    // （`BenchRecordingWindowController`）：说明文字的字号与颜色
                    // 都改不动，用户照着读了 23 条之后反馈「字太小、灰字看不清」。
                    if AppModel.benchEnabled {
                        expandedButton("开始录制基准集") { model.startBenchRecording() }
                    }
                    // 扫描在启动后自动开始（延后几秒让遥控器先连上），所以这里
                    // 只需要两个手动入口：
                    // - 「结束…并汇总」是**主入口**。合计行（哪个特征来了多少包）
                    //   只在收尾时才产生，用户按完键必须点它一下，日志里才有
                    //   第三个问题的答案。
                    // - 「重新开始」用于设备当时没醒、或要换一支设备再扫一轮——
                    //   不必退出应用重开。
                    if AppModel.bleScanEnabled {
                        expandedButton("结束 BLE 扫描并汇总") { model.stopBLEScan() }
                        expandedButton("重新开始 BLE 扫描") { model.startBLEScan() }
                    }
                }
            }
            .background(VITheme.contentBackground, in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack {
            Button("打开日志") {
                NSWorkspace.shared.selectFile(
                    AppLogger.shared.path, inFileViewerRootedAtPath: "")
            }
            Spacer()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.init(top: 8, leading: 14, bottom: 10, trailing: 14))
    }

    // MARK: - 行部件

    /// 设置一行：标题 + 琥珀橙当前值 + `›`（展开时转 90°），点整行展开。
    private func settingRow<Content: View>(
        title: String, value: String, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
        } label: {
            // 显式 HStack（而不是靠 ViewBuilder 的隐式 tuple 摊平）：
            // 里头那个 Spacer 要把「当前值」推到最右，而摊平后由谁来布局
            // 取决于外层样式的实现，写死一层最稳。
            HStack(spacing: 0) {
                Text(title).font(.system(size: 12))
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 11))
                    .foregroundStyle(VITheme.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .disclosureGroupStyle(PanelDisclosureStyle())
    }

    private var rowSeparator: some View {
        Rectangle().fill(VITheme.hairline).frame(height: 1).padding(.horizontal, 10)
    }

    /// 展开区里的一行按钮。样式统一在这里，**文案一律由调用方从 model 层取**。
    private func expandedButton(_ title: String, action: @escaping () -> Void) -> some View {
        expandedButton(title, checked: nil, action: action)
    }

    /// 带勾选标记的一行按钮（旧菜单里的 `Label(…, systemImage: "checkmark")`）。
    /// 未选中时勾照样占位再隐藏，免得选中与否会让文字左右跳。
    private func expandedButton(
        _ title: String, checked: Bool?, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(VITheme.accent)
                        .opacity(checked ? 1 : 0)
                }
                Text(title).font(.system(size: 11.5))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 展开区里的说明文字（旧菜单里那些不可点的 `Text`）。
    private func infoLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 面板里的展开样式：整行可点，`›` 展开时转 90°。
///
/// 自定义而不用系统默认：默认的三角在**左**侧，会把「标题 + 右侧当前值」
/// 这条排版顶掉一格，四行对不齐。
struct PanelDisclosureStyle: DisclosureGroupStyle {
    var horizontalPadding: CGFloat = 10
    var verticalPadding: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    configuration.label
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if configuration.isExpanded {
                configuration.content
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, verticalPadding)
            }
        }
    }
}

/// 归一化 VMark 几何 → SwiftUI Shape（面板头部用；菜单栏走 NSImage）。
struct VMarkShape: Shape {
    let bars: [CGRect]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // 缩放走 VMark.rects(_:in:)，不各写一遍（Task 1 QA 复核后泛化的初衷）。
        for r in VMark.rects(bars, in: rect) {
            path.addRoundedRect(in: r, cornerSize: CGSize(width: r.width / 2, height: r.width / 2))
        }
        return path
    }
}
