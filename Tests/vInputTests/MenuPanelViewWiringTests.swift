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
/// - **防就地拼文案**：面板里的每一句面向用户的话都必须来自 model 层那些
///   被测试钉着的纯函数。拼在视图里就没有任何测试守得住它——
///   「（缺模型目录）」这类警示后缀尤其是，那时选中的语言根本没生效。
///
/// 扫源码证明不了「它长得对」，那部分在 Task 9 的真机目检清单上。
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

    static func appSource() throws -> String {
        try source("Sources/vInput/App/vInputApp.swift")
    }

    // MARK: - 场景：自绘面板取代原生菜单

    /// `.window` 样式是整个 M9 面板的前提：不切的话 `MenuPanelView` 会被塞进
    /// 原生菜单里渲染，自绘的按钮、渐变、展开行全部失效或不可点。
    @Test("MenuBarExtra 用 .window 样式")
    func menuBarExtraUsesWindowStyle() throws {
        let source = try Self.appSource()
        #expect(
            source.contains(".menuBarExtraStyle(.window)"),
            """
            vInputApp 的 MenuBarExtra 没有 .menuBarExtraStyle(.window)。
            默认样式会把 MenuPanelView 当原生菜单项渲染——自绘面板的按钮、
            渐变主按钮、面板内展开行全部失效。
            """
        )
        #expect(
            source.contains("MenuPanelView(model: delegate.model)"),
            "MenuBarExtra 的内容不是 MenuPanelView。"
        )
    }

    /// 旧的原生菜单必须真的删掉，而不是留在文件里没人引用。
    ///
    /// 留着的话它会继续被编译、被后来的人误改，而两份菜单的文案与禁用条件
    /// 从此各走各的——本仓库在 `attachTranslation` 上栽过同一个坑。
    @Test("旧的 MenuContent 已从 vInputApp 删除")
    func oldMenuContentIsGone() throws {
        let source = try Self.appSource()
        #expect(
            !source.contains("MenuContent"),
            "vInputApp.swift 里还有 MenuContent。迁移到 MenuPanelView 后它必须整块删掉。"
        )
        // 图标只有 StatusIcon 一条路径：旧 iconName 的 SF Symbol 与
        // StatusIcon 的五档映射并存的话，两处迟早对同一个状态说两套话。
        #expect(
            !source.contains("Image(systemName:"),
            "vInputApp.swift 里还在用 SF Symbol 当菜单栏图标，图标只能走 StatusIcon。"
        )
        #expect(
            source.contains("StatusIcon.image(for: StatusIcon.state("),
            "菜单栏 label 没有走 StatusIcon.image(for: StatusIcon.state(...))。"
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
        #expect(
            source.contains("AppModel.outputLanguageMenuTitle("),
            """
            MenuPanelView 没有调用 AppModel.outputLanguageMenuTitle。
            自己拼语言名的话「（缺模型目录）」这条警示就没了，
            而那时用户看到「输出语言：西班牙文」，得到的却是中文。
            """
        )
        #expect(
            !source.contains("（缺模型目录）"),
            "MenuPanelView 里出现了手写的「（缺模型目录）」——这个后缀只能由 AppModel 算出。"
        )
        #expect(
            source.contains("target.menuLabel"),
            "六个输出语言选项的文案没有走 TranslationTarget.menuLabel（每项都带实测质量）。"
        )
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
            #expect(
                source.contains(call),
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
            "model.toggleCloudBackend()",  // 后端二选一：云端
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
            #expect(
                source.contains(action),
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
            "guard model.translationBackend == .local else { return }",  // 防重复确认
            "if !model.translationModelIsInherited",  // 「改回跟随」只在单独指过时出现
            "if model.hasCloudAPIKey",  // 「删除 API Key」只在有 key 时出现
        ] {
            #expect(
                source.contains(guardExpression),
                """
                MenuPanelView 里找不到 \(guardExpression)。
                这是旧 MenuContent 的一条禁用条件/门控，迁移守则是「功能零增减」。
                """
            )
        }
        // 「换模型」的禁用条件有**两处**：列表里的每个模型，以及「其他目录…」。
        // 只数「有没有」的话，删掉其中一处这条断言照样绿——而漏掉「其他目录…」
        // 那处，用户就能在录音途中从磁盘换掉正在用的引擎。
        #expect(
            source.components(separatedBy: ".disabled(!model.canSwitchModel)").count - 1 == 2,
            """
            .disabled(!model.canSwitchModel) 不是两处。
            模型列表项与「其他目录…」各要一处：少一处就能在录音/转写途中
            把正在用的引擎换掉。
            """
        )
    }
}
