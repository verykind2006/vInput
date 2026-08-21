import Foundation
import Testing

@testable import vInput

/// 菜单面板（`MenuPanelView`）与场景（`vInputApp`）的接线不变量，用**扫源码**
/// 的方式钉住。
///
/// # 为什么是扫源码
///
/// 这一批是视图。视图在这个仓库里跑不起来（`AppModel` 在 `init` 里就要真
/// 麦克风、真快捷键、真 CGEvent tap，`MenuBarExtra` 更是要一个真 App 生命
/// 周期），SwiftUI 的 body 也没有可断言的输出。能自动化的只剩两件事：
///
/// - **防删除**：旧 `MenuContent` 的每一个动作入口在迁移后还在不在。
///   M9 Task 7 是一次性搬走十几个菜单项的迁移，漏一个的表现是「某个功能
///   从此点不到了」，而全仓测试一条都不会红。
/// - **防就地拼文案**：面板里每一句随状态变的话都必须来自 model 层那些被
///   测试钉着的纯函数。拼在视图里就没有任何测试守得住它——「重试」的禁用
///   文案就是这么丢的（`1a0989b`）。
///
/// 扫源码证明不了「它长得对」，那部分在 Task 9 的真机目检清单上。
///
/// # 断言一律先算成 Bool
///
/// 不要把整份源码交给 `#expect`：那样一旦红了，失败输出里会原样打出这 550
/// 行文件（实测一次失败 484 行输出，`✘` 在第 26 行、自定义信息在第 405 行），
/// 变异验证时「没红」和「红了但找不到」就分不开了。规矩来自
/// `CloudBackendMenuTests` 里那段注释，循环断言尤其要守——一次能吐好几份。
@Suite("菜单面板接线不变量")
struct MenuPanelViewWiringTests {
    static func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // vInputTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
        return try String(
            contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    static func panelSource() throws -> String {
        try source("Sources/vInput/UI/MenuPanelView.swift")
    }

    /// 扫源码前先把 `//` 行注释去掉。
    ///
    /// 这一条是写 `ForegroundHandoffTests` 时当场撞上的：`ModalPanels.swift`
    /// 的注释里必须写清「原来用的是 NSApp 的 hide、为什么不能再用」，而整份
    /// `contains` 分不清注释和代码——把历史写进注释就等于让守卫永远红着。
    /// 反过来（为了让测试绿而不敢在注释里提它）更糟：下一个人不知道这条路
    /// 走过。本文件里那些老断言不走这里，它们钉的是**必须存在**的调用，
    /// 注释里多提一句只会让它更容易绿，不会漏判。
    ///
    /// 只处理行注释，不处理块注释与字符串里的 `//`：被扫的这几份文件里没有
    /// 那两种形态，多写的解析反而更容易出错。
    static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else { return line }
                return line[line.startIndex..<slashes.lowerBound]
            }
            .joined(separator: "\n")
    }

    static func appSource() throws -> String {
        try source("Sources/vInput/App/vInputApp.swift")
    }

    // MARK: - 场景：自绘面板取代原生菜单

    /// `.window` 样式是整个 M9 面板的前提：不切的话 `MenuPanelView` 会被塞进
    /// 原生菜单里渲染，自绘的按钮、渐变、展开行全部失效或不可点。
    @Test("MenuBarExtra 用 .window 样式")
    func menuBarExtraUsesWindowStyle() throws {
        let source = try Self.appSource()
        let usesWindowStyle = source.contains(".menuBarExtraStyle(.window)")
        #expect(
            usesWindowStyle,
            """
            vInputApp 的 MenuBarExtra 没有 .menuBarExtraStyle(.window)。
            默认样式会把 MenuPanelView 当原生菜单项渲染——自绘面板的按钮、
            渐变主按钮、面板内展开行全部失效。
            """
        )
        let usesPanel = source.contains("MenuPanelView(model: delegate.model)")
        #expect(usesPanel, "MenuBarExtra 的内容不是 MenuPanelView。")
    }

    /// 旧的原生菜单必须真的删掉，而不是留在文件里没人引用。
    ///
    /// 留着的话它会继续被编译、被后来的人误改，而两份菜单的文案与禁用条件
    /// 从此各走各的——本仓库在 `attachTranslation` 上栽过同一个坑。
    @Test("旧的 MenuContent 已从 vInputApp 删除")
    func oldMenuContentIsGone() throws {
        let source = try Self.appSource()
        let hasMenuContent = source.contains("MenuContent")
        #expect(
            !hasMenuContent,
            "vInputApp.swift 里还有 MenuContent。迁移到 MenuPanelView 后它必须整块删掉。"
        )
        // 图标只有 StatusIcon 一条路径：旧 iconName 的 SF Symbol 与
        // StatusIcon 的五档映射并存的话，两处迟早对同一个状态说两套话。
        let hasSFSymbolIcon = source.contains("Image(systemName:")
        #expect(
            !hasSFSymbolIcon,
            "vInputApp.swift 里还在用 SF Symbol 当菜单栏图标，图标只能走 StatusIcon。"
        )
        let usesStatusIcon = source.contains("StatusIcon.image(for: StatusIcon.state(")
        #expect(usesStatusIcon, "菜单栏 label 没有走 StatusIcon.image(for: StatusIcon.state(...))。")
    }

    // MARK: - 点主按钮之前必须先把焦点还回去

    /// **面板要先关，听写才能开。**
    ///
    /// 旧的原生菜单点一下自己就关了、前台应用从来没变过，这个行为是免费的；
    /// `.window` 面板点完还开着，而 `TargetAppGuard.capture()` 在会话开始的
    /// 那一刻记下前台应用。不关的两种坏结果：前台是 vInput 自己 → 文字被注进
    /// 面板（等于消失）；用户点别处关面板 → 前台变了 → 注入前 `verify` 抛
    /// `targetApplicationChanged`，用户看到「焦点已切到别的应用，文字没有输入」。
    ///
    /// 这正是以后重构会顺手删掉的那种行（「点个按钮为什么还要先关一下面板？」），
    /// 所以单独钉一条，并且连 `DispatchQueue.main.async` 一起钉：同一轮里
    /// 紧接着 `toggle()` 的话，焦点还没交还，`capture()` 拿到的仍是 vInput。
    ///
    /// **钉的是行为，不是机制的名字。** 「关面板 + 让位」这一步具体怎么实现
    /// 换过一次（`NSApp.hide(nil)` → 显式激活原前台应用，R-1），换的理由是
    /// `hide` 会连菜单栏状态项一起藏掉。这里只管「开听写之前先走过那一步」；
    /// 那一步内部不许再藏整个应用，由 `ForegroundHandoffTests` 单独钉。
    @Test("主按钮先关面板让位再开听写")
    func primaryButtonDismissesPanelBeforeToggling() throws {
        let source = try Self.panelSource()
        let dismisses = source.contains("dismissMenuPanel()")
        #expect(
            dismisses,
            """
            MenuPanelView 里没有 dismissMenuPanel()。
            .window 面板不会自己关、也不会自己把前台让出去：面板开着时前台是
            vInput 自己，TargetAppGuard 记下的目标就是这个面板，转写出来的
            文字会注进面板里。
            """
        )
        let deferred = source.contains("DispatchQueue.main.async { model.toggle() }")
        #expect(
            deferred,
            """
            model.toggle() 没有推到下一个 runloop turn。
            焦点交还是异步的——同一轮里 capture() 拿到的还是 vInput 自己，
            关不关面板都一样错。
            """
        )
        guard let dismissRange = source.range(of: "dismissMenuPanel()"),
            let toggleRange = source.range(of: "DispatchQueue.main.async { model.toggle() }")
        else { return }
        #expect(
            dismissRange.lowerBound < toggleRange.lowerBound,
            "先 toggle 再关面板：焦点还没还回去，会话已经开始了。")
    }

    // MARK: - 深色面板

    /// 面板底色是写死的深色，文字颜色必须一起钉死。
    ///
    /// `.primary` / `.secondary` 跟系统外观走：浅色模式下删掉这一行，整块面板
    /// 就是黑字压 #1D1D1F 深底，几乎读不出来——而开发机常年深色模式，
    /// 这种缺陷在自己机器上永远看不见。
    @Test("面板把配色方案钉死成深色")
    func panelForcesDarkColorScheme() throws {
        let source = try Self.panelSource()
        let forcesDark = source.contains(#".environment(\.colorScheme, .dark)"#)
        #expect(
            forcesDark,
            """
            MenuPanelView 没有 .environment(\\.colorScheme, .dark)。
            面板底色写死 #1D1D1F，而 .primary/.secondary 跟系统外观走——
            浅色模式下正文会变成黑字压深底。
            """
        )
    }

    /// 设置各行必须是手风琴（一次只开一行）。
    ///
    /// 理由与上一条同源，都是「开发机上看不见的缺陷」：`.window` 面板不滚动，
    /// 超出屏幕的部分够不到。四行各自独立展开时，最坏情况（云端档 + 嵌套的
    /// 「选择模型」+ 设备卡 + 上次转写卡）约 900–1000pt，13 寸屏到顶约 850pt
    /// ——而作者的屏幕大，怎么点都不会撞到。旧的原生菜单天然一次只开一个
    /// 子菜单，这是在把那个行为补回来。
    ///
    /// 钉两处：单值状态（`SettingRow?` 让「同时开三行」在类型上就表示不出来）
    /// 与显式绑定（改回各自独立的 `DisclosureGroup` 会让这条红）。
    @Test("设置各行是手风琴，一次只开一行")
    func settingsRowsAreAccordion() throws {
        let source = try Self.panelSource()

        let hasSingleOpenState = source.contains("@State private var openRow: SettingRow?")
        #expect(
            hasSingleOpenState,
            """
            MenuPanelView 里找不到 `@State private var openRow: SettingRow?`。
            四行设置若各自独立展开，最坏情况约 900–1000pt，13 寸屏够不到底部
            （面板不滚动）。单值状态让「同时开多行」在类型上就表示不出来。
            """
        )

        let hasExplicitBinding = source.contains("isExpanded: Binding(")
        #expect(
            hasExplicitBinding,
            """
            设置行不再用显式 isExpanded 绑定——多半是改回了各自持有状态的
            DisclosureGroup，手风琴行为会一起丢掉。
            """
        )
    }

    // MARK: - 文案一律来自 model 层

    /// 面板里不许出现任何就地拼的面向用户的警示文案。
    ///
    /// 「（缺模型目录）」是 `AppModel.outputLanguageMenuTitle` 算出来的后缀：
    /// 缺目录时选中的语言**根本没生效**，只印语言名的话面板恰好在骗人。
    /// 它一旦被抄进视图，`AppModel` 那边改措辞、改判据都不会同步过来。
    @Test("输出语言那行的文案走 AppModel.outputLanguageMenuTitle")
    func outputLanguageCopyComesFromModelLayer() throws {
        let source = try Self.panelSource()
        let usesTitle = source.contains("AppModel.outputLanguageMenuTitle(")
        #expect(
            usesTitle,
            """
            MenuPanelView 没有调用 AppModel.outputLanguageMenuTitle。
            自己拼语言名的话「缺模型目录」这条警示就没了，
            而那时用户看到「输出语言：西班牙文」，得到的却是中文。
            """
        )
        let handWritesSuffix = source.contains("（缺模型目录）")
        #expect(
            !handWritesSuffix,
            "MenuPanelView 里出现了手写的缺目录后缀——它只能由 AppModel 算出。"
        )
        let usesTargetLabel = source.contains("target.menuLabel")
        #expect(
            usesTargetLabel,
            "六个输出语言选项的文案没有走 TranslationTarget.menuLabel（每项都带实测质量）。"
        )
    }

    /// 随状态变的五处文案必须走 `MenuPanelModel`。
    ///
    /// 这条是那次真事故的守卫：迁移时「重试上次转写（没有可重试的）」在视图
    /// 里被写成纯置灰的单句「重试 ↻」，禁用理由整句丢失，而全仓 1121 条测试
    /// 一条都没红（`1a0989b` 才补回来）。两句话的文案只要留在视图里，就没有
    /// 任何东西守得住其中一句被删掉。
    @Test("随状态变的文案全部走 MenuPanelModel")
    func statefulCopyComesFromMenuPanelModel() throws {
        let source = try Self.panelSource()
        for call in [
            "MenuPanelModel.primaryButtonTitle(phase: model.phase)",
            "MenuPanelModel.retryTitle(canRetry: model.canRetry)",
            "MenuPanelModel.correctionToggleTitle(enabled: model.correctionEnabled)",
            "MenuPanelModel.correctionModelLine(name: model.correctionModelName)",
            "MenuPanelModel.apiKeyButtonTitle(hasKey: model.hasCloudAPIKey)",
        ] {
            // 先算成 Bool：循环里直接 #expect(source.contains(...)) 的话，
            // 一次失败会把整份源码吐好几遍。
            let present = source.contains(call)
            #expect(
                present,
                """
                MenuPanelView 里找不到 \(call)。
                这一处的文案随状态变（两句话），留在视图里就没有任何测试
                守得住其中一句被删掉——「重试」的禁用文案就是这么丢的。
                """
            )
        }
    }

    /// 翻译后端那一格四句话、二选一文案、说明行，全部来自 `AppModel` 的纯函数。
    ///
    /// 这一格是「面板说的和实际出站行为一致」的唯一保证：「云端开着但输出
    /// 中文＝零出站」「云端开着但没 key＝退回中文」这两种状态，只有那几个
    /// 函数分得清。视图里随便写一句「云端：开」就把它们抹平了。
    @Test("翻译后端那格的文案全部走 AppModel 的纯函数")
    func backendCopyComesFromModelLayer() throws {
        let source = try Self.panelSource()
        for call in [
            "AppModel.translationBackendMenuTitle(",
            "AppModel.backendChoiceLabel(cloud: false)",
            "AppModel.backendChoiceLabel(cloud: true)",
            "AppModel.translationBackendDetailLines(",
            "AppModel.translationModelMenuLine(",
            "AppModel.cloudModelMenuLine(",
            "AppModel.cloudAPIKeyMenuLine(",
            "CloudTranslationModel.known(known).menuLabel",
        ] {
            let present = source.contains(call)
            #expect(
                present,
                """
                MenuPanelView 没有调用 \(call)。
                翻译后端那一格的每一句话都必须由 AppModel 的纯函数算出——
                「开了但不会生效」的两种状态只有它们分得清。
                """
            )
        }
    }

    // MARK: - 迁移零丢失：旧菜单的每个动作入口都还在

    /// 旧 `MenuContent` 的全部动作入口逐条点名。
    ///
    /// 这是 M9 Task 7 那次迁移唯一能自动化的验收：漏搬一项的表现是
    /// 「某个功能从此在界面上点不到了」——功能本身的单测照样全绿，
    /// 因为那些测试调的是 `AppModel`，不经过界面。
    @Test("旧菜单的每一个动作入口都在面板里")
    func everyOldMenuActionSurvived() throws {
        let source = try Self.panelSource()
        for action in [
            "model.toggle()",  // 开始/结束听写 ⌥D
            "dismissMenuPanel()",  // 开听写之前先关面板、还焦点（见上面那条）
            "model.retryLastTranscription()",  // 重试
            "model.refreshAvailableModels()",  // 打开面板时重扫模型目录
            "model.selectModel(candidate)",  // 模型列表
            "presentWhisperModelFolderPanel()",  // 其他目录…
            "model.selectModelFromFolder(url.path)",
            "model.toggleCorrection()",  // 开启/关闭校正
            "presentCorrectionModelFolderPanel()",  // 指定校正模型…
            "model.selectCorrectionModel(directory: url)",
            "model.selectOutputLanguage(target)",  // 六个输出语言
            "model.useLocalBackend()",  // 后端二选一：本机
            "model.useCloudBackend()",  // 后端二选一：云端（幂等，守卫在 AppModel）
            "model.chooseTranslationModelFolder?()",  // 本机档：指定模型…
            "model.selectTranslationModel(directory: url)",
            "model.clearTranslationModel()",  // 改回跟随校正模型
            "model.selectCloudModel(.known(known))",  // 云端档：选择模型
            "model.promptCloudModel()",  // 自定义…
            "model.enterCloudAPIKey()",  // 输入/更换 API Key…
            "model.removeCloudAPIKey()",  // 删除 API Key
            "model.recheckCloudAPIKey()",  // 重新检查 API Key
            "model.startBenchRecording()",  // bench 门控
            "model.stopBLEScan()",  // BLE 门控
            "model.startBLEScan()",
            "AppLogger.shared.path",  // 打开日志
            "NSApplication.shared.terminate(nil)",  // 退出
            ".keyboardShortcut(\"q\")",  // ⌘Q
        ] {
            let present = source.contains(action)
            #expect(
                present,
                """
                MenuPanelView 里找不到 \(action)。
                这是旧 MenuContent 的一个动作入口，迁移守则是「功能与文案零增减」；
                漏掉的表现是这个功能从此在界面上点不到，而它自己的单测照样全绿。
                """
            )
        }
    }

    /// 禁用条件与环境变量门控一起点名。
    ///
    /// 禁用条件掉了不是「多能点一下」：录音途中换模型会把正在用的引擎换掉；
    /// 门控掉了则是把两个开发期工具（会把音频/原始字节写盘）默认摆给用户。
    @Test("禁用条件与开发期门控都还在")
    func disabledConditionsAndGatesSurvived() throws {
        let source = try Self.panelSource()
        for guardExpression in [
            ".disabled(!model.canSwitchModel)",  // 换模型 / 其他目录…
            ".disabled(!model.canRetry)",  // 重试
            ".disabled(model.loadingModelName != nil)",  // 加载模型时不能开听写
            "AppModel.benchEnabled",  // VINPUT_BENCH=1
            "AppModel.bleScanEnabled",  // VINPUT_BLE_SCAN=1
            "AppModel.mouseEnabled",  // 鼠标卡的门控
            "if !model.translationModelIsInherited",  // 「改回跟随」只在单独指过时出现
            "if model.hasCloudAPIKey",  // 「删除 API Key」只在有 key 时出现
        ] {
            let present = source.contains(guardExpression)
            #expect(
                present,
                """
                MenuPanelView 里找不到 \(guardExpression)。
                这是旧 MenuContent 的一条禁用条件/门控，迁移守则是「功能零增减」。
                """
            )
        }
        // 「换模型」的禁用条件有**两处**：列表里的每个模型，以及「其他目录…」。
        // 只数「有没有」的话，删掉其中一处这条断言照样绿——而漏掉「其他目录…」
        // 那处，用户就能在录音途中从磁盘换掉正在用的引擎。
        // 云端那一档的幂等守卫**不许回到视图里**。它原来就写在按钮闭包里
        // （`guard model.translationBackend == .local else { return }`），
        // 那个位置没有任何测试进得去，而这一档点错的后果是把出站开关悄悄
        // 关掉。现在决策在 `AppModel.cloudBackendRequest`，由纯函数用例钉着；
        // 视图里再摆一份的话，两份松紧迟早各走各的（`attachTranslation` 同款）。
        let guardsCloudInView = source.contains(
            "guard model.translationBackend == .local else { return }")
        #expect(
            !guardsCloudInView,
            """
            云端后端的守卫又回到了视图里。这条判断必须只留在
            AppModel.cloudBackendRequest 一处——视图里那份没有测试进得去。
            """
        )
        let switchGuards = source.components(separatedBy: ".disabled(!model.canSwitchModel)").count - 1
        #expect(
            switchGuards == 2,
            """
            .disabled(!model.canSwitchModel) 不是两处（现在是 \(switchGuards) 处）。
            模型列表项与「其他目录…」各要一处：少一处就能在录音/转写途中
            把正在用的引擎换掉。
            """
        )
    }

    /// 禁用态的主按钮必须**看起来**也是禁的。
    ///
    /// `.buttonStyle(.plain)` + 自绘渐变底不吃 `isEnabled`：光加 `.disabled`
    /// 的话，模型加载那一两分钟里用户看到一个鲜亮如常的「开始听写」，点了
    /// 没反应——与「重试」纯置灰丢掉禁用理由是同一类缺陷（用户分不清是
    /// 「现在不能用」还是「坏了」）。
    @Test("加载模型时主按钮看得出是禁用的")
    func disabledPrimaryButtonLooksDisabled() throws {
        let source = try Self.panelSource()
        let dimmed = source.contains(".opacity(model.loadingModelName != nil ? 0.45 : 1)")
        #expect(
            dimmed,
            """
            主按钮没有随 loadingModelName 压暗。自绘渐变底不吃 isEnabled，
            只加 .disabled 的话按钮看上去和平时一模一样。
            """
        )
    }
}
