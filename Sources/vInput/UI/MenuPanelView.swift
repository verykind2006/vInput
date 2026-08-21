import AppKit
import SwiftUI

/// 菜单栏面板（`MenuBarExtra` `.window` 样式的内容视图）。
///
/// 布局与视觉见设计定稿 ②；**一切文案与动作复用 model 层现有函数，零增减**
/// ——旧 `MenuContent` 里的每一个按钮、每一条禁用条件、每一道环境变量门控
/// 都在这里有对应的一项（迁移对照清单在 Task 7 的提交信息里）。
///
/// ## 哪些文案在这里，哪些不在
///
/// **凡是随状态变的文案，一律在 model 层**（`MenuPanelModel` 的
/// `primaryButtonTitle` / `retryTitle` / `correctionToggleTitle` /
/// `correctionModelLine` / `apiKeyButtonTitle`，以及 `AppModel` 那一串
/// `…MenuTitle` / `…MenuLine` / `…Label`）。理由不是洁癖：迁移时「重试上次
/// 转写（没有可重试的）」在视图里被改成纯置灰的「重试 ↻」，禁用理由整句
/// 丢失而全仓测试一条没红（`1a0989b` 才补回来）——两句话的文案留在视图里，
/// 没有任何东西守得住它。
///
/// **不随状态变的固定标签仍然写在这里**，约二十处：设置四行的行标题
/// （「模型」「校正」「输出语言」「翻译后端」「开发工具」）、头部的
/// 「vInput」、卡片标题「上次转写」、快捷键徽章「⌥D」，以及一批一次性的
/// 按钮字面量（「其他目录…」「指定校正模型…」「指定模型…」「改回跟随校正
/// 模型」「选择模型」「自定义…」「删除 API Key」「重新检查 API Key」
/// 「开始录制基准集」「结束 BLE 扫描并汇总」「重新开始 BLE 扫描」
/// 「打开日志」「退出」）与空列表提示「vendor/models 下没有模型」。
/// 它们只有一种取值，改动只会来自「有人主动改文案」，不会来自漏掉一个分支。
///
/// 设置四行的行标题是旧菜单标题里那半截前缀搬了个位置——值那侧因此去掉
/// 重复的前缀，见 `stripPrefix`。
struct MenuPanelView: View {
    let model: AppModel

    /// 磁盘上存不存在。抽成一处是为了「显示位置」与「在访达中显示」用的是
    /// 同一个判据——两处各写一遍的话，会出现「说还没建、却又能打开」。
    static let pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    /// 初始展开哪一行。**只为量高度而存在。**
    ///
    /// 面板高度是这一批唯一会真正伤到人的排版指标（`.window` 面板不滚动，
    /// 13 寸屏够不到底部），而「哪一行展开」是 `@State`，测试进程里点不动。
    /// 有了这个参数，`MenuPanelLayoutTests` 才能把每一档都摆出来真量一遍，
    /// 而不是在注释里写一个估算值——R-3 那次就是靠实测才发现旧估算偏了 50pt。
    ///
    /// 生产调用方（`vInputApp`）不传它，行为与原来一字不差。
    init(model: AppModel, initiallyOpen: SettingRow? = nil) {
        self.model = model
        _openRow = State(initialValue: initiallyOpen)
    }

    /// 手风琴：一次只展开一行。
    ///
    /// **`.window` 面板不滚动**，超出屏幕的部分够不到，而四行同时展开
    /// （云端档还嵌一层「选择模型」）实测能堆到 900–1000pt，13 寸的可用
    /// 高度约 850pt。旧的原生菜单天然一次只开一个子菜单，这里把那条行为
    /// 补回来，顺带解决「展开第四行把前三行顶出屏幕」。
    ///
    /// R-3 把字号整体调大一档之后重新量过（离屏渲染，最深的那一档：云端
    /// 后端展开 + 嵌套的「选择模型」也展开 + 设备卡 + 上次转写）：旧尺寸
    /// 666pt，新尺寸 719pt，离 850 还有 131pt。**手风琴仍然是这条余量的
    /// 唯一来源**——去掉它，四行一起开就回到 900pt 以上。
    @State private var openRow: SettingRow?

    /// 可展开的行。用枚举而不是四个 Bool：四个 Bool 表示得出「同时开三行」
    /// 这种非法状态，而这里要的恰恰是「至多一行」。
    ///
    /// internal 而不是 private：`init(model:initiallyOpen:)` 要拿它当参数
    /// （量高度用，见那边的注释）。
    enum SettingRow: Hashable {
        case model, correction, outputLanguage, backend, advanced, devTools
    }

    /// 面板宽度。
    ///
    /// **300 → 320（R-3，2026-08-21）**：字号整体调大一档后，最长的那几行
    /// 设置值在 300 里只剩十几点余量（实测最长的「翻译后端：云端（缺 API
    /// key，未生效）」在 13/12pt 下要 259pt，300 宽可用 276pt），而设备卡的
    /// 说明行会折成两行、两张卡一高一低。320 把余量拉回 37pt，设备卡回到
    /// 单行。这是这批唯一改变面板比例的地方，请用户过目。
    ///
    /// 高度不受影响的证据：离屏渲染实测，最深一档（云端后端展开 + 嵌套的
    /// 「选择模型」也展开 + 设备卡 + 上次转写）旧版 666pt、新版 719pt，
    /// 13 寸屏可用高度约 850pt，仍有 131pt 余量。
    static let panelWidth: CGFloat = 320

    /// 头部与底栏的左右留白。
    ///
    /// **14 → 20（R-2，2026-08-21 用户真机实测「底栏两个按钮显示不全」）**。
    ///
    /// 不是宽度不够：离屏实测底栏在 300 宽里只要 102pt，横向余量将近 200pt，
    /// 300 宽下渲染出来的「打开日志」「退出」一个像素都没少。真正的区别是
    /// **离边有多近**——面板里别的东西都在卡片里（卡片外边距 12 + 卡内边距
    /// 8 = 文字离面板边至少 20pt），只有头部和底栏是直接贴着 14pt 写的。
    /// 宿主窗口的圆角、材质边、以及 `MenuBarExtra` 自己给内容加的那层内缩，
    /// 吃掉的都是最外面这几点，于是**整块面板里只有底栏会被啃掉一角**。
    /// 把这两处推到 20pt，整块面板里再没有任何文字比卡片内的文字更靠边。
    static let edgeGutter: CGFloat = 20

    /// 面板的字号表（R-3：用户「字体稍微放大一些，目前太小了」）。
    ///
    /// **集中成一张表，而不是散在各处写字面量**，理由有二：
    ///
    /// - 「放大但保持层级」这件事，只有在能一眼看见全部档位时才谈得上。
    ///   之前是 10 / 10.5 / 11 / 11.5 / 12 / 13 六档散在十几处，改一处
    ///   很容易把层级压平。
    /// - 视图里的字面量没有任何测试守得住，而这一批恰恰是用户点名要改的。
    ///   写成常量之后 `MenuPanelLayoutTests` 才能直接断言「头部 ≥ 正文 ≥
    ///   次要」，不必去扫源码。
    ///
    /// 基准是系统菜单的 13pt：正文档就是它，比它小的都是次要信息。
    enum TypeScale {
        /// 头部「vInput」与主按钮标题。整块面板里最大的两处。
        static let header: CGFloat = 14
        /// 正文：设置行标题、展开区的每一项、上次转写正文、底栏、设备卡标题。
        static let body: CGFloat = 13
        /// 次要：设置行的当前值、说明行、头部状态、⌥D 徽章。
        static let secondary: CGFloat = 12
        /// 更次一级：「上次转写」这个小标题与它旁边的「重试」。
        static let detail: CGFloat = 11.5
        /// 设备卡的说明行（等宽字）。两张卡并排，每张只有约 118pt 放字，
        /// 跟到 11.5 会折行、两张卡一高一低（离屏渲染实测）。
        static let cardDetail: CGFloat = 11
        /// ✓ 与 › 两个 SF Symbol 的字号。**不是文字**，不参与上面的层级。
        static let glyph: CGFloat = 10
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            primaryButton
            downloadStatus
            deviceCards
            lastTranscriptCard
            settingsList
            devTools
            footer
        }
        .frame(width: Self.panelWidth)
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
                .frame(width: 16, height: 16)
            Text("vInput").font(.system(size: TypeScale.header, weight: .semibold))
            Spacer()
            Circle().fill(toneColor(status.tone)).frame(width: 6, height: 6)
            Text(status.text)
                .font(.system(size: TypeScale.secondary))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(
            .init(
                top: 12, leading: Self.edgeGutter, bottom: 10, trailing: Self.edgeGutter))
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

    /// 主按钮。**先关面板、把焦点还给原应用，下一个 runloop turn 再开听写。**
    ///
    /// 顺序不能反，也不能省：`TargetAppGuard.capture()` 在会话开始的那一刻
    /// 记下前台应用，而面板开着的时候前台是 vInput 自己——同一轮里紧接着
    /// `toggle()` 的话，记下的目标就是这个面板，转写出来的文字会被注进面板
    /// 里（等于消失）；用户随后点别处关面板，则前台一变，注入前的 `verify`
    /// 抛 `targetApplicationChanged`，用户看到「焦点已切到别的应用，文字没有
    /// 输入」。旧的原生菜单点一下自己就关了，从来不会撞上这件事，
    /// 换成 `.window` 之后必须自己补（详见 `dismissMenuPanel`）。
    ///
    /// 只有这个按钮需要：几个弹窗自己会 `activate`，「打开日志」交给 Finder。
    private var primaryButton: some View {
        Button {
            dismissMenuPanel()
            // 焦点交还是异步的，同一轮里 capture() 拿到的还是 vInput 自己。
            DispatchQueue.main.async { model.toggle() }
        } label: {
            HStack {
                Text(MenuPanelModel.primaryButtonTitle(phase: model.phase))
                    .font(.system(size: TypeScale.header, weight: .semibold))
                Spacer()
                // 内边距 h6/v1 → h7/v3、圆角 4 → 5：离屏渲染实测，旧尺寸下
                // 那块底片紧贴字形外框，⌥（U+2325，比等宽字体的其他字形高）
                // 上下都顶到边，看上去像被裁了。字号调大只会更挤，一起放宽。
                Text("⌥D")
                    .font(.system(size: TypeScale.secondary, design: .monospaced))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
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
        // 自绘的渐变底 + .plain 样式**不会**跟着 isEnabled 变灰：不自己压暗
        // 的话，模型加载那一两分钟里用户看到的是一个鲜亮如常的「开始听写」，
        // 点下去毫无反应——与「重试」纯置灰丢掉理由是同一类缺陷。
        .opacity(model.loadingModelName != nil ? 0.45 : 1)
        .saturation(model.loadingModelName != nil ? 0 : 1)
        .disabled(model.loadingModelName != nil)
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    // MARK: - 在飞的下载

    /// 「正在下载模型 42%」与「新模型已下载好，这次听写结束后自动启用」。
    ///
    /// **这一格补的是一个看不见的后台任务。** 关掉向导不取消下载（扔掉几百
    /// MB 更糟），而菜单栏图标的 `loadingModel` 说的是「模型正在加载」，
    /// 不是「正在下载」——两者差着十几分钟。没有这一格的话，用户关掉向导之后
    /// 看到的是一个若无其事的面板，直到某一刻应用忽然自己进入加载态。
    ///
    /// 摆在主按钮下面、设备卡上面：它是「此刻应用在替你做的事」，
    /// 比设备状态紧要，但不该把主按钮往下推。
    ///
    /// 两行都可能同时出现（下完一个正在下一个不会发生，但「上一次下的还等着
    /// 启用」＋「这次又在下」在重试路径上会）。文案全部在 `MenuPanelModel`。
    @ViewBuilder
    private var downloadStatus: some View {
        let lines = [
            MenuPanelModel.downloadLine(progress: model.downloadingModelProgress),
            MenuPanelModel.pendingModelLine(folder: model.pendingModelFolder),
        ].compactMap { $0 }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(lines, id: \.self) { line in infoLine(line) }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VITheme.contentBackground, in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
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
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(card.title).font(.system(size: TypeScale.body))
                            // 说明行只跟到 11pt（正文是 13）：两张卡并排，每张
                            // 只有约 118pt 放字。离屏实测 11.5pt 时「未连接，
                            // 长按侧键唤醒」会折成两行、两张卡一高一低；11pt
                            // 回到单行。
                            Text(card.detail)
                                .font(.system(size: TypeScale.cardDetail, design: .monospaced))
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
                    Text("上次转写").font(.system(size: TypeScale.detail)).foregroundStyle(.secondary)
                    Spacer()
                    // 转写失败时音频保留着，此前却点不到（Transcriber.swift:17：全仓
                    // 只有测试在调 retry()）。禁用而不是隐藏：入口时有时无的话，
                    // 用户根本不会知道存在这么个东西，也就等不到需要它的那一刻。
                    //
                    // 禁用时把「为什么点不动」写在文案里。两句话都在
                    // `MenuPanelModel.retryTitle`——正是这一处曾经在视图里被
                    // 改成纯置灰的单句，全仓测试一条没红。
                    Button(MenuPanelModel.retryTitle(canRetry: model.canRetry)) {
                        model.retryLastTranscription()
                    }
                        .buttonStyle(.plain)
                        .font(.system(size: TypeScale.detail))
                        .foregroundStyle(model.canRetry ? VITheme.accent : Color.secondary)
                        .disabled(!model.canRetry)
                }
                Text(model.lastText.prefix(60))
                    .font(.system(size: TypeScale.body))
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
            settingRow(.model, title: "模型", value: modelValueLabel) { modelSection }
            rowSeparator
            settingRow(.correction, title: "校正", value: model.correctionEnabled ? "开" : "关") {
                correctionSection
            }
            rowSeparator
            settingRow(.outputLanguage, title: "输出语言", value: outputLanguageValueLabel) {
                outputLanguageSection
            }
            rowSeparator
            settingRow(.backend, title: "翻译后端", value: backendValueLabel) { backendSection }
            rowSeparator
            // 第五行。**高度是量出来的，不是估的**（`MenuPanelHeightTests`，
            // 2026-08-22 离屏 `fittingSize` 实测）：
            //
            //     收起 310 / 模型 363 / 校正 339 / 输出语言 459
            //     翻译后端（本机）476 / **高级 511**
            //
            // 也就是说本批把「最深一档」从 476 抬到了 511——多的不只是一个
            // 行高：高级展开有 11 行（3 条说明 + 6 个按钮 + 3 条分隔线）。
            // 再叠上本批新增的两行在飞状态（+74pt）是 585pt，那是测试进程里
            // 能摆出来的最坏情形。
            //
            // 摆不出来、只能在真机上叠加的还有四样（设备卡、上次转写、
            // 模型列表条目、云端后端展开+嵌套「选择模型」）。按 R-3 实测的
            // 719pt（那一档含云端嵌套+设备卡+上次转写）推算，最坏组合约
            // 719 + 35（多这一行收起态）+ 74（两行在飞状态）≈ 828pt，
            // 而 13 寸可用约 850pt——**只剩约 22pt**。Task 9 真机目检要核的
            // 就是这个数字；再往面板里加东西之前先重量一次。
            settingRow(.advanced, title: "高级", value: "") { advancedSection }
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

    /// 校正（旧 `correctionMenu`）：这一格现在只剩开关。
    ///
    /// **「指定校正模型…」连同它上面那行「模型：…」搬去了「高级」**：
    /// 开关是天天会点的，而挑一个本地 MLX 模型目录一个用户一辈子做一两次。
    /// 两项没有拆成两处（模型行留这里、按钮搬走）——那行字存在的理由就是
    /// 「按下按钮之前先知道现在用的是哪个」，拆开之后两边都不完整，
    /// 而重复写一份迟早各走各的。
    @ViewBuilder
    private var correctionSection: some View {
        expandedButton(MenuPanelModel.correctionToggleTitle(enabled: model.correctionEnabled)) {
            model.toggleCorrection()
        }
    }

    /// 高级：储存位置、下载源、校正模型目录、卸载。
    ///
    /// 这一格的共同点是「一辈子点一两次，点错代价大」。**卸载排在最后且是
    /// 红字**：它删的是几个 GB 加全部设置加 Keychain 里的 API key，不可撤销。
    /// 它必须待在这个折叠区里而不是主区域——主区域的每一项都是天天点的，
    /// 一个「删掉一切」摆在它们中间迟早会被误点（`MenuPanelViewWiringTests`
    /// 单独钉了这一条）。
    @ViewBuilder
    private var advancedSection: some View {
        // ① 储存位置。**这是好奇的用户唯一能看见「那几个 GB 在哪」的地方**，
        // 也是卸载入口存在的同一条产品义务的另一半：我们把几个 GB 塞进了
        // 用户不感知的目录，就有义务让他看得见、也删得掉。
        infoLine(
            MenuPanelModel.storageLocationLine(
                root: model.modelRootPath, exists: Self.pathExists))
        expandedButton("在访达中显示") {
            // 目录还不存在时退到最近一个存在的祖先：Finder 拿到不存在的路径
            // 是**静默无反应**的，而首次下载之前这就是常态。
            guard
                let target = MenuPanelModel.revealTarget(
                    root: model.modelRootPath, exists: Self.pathExists)
            else { return }
            NSWorkspace.shared.selectFile(target, inFileViewerRootedAtPath: "")
        }

        Divider()
        // ② 下载源。默认自动（并发探测，谁快用谁）；这里是「探测选错了」的
        // 逃生口。写进偏好的那个 key 与向导读的是同一个（都经由
        // `DownloadSourcePreference`），否则这个开关会静默地什么都不做。
        infoLine("下载源")
        downloadSourceChoice(nil)
        downloadSourceChoice(.official)
        downloadSourceChoice(.mirror)

        Divider()
        // ③ 校正模型目录（从「校正」那一格搬过来，逐字未改）。
        infoLine(MenuPanelModel.correctionModelLine(name: model.correctionModelName))
        expandedButton("指定校正模型…") {
            if let url = presentCorrectionModelFolderPanel() {
                model.selectCorrectionModel(directory: url)
            }
        }

        Divider()
        // ④ 卸载。红字、最后一项。确认框、体积、真删除全都不在视图里：
        // 文案来自 `UninstallPlan.confirmation`，流程在 `runUninstallFlow`
        // （取消是默认按钮，理由见 `presentUninstallConfirmation`）。
        destructiveButton("卸载 vInput 的数据…") {
            Task { await runUninstallFlow() }
        }
    }

    /// 下载源三选一里的一项。nil 是「自动」。
    private func downloadSourceChoice(_ source: DownloadSource?) -> some View {
        expandedButton(
            MenuPanelModel.downloadSourceChoiceLabel(source),
            checked: model.forcedDownloadSource == source
        ) {
            model.selectDownloadSource(source)
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
            // 幂等：已经在云端时这一下什么都不做，也不弹确认。守卫在
            // `AppModel.cloudBackendRequest` 里（视图里的 guard 没有测试
            // 进得去，而这一档点错的后果是把出站开关悄悄关掉）。
            model.useCloudBackend()
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
                    Text("选择模型").font(.system(size: TypeScale.body))
                    Spacer(minLength: 0)
                }
            }
            // verticalPadding 3 → 4：跟着 R-3 的字号一起长（这一格的标题从
            // 11.5 到了 13），否则「选择模型」和它上下两行几乎贴在一起。
            .disclosureGroupStyle(PanelDisclosureStyle(horizontalPadding: 0, verticalPadding: 4))

            Divider()
            infoLine(AppModel.cloudAPIKeyMenuLine(hasKey: model.hasCloudAPIKey))
            expandedButton(MenuPanelModel.apiKeyButtonTitle(hasKey: model.hasCloudAPIKey)) {
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
                settingRow(.devTools, title: "开发工具", value: "") {
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

    /// 底栏（R-2：用户真机实测这两个按钮「显示不全」）。
    ///
    /// 三处改动，各自对应一个已排除或已确认的原因：
    ///
    /// - **左右留白 14 → `edgeGutter`(20)**。这是主因，理由整段写在
    ///   `edgeGutter` 上：横向宽度从来就不缺（离屏实测底栏只要 102pt，
    ///   300 宽里余量近 200pt），缺的是「离面板边缘的距离」——底栏是整块
    ///   面板里唯一贴着边写的文字。
    /// - **字号 11 → 13**（R-3 的一部分）。11pt 的次要灰字压在 #1D1D1F 上
    ///   本来就临界，被啃掉一角之后更像是「没画完」。
    /// - **每个按钮各自 `.lineLimit(1).fixedSize()`**。两个标签都是定长
    ///   文案，宁可把面板顶宽，也不许被截断成半个字——「显示不全」这四个字
    ///   最坏的一种成因就是无声的截断，而截断在源码扫描测试里看不见。
    ///   `fixedSize` 只能加在两个按钮上、不能加在外层 `HStack` 上：加在外层
    ///   会连 `Spacer` 一起按理想宽度（0）算，整条底栏缩成一团居中，
    ///   「一左一右」当场没了。
    private var footer: some View {
        HStack {
            Button("打开日志") {
                NSWorkspace.shared.selectFile(
                    AppLogger.shared.path, inFileViewerRootedAtPath: "")
            }
            .lineLimit(1)
            .fixedSize()
            Spacer(minLength: 12)
            Button("退出") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .font(.system(size: TypeScale.body))
        .foregroundStyle(.secondary)
        .padding(
            .init(
                top: 10, leading: Self.edgeGutter, bottom: 12, trailing: Self.edgeGutter))
    }

    // MARK: - 行部件

    /// 设置一行：标题 + 琥珀橙当前值 + `›`（展开时转 90°），点整行展开。
    ///
    /// 展开状态**由 `openRow` 单独持有**，不用 `DisclosureGroup` 自带的内部
    /// 状态：手风琴要的是「开这一行 = 关掉另外三行」，那必须有一个共同的
    /// 真相源（理由见 `openRow`）。
    private func settingRow<Content: View>(
        _ row: SettingRow, title: String, value: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { openRow == row },
                set: { openRow = $0 ? row : nil }
            )
        ) {
            VStack(alignment: .leading, spacing: 4) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
        } label: {
            // 显式 HStack（而不是靠 ViewBuilder 的隐式 tuple 摊平）：
            // 里头那个 Spacer 要把「当前值」推到最右，而摊平后由谁来布局
            // 取决于外层样式的实现，写死一层最稳。
            HStack(spacing: 0) {
                Text(title).font(.system(size: TypeScale.body))
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: TypeScale.secondary))
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
                        .font(.system(size: TypeScale.glyph, weight: .bold))
                        .foregroundStyle(VITheme.accent)
                        .opacity(checked ? 1 : 0)
                }
                Text(title).font(.system(size: TypeScale.body))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 展开区里那种「点下去会毁掉东西」的按钮。目前只有卸载一项。
    ///
    /// 红字不是装饰：这一行删的是几个 GB、全部设置和 Keychain 里的 API key，
    /// 而它周围全是无害的设置项。颜色是用户在**点之前**唯一能收到的警告
    /// （确认框是点之后的第二道）。
    private func destructiveButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: TypeScale.body)).foregroundStyle(.red)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 展开区里的说明文字（旧菜单里那些不可点的 `Text`）。
    private func infoLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: TypeScale.secondary))
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
    /// 8 → 9：行高要跟着 R-3 的字号一起长，否则 13pt 的行标题贴着分隔线。
    var verticalPadding: CGFloat = 9

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    configuration.label
                    Image(systemName: "chevron.right")
                        .font(.system(size: MenuPanelView.TypeScale.glyph, weight: .semibold))
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
