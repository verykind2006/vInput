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

    /// 截出某个函数/计算属性的函数体（从签名那一行到缩进相同的收尾 `}`）。
    ///
    /// **有几条不变量的要害是「在哪一段里」，不是「在不在」。** 「卸载」
    /// 那一行摆在主区域还是「高级」折叠区里，整份 `contains` 完全分不出来
    /// ——而那正是误点几个 GB 与不误点的差别。这里按缩进配对括号切一刀。
    ///
    /// `OnboardingWiringTests` 里那一份就是这一份（它 `@MainActor` 隔离，
    /// 转调过来）；两处各写一遍迟早各走各的。
    static func functionBody(_ source: String, signature: String) -> String? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.contains(signature) }) else { return nil }
        let indent = String(lines[start].prefix { $0 == " " })
        let closing = indent + "}"
        guard let end = lines[(start + 1)...].firstIndex(where: { $0 == Substring(closing) })
        else { return nil }
        return lines[start...end].joined(separator: "\n")
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
        // 钉「label 是一个真正的 View」，而不是钉某种写法：`Image` 没有自己的
        // body，直接写在 label 闭包里，状态读取就落进 Scene 的 body——Scene
        // 只在启动时求值一次，图标从此定格（2026-08-21 实测：听写中不变琥珀橙，
        // 而琥珀橙是「正在录音」唯一始终可见的信号）。
        let usesLabelView = source.contains("StatusIconLabel(model:")
        #expect(
            usesLabelView,
            """
            菜单栏 label 没有走 StatusIconLabel。
            直接在 label 闭包里算 Image(nsImage:) 的话，phase 变化推不动它，
            图标会一直停在启动那一刻的状态。
            """
        )
        let computesInlineInScene = source.contains("StatusIcon.image(for:")
        #expect(
            !computesInlineInScene,
            "Scene 里又直接算图标了——那样图标不会跟着状态变，要放进 StatusIconLabel。"
        )
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
            "六个输出语言选项的文案没有走 Language.menuLabel（每项都带实测质量）。"
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

    // MARK: - 高级区：卸载、下载源、储存位置

    /// **卸载入口必须待在「高级」折叠区里，不许摆在主区域。**
    ///
    /// 这一条钉的是位置，不是存在性。点错它的代价是几个 GB 的模型、全部设置
    /// 和 Keychain 里的 API key，不可撤销；而主区域里的每一项都是天天点的
    /// （开始听写、重试、模型、校正、输出语言、翻译后端），一个「删掉一切」
    /// 混在它们中间迟早会被误点。
    ///
    /// 判据：`destructiveButton("卸载` 这一行必须落在 `advancedSection` 的
    /// 函数体里。整份 `contains` 分不出这个差别——把它挪到底栏「退出」旁边，
    /// 只数「在不在」的断言照样绿。
    @Test("卸载入口在「高级」区里，不在主区域")
    func uninstallEntryLivesInsideAdvancedSection() throws {
        let source = Self.codeOnly(try Self.panelSource())
        guard let advanced = Self.functionBody(source, signature: "private var advancedSection") else {
            Issue.record("MenuPanelView 里找不到 advancedSection 的函数体。")
            return
        }
        let insideAdvanced = advanced.contains("destructiveButton(\"卸载")
        #expect(
            insideAdvanced,
            """
            「卸载 vInput 的数据…」不在 advancedSection 里了。
            它删的是几个 GB、全部设置和 Keychain 里的 key，且不可撤销——
            摆进天天要点的主区域迟早会被误点。
            """
        )
        // 反面：整份源码里只许有这一处，且必须是 destructiveButton（红字）。
        let occurrences = source.components(separatedBy: "卸载 vInput 的数据").count - 1
        #expect(
            occurrences == 1,
            "面板里出现了 \(occurrences) 处卸载入口，只该有一处（在「高级」里）。"
        )
        let isDestructive = source.contains("destructiveButton(\"卸载 vInput 的数据…\")")
        #expect(
            isDestructive,
            """
            卸载那一行不再走 destructiveButton（红字）。
            颜色是用户在**点之前**唯一能收到的警告，确认框是点之后的第二道。
            """
        )
        // 走的是那条被测过的流程，不是在视图里自己拼一遍。
        let usesFlow = source.contains("runUninstallFlow()")
        #expect(usesFlow, "卸载按钮没有调 runUninstallFlow()：扫体积、确认、真删三步无人负责。")
    }

    /// 卸载的**文案一个字都不许写在视图或面板层**。
    ///
    /// `UninstallPlan.confirmation(sizeText:)` 那份文案由测试钉着「必须说清
    /// 两件我们做不到的事」（应用删不掉自己、系统设置里的授权条目不归我们
    /// 管）。抄一份到视图里的话，那两条测试从此守的是一份没人用的字符串，
    /// 而用户看到的是抄过来的、将来不会跟着改的那一份。
    @Test("卸载确认文案来自 UninstallPlan，不在视图里手写")
    func uninstallCopyComesFromUninstallPlan() throws {
        let panel = Self.codeOnly(try Self.panelSource())
        let modal = Self.codeOnly(try Self.source("Sources/vInput/App/ModalPanels.swift"))

        let buildsFromPlan = modal.contains("UninstallPlan.confirmation(sizeText:")
        #expect(
            buildsFromPlan,
            """
            presentUninstallConfirmation 没有调 UninstallPlan.confirmation(sizeText:)。
            确认框的标题/正文/两个按钮全部只能来自那一处。
            """
        )
        // 视图与弹窗两侧都不许出现那份文案的任何一句。
        for phrase in ["废纸篓", "不可撤销", "删除并退出", "隐私与安全性"] {
            let leakedIntoPanel = panel.contains(phrase)
            #expect(!leakedIntoPanel, "MenuPanelView 里手写了卸载文案「\(phrase)」。")
            let leakedIntoModal = modal.contains(phrase)
            #expect(!leakedIntoModal, "ModalPanels 里手写了卸载文案「\(phrase)」。")
        }
    }

    /// **取消必须是卸载确认框的默认按钮。**
    ///
    /// `NSAlert` 里先加的那个是默认按钮（回车触发）。云端那一格的理由是
    /// 「一路回车不该把出站开关按开」；这一格的代价大一个量级——回车下去
    /// 删的是几个 GB 加全部设置加 Keychain 里的 key，而且没有撤销。
    ///
    /// 钉两件事：取消先加（顺序），以及判的是**第二个**按钮的返回值。
    /// 只钉顺序的话，把 `alertSecondButtonReturn` 改成 first 就等于取消即删除。
    @Test("卸载确认框里取消是默认按钮")
    func uninstallConfirmationDefaultsToCancel() throws {
        let modal = Self.codeOnly(try Self.source("Sources/vInput/App/ModalPanels.swift"))
        guard
            let body = Self.functionBody(modal, signature: "func presentUninstallConfirmation")
        else {
            Issue.record("ModalPanels.swift 里找不到 presentUninstallConfirmation 的函数体。")
            return
        }
        guard let cancelAt = body.range(of: "addButton(withTitle: copy.cancelButton)"),
            let confirmAt = body.range(of: "addButton(withTitle: copy.confirmButton)")
        else {
            Issue.record("卸载确认框没有把两个按钮都加上。")
            return
        }
        #expect(
            cancelAt.lowerBound < confirmAt.lowerBound,
            """
            卸载确认框先加了「删除并退出」——NSAlert 里先加的是默认按钮，
            于是一路回车就会把几个 GB 和 Keychain 里的 key 删掉。
            """
        )
        let readsSecondButton = body.contains("== .alertSecondButtonReturn")
        #expect(
            readsSecondButton,
            """
            卸载确认框判的不是第二个按钮。取消排在第一位，判 first 的话
            「取消」等于「确认删除」。
            """
        )
    }

    /// 下载源那个设置：面板写、向导读，中间必须经由同一个类型。
    ///
    /// 面板这一侧只能钉「调了 `model.selectDownloadSource(`」与「勾选状态读的
    /// 是 `model.forcedDownloadSource`」；key 本身全仓唯一那一条在
    /// `DownloadSourceKeyTests` 里数字面量，向导那一侧真的会照办则由
    /// `OnboardingWiringTests.forcedSourceOverridesProbe` 真跑一遍。
    /// 三条合起来才排除「点了、勾也在、行为没变」这种静默失效。
    @Test("下载源设置读写的是同一处偏好")
    func downloadSourceSettingIsWiredToItsConsumer() throws {
        let panel = Self.codeOnly(try Self.panelSource())
        let writes = panel.contains("model.selectDownloadSource(source)")
        #expect(
            writes,
            "MenuPanelView 里没有 model.selectDownloadSource(source)：这一档点了不会被存下来。"
        )
        let readsMirror = panel.contains("model.forcedDownloadSource == source")
        #expect(
            readsMirror,
            """
            下载源三选一的勾选状态没有读 model.forcedDownloadSource。
            读别的东西（或者干脆不读）的话，面板显示的档位与真正生效的那档
            可以长期不一致。
            """
        )
        // 面板里不许直接碰 UserDefaults：那正是「两边各写一个 key」的起点。
        let touchesDefaults = panel.contains("UserDefaults")
        #expect(!touchesDefaults, "MenuPanelView 直接碰了 UserDefaults——偏好只能经由 AppModel。")

        let appModel = Self.codeOnly(try Self.source("Sources/vInput/App/AppModel.swift"))
        let persists = appModel.contains("downloadSourcePreference.forced = source")
        #expect(
            persists,
            """
            AppModel.selectDownloadSource 没有把选择写进 DownloadSourcePreference。
            只更新可观察镜像的话，重启之后这个设置就没了，而用户以为它一直在。
            """
        )
        // **对称的另一半：启动时要把它读回来。**
        //
        // 少了这一行不会有任何东西报错，坏结果却正是这套设计要防的那个的
        // 镜像版本：重启之后面板上「自动」勾着，而向导直接读
        // `DownloadSourcePreference().forced`、仍然在强制镜像——**面板说的和
        // 实际做的不一致**，且两边都「自洽」。写与读必须一起钉。
        let restoresAtLaunch = appModel.contains(
            "forcedDownloadSource = downloadSourcePreference.forced")
        #expect(
            restoresAtLaunch,
            """
            bootstrap 里没有把下载源偏好读回可观察镜像。
            重启后面板会显示「自动」，而向导仍然按上次强制的那个源下载——
            面板说的和实际做的不一致，且没有任何东西会红。
            """
        )
    }

    /// 「新模型已下载好…」那一行必须挂在**可观察的存储属性**上。
    ///
    /// `@Observable` 只跟踪自己的可变存储属性。`pendingModelFolder` 一旦写成
    /// `{ modelAdoption.pendingFolder }`（`ModelAdoptionQueue` 是普通类），
    /// 改队列里的字段不通知任何人——那一行「能显示」纯属巧合：
    /// `adoptDownloadedModel` 恰好先调了 `refreshAvailableModels()`、紧接着
    /// 进度回调又动了 `downloadingModelProgress`，是这两个被观察的属性顺手
    /// 让面板失效的。任何一处顺序调整都会静默干掉这一行。
    ///
    /// 本仓库为这条规矩付过两次学费（`canRetry`、`correctionEnabled`，
    /// 它们的注释里都写着同一句）。
    @Test("待启用的模型挂在可观察的存储属性上，不是队列的转发")
    func pendingModelFolderIsAnObservableStoredProperty() throws {
        let source = Self.codeOnly(try Self.source("Sources/vInput/App/AppModel.swift"))
        let isStored = source.contains("private(set) var pendingModelFolder: String?")
        #expect(
            isStored,
            """
            AppModel.pendingModelFolder 不再是存储属性。
            @Observable 看不见 ModelAdoptionQueue 里的字段，面板那行
            「结束后自动启用」会变成时有时无。
            """
        )
        let forwards = source.contains("pendingModelFolder: String? { modelAdoption")
        #expect(!forwards, "pendingModelFolder 又写回了对队列的转发——那样它不被观察。")

        // 两个动队列的入口都必须同步镜像，否则那一行只会出现、不会消失
        // （或者反过来）。
        for member in ["func adoptDownloadedModel(", "func applyPendingModelAdoption("] {
            guard let body = Self.functionBody(source, signature: member) else {
                Issue.record("AppModel 里找不到 \(member) 的函数体。")
                continue
            }
            let syncs = body.contains("syncPendingModelMirror()")
            #expect(
                syncs,
                "\(member) 没有同步 pendingModelFolder 镜像——面板上那行会与实际状态对不上。"
            )
        }
    }

    /// 「储存位置」那一格：既要说在哪，也要能直接打开。
    ///
    /// 这是好奇的用户唯一能看见「那几个 GB 在哪」的地方——它与卸载入口是
    /// 同一条产品义务的两半（我们把几个 GB 塞进了用户不感知的目录）。
    @Test("高级区能看见并打开模型储存位置")
    func advancedSectionShowsStorageLocation() throws {
        let source = Self.codeOnly(try Self.panelSource())
        guard let advanced = Self.functionBody(source, signature: "private var advancedSection") else {
            Issue.record("MenuPanelView 里找不到 advancedSection 的函数体。")
            return
        }
        for call in [
            "MenuPanelModel.storageLocationLine(",
            // 「显示位置」与「在访达中显示」必须用同一个判据，否则会出现
            // 「说还没建、却又能打开」。目录不存在时退到最近的祖先，
            // 因为 Finder 拿到不存在的路径是静默无反应的。
            "MenuPanelModel.revealTarget(",
            "NSWorkspace.shared.selectFile(target, inFileViewerRootedAtPath: \"\")",
            "presentCorrectionModelFolderPanel()",
        ] {
            let present = advanced.contains(call)
            #expect(
                present,
                """
                「高级」区里找不到 \(call)。
                储存位置（看得见、打得开）与校正模型目录都归这一格；
                少一项的表现是那个功能从此在界面上点不到。
                """
            )
        }
    }

    /// **在飞的下载必须在面板上看得见。**
    ///
    /// 关掉向导不取消下载（扔掉几百 MB 更糟），而菜单栏图标的 `loadingModel`
    /// 说的是「模型正在加载」，不是「正在下载」——两者差着十几分钟。没有这
    /// 一行的话，用户关掉向导之后看到的是一个若无其事的面板。
    ///
    /// 连「待启用」那行一起钉：下载在录音途中完成时换模型会被推迟，
    /// 而「下完了但还是老模型」与「下载失败了」在界面上长得一模一样。
    @Test("面板上看得见在飞的下载与待启用的模型")
    func panelShowsInFlightDownload() throws {
        let source = Self.codeOnly(try Self.panelSource())
        for call in [
            "MenuPanelModel.downloadLine(progress: model.downloadingModelProgress)",
            "MenuPanelModel.pendingModelLine(folder: model.pendingModelFolder)",
        ] {
            let present = source.contains(call)
            #expect(
                present,
                """
                MenuPanelView 里找不到 \(call)。
                在飞的下载与待启用的模型都是「应用正在替你做的事」，
                看不见的话用户只会觉得应用忽然自己进入了加载态。
                """
            )
        }
        // 那一格要真的被摆进 body 里，光定义不用等于不存在。
        guard let body = Self.functionBody(source, signature: "var body: some View") else {
            Issue.record("MenuPanelView 里找不到 body。")
            return
        }
        let rendered = body.contains("downloadStatus")
        #expect(rendered, "downloadStatus 定义了却没有摆进面板的 body 里。")
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

    /// 头部状态行必须把「有没有模型」也交给 `headerStatus`。
    ///
    /// `MenuPanelModelTests.zeroModelsIsNotReady` 证的是那个纯函数会说真话，
    /// 证不了视图真的把这个事实喂了进去——不喂的话（哪怕写死 `true`），
    /// 面板在零模型时照旧一个绿点加「就绪」。
    @Test("头部状态行读的是真实的「有没有模型」")
    func headerIsToldWhetherAModelExists() throws {
        let source = try Self.panelSource()
        let code = Self.codeOnly(source)
        #expect(
            code.contains("hasModel: model.hasModel"),
            """
            面板没有把 model.hasModel 交给 headerStatus。
            零模型时头部会继续说「就绪」，而按下「开始听写」会开始下载
            一个用户没要过的模型。
            """
        )
    }

    /// 空模型列表那一行的文案不许再写在视图里。
    ///
    /// 它原先是就地写死的「vendor/models 下没有模型」——开发机才有的仓库
    /// 路径，而读到它的正是手上一个模型都没有的新用户。搬进 model 层是为了
    /// 让 `MenuPanelModelTests` 钉得住它。
    @Test("空模型列表提示走 MenuPanelModel")
    func emptyModelListCopyComesFromTheModelLayer() throws {
        let source = try Self.panelSource()
        let code = Self.codeOnly(source)
        #expect(
            code.contains("MenuPanelModel.emptyModelListLine"),
            "空列表提示没走 MenuPanelModel.emptyModelListLine。")
        let stillMentionsVendor = code.contains("vendor/models")
        #expect(
            stillMentionsVendor == false,
            "面板代码里还写着 vendor/models——那是开发机上的仓库路径。")
    }

    /// 向导第五步的「可以听写了」必须**同时**判有没有模型。
    ///
    /// 原先是 `loadingModelName == nil`，而那句话的意思只是「此刻没有东西在
    /// 加载」——零模型时恒为真：按钮亮着、「语音模型还在准备」那句提示被
    /// 压掉，用户按下去开始一次注定失败的听写。恰好是验收标准的最后一步。
    @Test("向导的「可以听写了」要求真有一个模型")
    func wizardReadinessRequiresAModel() throws {
        let source = try Self.appSource()
        guard let range = source.range(of: "wiring.isDictationReady = {") else {
            Issue.record("找不到 isDictationReady 的接线，这条测试的锚点失效了")
            return
        }
        let body = Self.codeOnly(String(source[range.lowerBound...].prefix(400)))
        #expect(
            body.contains("model.hasModel"),
            """
            isDictationReady 没有判 hasModel，只判了「没有东西在加载」。
            下载失败之后第五步的按钮照样亮着，而按下去没有任何模型。
            """
        )
    }
}
