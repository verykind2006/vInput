import Foundation
import Testing

@testable import vInput

/// `AppModel` 的接线不变量，用**扫源码**的方式钉住。
///
/// # 为什么是扫源码而不是跑 AppModel
///
/// `AppModel` 在 `init` 里就要真麦克风、真快捷键注册、真 CGEvent tap，
/// 单元测试里起不来。现有的办法是 `MouseWiringUnderTest`——照抄一份接线
/// 再测那一份。它挡得住「协调器与桥接错了」，**挡不住「AppModel 那一份
/// 和抄本不一样了」**，而 Esc 取消不收抑制（独立验收 2026-08-18）恰恰就是
/// 这一类：抄本里根本没有 Esc 这条路。
///
/// 扫源码只能证明「那行代码还在」，证明不了它是对的——正确性由
/// `RemoteKeySuppressorTests` 那几条纯逻辑断言负责。两者分工：
/// 一个测语义，一个防删除。
@Suite("AppModel 接线不变量")
struct AppModelWiringTests {
    /// 取 `AppModel.swift` 里某个成员的源码窗口：从声明那一行起，到**下一个
    /// 成员级文档注释**（行首恰好四个空格的 `///`）为止。
    ///
    /// **不用固定长度的窗口。** `enableCorrection()` 与
    /// `selectCorrectionModel(directory:)` 紧挨着，而要守的是同一句话；
    /// 窗口一长就会读到隔壁那一句，于是「只删掉其中一处」这条变异照样全绿
    /// ——正是本仓库栽过八次的那类空守卫。
    ///
    /// 不是假想：从 `enableCorrection` 的声明算起，它自己那句
    /// `applyTranslationPreference()` 在偏移 1152，隔壁那句在 2432，
    /// 而下一个成员级文档注释在 1640。2026-08-19 实测把本函数换成
    /// `String(rest.prefix(2600))` 并删掉 `enableCorrection` 里那一句：
    /// **8 条全绿**（换成 `prefix(1600)` 时还红，所以窗口取多长成了运气）。
    ///
    /// 函数体里的注释一律是 `//` 或缩进更深的，不会撞上这个分隔符。
    static func memberBody(_ source: String, startingAt declaration: String) throws -> String {
        let start = try #require(
            source.range(of: declaration),
            "找不到 \(declaration)，这个测试的锚点失效了"
        )
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    /// ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    static func appModelSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // vInputTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
        return try String(
            contentsOf: root.appendingPathComponent("Sources/vInput/App/AppModel.swift"),
            encoding: .utf8
        )
    }

    /// 按 Esc 取消时必须当场收掉按键抑制。
    ///
    /// 漏掉的后果不是「少一次清理」：鼠标那档是 `.allExcept([Esc])`，
    /// 用户按 Esc 之后整个键盘只剩 Esc 可用，直到他松开鼠标语音键。
    @Test("Esc 取消的处理里收掉按键抑制")
    func cancelEndsSuppression() throws {
        let source = try Self.appModelSource()
        guard let start = source.range(of: "cancelHotkey.onCancel = {") else {
            Issue.record("找不到 cancelHotkey.onCancel 的接线，这个测试的锚点失效了")
            return
        }
        // 闭包本体只有十几行，取一段足够长的窗口即可，不必真去配对花括号。
        let body = source[start.lowerBound...].prefix(1200)
        #expect(
            body.contains("keySuppressor.endSuppressing()"),
            """
            cancelHotkey.onCancel 里没有 endSuppressing()。
            鼠标档的抑制策略是 .allExcept([Esc])：不收的话，按 Esc 取消之后
            整个键盘只剩 Esc 能用，直到用户松开鼠标语音键。
            """
        )
    }

    /// 会话状态变化时同步抑制器。这是「离开 .listening 就还键盘」那道网。
    @Test("会话状态变化时同步按键抑制器")
    func stateChangeSyncsSuppressor() throws {
        let source = try Self.appModelSource()
        #expect(
            source.contains("keySuppressor.update(for: state)"),
            """
            session.onStateChange 里没有 keySuppressor.update(for: state)。
            离开 .listening 的出口不止一个（松开键、撞时长上限、转写失败、
            Esc 取消），逐个出口去收迟早漏一个——Esc 那条已经漏过一次。
            """
        )
    }

    // MARK: - 翻译层的挂载走协调器，且只走协调器

    /// 翻译层「挂什么」的状态机搬进了 `TranslationAttachmentCoordinator`
    /// （理由见那边：长在 `AppModel` 里是零覆盖，两条变异实测全绿）。
    ///
    /// 搬走之后要守的是「`AppModel` 真的在调它」——
    /// `TranslationAttachmentCoordinatorTests` 跑的是协调器，那套用例在
    /// 「`AppModel` 压根不调协调器」时照样全绿，正是本仓库栽过七次的
    /// 「看着在检查什么，其实什么都没检查」的翻版。
    @Test("换语言时把偏好交给翻译协调器")
    func applyTranslationGoesThroughCoordinator() throws {
        let source = try Self.appModelSource()
        #expect(
            source.contains("translationCoordinator?.apply()"),
            """
            applyTranslationPreference 里没有 translationCoordinator?.apply()。
            没有这一句的话，用户在菜单里换语言什么都不会发生，
            而 TranslationAttachmentCoordinatorTests 照样全绿。
            """
        )
    }

    /// 会话回到 idle 时要给协调器一次补挂的机会。
    ///
    /// 缺了它的表现是「用户在录音途中换的语言永远不生效」——
    /// `DictationSession` 只在 idle 时接受挂载，那次改动就此丢失，
    /// 而菜单已经写着新语言。
    @Test("会话回到 idle 时给翻译协调器补挂的机会")
    func idleResumesPendingTranslationAttach() throws {
        let source = try Self.appModelSource()
        #expect(
            source.contains("translationCoordinator?.sessionDidBecomeIdle()"),
            """
            onStateChange 的 .idle 分支里没有 sessionDidBecomeIdle()。
            录音途中换的语言会被 DictationSession 拒绝，没人补挂的话
            这次改动永远丢失，而菜单已经写着新语言。
            """
        )
    }

    /// 会话回到 idle 时补上被推迟的**换模型**。
    ///
    /// 与上面那条补挂并排，坏结果却不一样：下载在用户正说着话的时候完成时，
    /// `selectModel` 被 `canSwitchModel` 挡下来（挡是对的），而挡下来之后
    /// **再也没有人重试**——用户刚下的 1.5GB 要等到下次启动才生效，
    /// 界面上「下载完成」与「下载完成但没换上」长得一模一样。
    ///
    /// 记账与判断在 `ModelAdoptionQueue`（那边有真跑的用例），
    /// 这里钉的是「`AppModel` 真的问了它」——这一行是本文件里
    /// 唯一能守住那条接线的东西。
    ///
    /// **断言的是「调用在 onStateChange 里」，不是「这个名字在文件里」。**
    /// 后者是空守卫：`private func applyPendingModelAdoption()` 那行声明本身
    /// 就含有这个子串，删掉调用点照样绿——2026-08-22 实测过一次，
    /// 变异（删掉 `.idle` 分支里那一行）当场全绿。
    @Test("会话回到 idle 时补上被推迟的换模型")
    func idleResumesPendingModelAdoption() throws {
        let source = try Self.appModelSource()
        let start = try #require(
            source.range(of: "session.onStateChange"), "找不到 onStateChange，锚点失效了")
        let end = try #require(
            source.range(of: "session.onError"), "找不到 onError，锚点失效了")
        let stateChangeBody = String(source[start.upperBound..<end.lowerBound])
        #expect(
            stateChangeBody.contains("self.applyPendingModelAdoption()"),
            """
            onStateChange 里没有 self.applyPendingModelAdoption()。
            录音途中下完的模型会被永久搁置——菜单里还是老模型，
            而用户刚等了十几分钟。
            """
        )
        // 向导那条路必须走 adoptDownloadedModel，不能绕回 selectModelFromFolder：
        // 绕回去就等于没有队列，被拒的那次照样丢。
        let appSource = try MenuPanelViewWiringTests.appSource()
        let adopts = MenuPanelViewWiringTests.codeOnly(appSource)
            .contains("model.adoptDownloadedModel(folder)")
        #expect(
            adopts,
            """
            vInputApp 把向导下载好的模型直接交给了 selectModelFromFolder。
            那条路在会话进行中会被静默拒绝且没有下文，必须走
            adoptDownloadedModel（它会记账、会话结束时补做）。
            """
        )

        // **补做这条路上不许弹红字。** 目录可能已经不在了（手动删了、卸载过、
        // 换了盘），而这一步发生在「用户刚说完一句话」的那一刻——
        // `selectModelFromFolder` 会把 `phase` 打成
        // 「这不是模型目录，缺少：…」，对他来说是个没有任何上下文的报错：
        // 他没点过任何东西。所以走 `ModelCatalog.validate` 自己判，失败只记日志。
        let body = try #require(
            MenuPanelViewWiringTests.functionBody(
                MenuPanelViewWiringTests.codeOnly(source),
                signature: "func applyPendingModelAdoption("),
            "AppModel 里找不到 applyPendingModelAdoption 的函数体")
        #expect(
            !body.contains("selectModelFromFolder("),
            """
            补做那条路又走回 selectModelFromFolder 了。
            目录已经不在时它会把 phase 打成红字，而用户刚说完一句话、
            什么都没点——那是个毫无上下文的报错。
            """
        )
        #expect(
            body.contains("ModelCatalog.validate(folder:"),
            "补做前没有自己校验目录，没法在目录消失时安静地放弃。"
        )
    }

    /// **`AppModel` 里不许再出现第二条挂翻译的路径。**
    ///
    /// 这是「抽出来的那个就是实际跑的那个」最硬的一条：协调器的用例只有在
    /// 它是**唯一**实现时才代表线上行为。哪天有人在 `AppModel` 里就地补一句
    /// `session.attachTranslation(...)`，协调器那套用例一条都不会红，而两条
    /// 路径的松紧从此各走各的。
    ///
    /// 用整份源码做 `contains` 而不是逐行 grep：跨行写法（把参数换行）
    /// 行式匹配看不见——本仓库一天栽过三次这个坑。
    @Test("AppModel 自己不再直接挂翻译流水线")
    func appModelHasNoSecondTranslationAttachPath() throws {
        let source = try Self.appModelSource()
        #expect(
            !source.contains("attachTranslation"),
            """
            AppModel 里又出现了 attachTranslation。翻译层的挂载必须只有
            TranslationAttachmentCoordinator 一条路径，否则那套用例证明不了
            线上跑的是什么。
            """
        )
    }

    // MARK: - 写校正模型目录的两条入口都要重挂翻译层

    /// `correction.modelDirectory` 是翻译层今天**唯一**的模型来源
    /// （`translation.modelDirectory` 没有任何入口能设）。写它的两条入口
    /// 不通知翻译协调器的话，用户照着应用自己给的那句
    /// 「请在「校正」菜单里指定本地模型目录」做完之后，说话出来的还是中文、
    /// 菜单还挂着「（缺模型目录）」，要重启 app 才生效。
    ///
    /// 兜底也不接：`onStateChange` 的 idle 分支走的是
    /// `sessionDidBecomeIdle()`，第一行就是 `guard isPending else { return }`,
    /// 而上一次 `apply()` 是**成功**返回的，`isPending == false`。
    ///
    /// 2026-08-19 QA 实测：两条入口各补一句之前，981 tests 全绿——
    /// 两个方向一处守卫都没有。
    ///
    /// 顺序也一起钉住：翻译要退回校正层的目录，而校正的开启校验可能刚把
    /// 一个失效目录判掉，反了的话翻译会拿到一个已经确认无效的路径
    /// （与 `bootstrap` 里那一处同一条理由）。
    @Test("开启校正之后立刻重挂翻译层，且排在校正之后")
    func enablingCorrectionReattachesTranslation() throws {
        let body = try Self.memberBody(
            try Self.appModelSource(), startingAt: "private func enableCorrection() {")
        try Self.expectReattachesTranslationAfterCorrection(in: body, entry: "enableCorrection()")
    }

    /// 「指定校正模型…」是写同一个键的第二条入口。
    ///
    /// 少了这一句还有第二个后果：翻译层继续持有**旧目录**的 `MLXTranslator`,
    /// 登记处里同时活着两份 2 GB 权重——`ModelContainerRegistry` 要省的
    /// 那一份正好在这条路径上被吃回去。
    @Test("换校正模型之后立刻重挂翻译层，且排在校正之后")
    func selectingCorrectionModelReattachesTranslation() throws {
        let body = try Self.memberBody(
            try Self.appModelSource(),
            startingAt: "func selectCorrectionModel(directory: URL) {")
        try Self.expectReattachesTranslationAfterCorrection(
            in: body, entry: "selectCorrectionModel(directory:)")
    }

    static func expectReattachesTranslationAfterCorrection(
        in body: String, entry: String
    ) throws {
        let correction = body.range(of: "applyCorrectionPreference()")
        let translation = body.range(of: "applyTranslationPreference()")
        #expect(
            translation != nil,
            """
            \(entry) 的成功分支里没有 applyTranslationPreference()。
            correction.modelDirectory 是翻译层唯一的模型来源，不重挂的话
            用户照着「请在「校正」菜单里指定本地模型目录」做完仍然出中文，
            要重启 app 才生效。
            """
        )
        guard let correction, let translation else { return }
        #expect(
            correction.lowerBound < translation.lowerBound,
            """
            \(entry) 里 applyTranslationPreference() 排在了
            applyCorrectionPreference() 之前。翻译要退回校正层的目录，
            而校正的校验可能刚把一个失效目录判掉——反了的话翻译会拿到
            一个已经确认无效的路径。
            """
        )
    }

    // MARK: - 换语言时的即时反馈

    /// 用户刚点完菜单、菜单当场就关了，**HUD 才是他这一刻会看到的东西**。
    ///
    /// 菜单标题上的「（缺模型目录）」后缀是常驻提示，但它在菜单里；
    /// 少了这几行，选了西班牙文而没有模型时用户得不到任何即时反馈——
    /// 正是「静默不工作」。2026-08-19 QA 实测：删掉这三行，981 tests 全绿。
    @Test("换翻译目标时缺模型要当场弹 HUD")
    func selectingTranslationChoiceWarnsWhenModelMissing() throws {
        let body = try Self.memberBody(
            try Self.appModelSource(),
            startingAt: "func selectTranslationChoice(_ choice: TranslationChoice) {")
        #expect(
            body.contains("if translationModelMissing"),
            """
            selectTranslationChoice 里没有「缺模型目录就提示」的判断。
            菜单当场就关了，用户这一刻唯一看得见的反馈就是 HUD。
            """
        )
        // 文案取自 `TranslationAnnotation`，不另写一句——「翻译为什么没生效」
        // 只该有一处措辞。写死一个字符串字面量时这条会红。
        #expect(
            body.contains("showHUDNotice(TranslationAnnotation.missingLocalModel.hudLabel)"),
            """
            selectTranslationChoice 里没有 showHUDNotice(
            TranslationAnnotation.missingLocalModel.hudLabel)。
            """
        )
    }

    // MARK: - 缩放热键（⌘±/⌘0）接线

    /// 会话状态变化时必须同步缩放热键控制器——不然它永远停在「未注册」，
    /// `ZoomHotkeyTests` 那套用例只测 `ZoomHotkeyController` 自身的逻辑，
    /// 证明不了 `AppModel` 真的在调它（与 keySuppressor 那条同一个理由）。
    @Test("会话状态变化时同步缩放热键控制器")
    func stateChangeSyncsZoomHotkeys() throws {
        let source = try Self.appModelSource()
        #expect(
            source.contains("zoomHotkeys.update(for: state)"),
            """
            onStateChange 里没有 zoomHotkeys.update(for: state)。
            少了这一行，⌘±/⌘0 永远不会注册，ZoomHotkeyController 自身的
            单测再绿也测不出这个漏洞。
            """
        )
    }

    /// ⌘±/⌘0 三个回调必须都接到 HUDViewModel 的三个字号方法上，
    /// 而不是漏接其中一个或接错方法。
    @Test("缩放热键的三个回调都接到 HUDViewModel 的字号方法")
    func zoomHotkeysForwardToHUDFontSizeMethods() throws {
        let source = try Self.appModelSource()
        #expect(
            source.contains("zoomHotkeys.onIncrease = { [weak self] in self?.hudModel.increaseFontSize() }"),
            "zoomHotkeys.onIncrease 没有接到 hudModel.increaseFontSize()。"
        )
        #expect(
            source.contains("zoomHotkeys.onDecrease = { [weak self] in self?.hudModel.decreaseFontSize() }"),
            "zoomHotkeys.onDecrease 没有接到 hudModel.decreaseFontSize()。"
        )
        #expect(
            source.contains("zoomHotkeys.onReset = { [weak self] in self?.hudModel.resetFontSize() }"),
            "zoomHotkeys.onReset 没有接到 hudModel.resetFontSize()。"
        )
    }

    // MARK: - 模型根目录解析走 resolveRoot，不直接用 defaultRoot

    /// `bootstrap()` 必须经 `ModelCatalog.resolveRoot(...)` 取模型根目录，
    /// 不能退回直接调 `ModelCatalog.defaultRoot(appBundleURL:)`。
    ///
    /// 这是接线变异，不是逻辑变异：`ModelRootResolutionTests` 那五条测的是
    /// `resolveRoot` 自身对不对，证明不了 `AppModel` 真的在调它——把这一句
    /// 换回 `defaultRoot(appBundleURL:)` 之后那五条照样全绿（`resolveRoot`
    /// 本身没动），装进 `/Applications` 又会回到本批要修的那个核心缺口。
    @Test("bootstrap 用 resolveRoot 取模型根目录")
    func bootstrapUsesResolveRootForModelRoot() throws {
        let body = try Self.memberBody(
            try Self.appModelSource(), startingAt: "func bootstrap() {")
        #expect(
            body.contains("ModelCatalog.resolveRoot("),
            """
            bootstrap() 里没有 ModelCatalog.resolveRoot(...)。
            少了这一步，modelRoot 会退回 defaultRoot(appBundleURL:)——
            那条路径假定 .app 躺在 <仓库>/dist/ 下，装进 /Applications
            必然找不到模型。
            """
        )
    }

    // MARK: - HF 端点（tokenizer 那一路只认环境变量）

    /// 启动时必须把 `HF_ENDPOINT` 设好，**而且要排在造 transcriber 之前**。
    ///
    /// `HuggingFaceEndpointTests` 证的是「设进去的值对不对」，证不了
    /// 「有没有人在启动时调它」——不调的话，一台靠镜像装成的国内机器，
    /// 每次启动加载模型都会为了 2.8MB 的 tokenizer 去连 huggingface.co。
    /// 顺序同样要钉：排在 `SwitchableTranscriber` 之后的话，这一轮启动的
    /// 第一次加载仍然用着旧端点。
    @Test("bootstrap 在造 transcriber 之前设好 HF 端点")
    func bootstrapAppliesTheEndpointBeforeBuildingTheTranscriber() throws {
        let body = try Self.memberBody(
            try Self.appModelSource(), startingAt: "func bootstrap() {")
        guard let apply = body.range(of: "HuggingFaceEndpoint.applyFromPreference(") else {
            Issue.record(
                """
                bootstrap() 里没有 HuggingFaceEndpoint.applyFromPreference(...)。
                模型下载那一路能带 endpoint 参数，tokenizer 那一路不能——
                它只读进程的 HF_ENDPOINT。不设的话，镜像只覆盖了一半。
                """)
            return
        }
        guard let transcriber = body.range(of: "SwitchableTranscriber(") else {
            Issue.record("bootstrap() 里找不到 SwitchableTranscriber，这条测试的锚点失效了")
            return
        }
        #expect(
            apply.lowerBound < transcriber.lowerBound,
            "HF 端点设在了造 transcriber 之后：这一轮启动的模型加载仍然用旧端点。"
        )
    }

    /// 面板「高级 → 下载源」换档时端点跟着换。
    ///
    /// 不跟的话，用户看到「强制国内镜像」打着勾，而 tokenizer 那几 MB
    /// 照样去连官方源——正是这个设置最容易被以为已经生效的地方。
    @Test("换下载源时同步改 HF 端点")
    func selectingDownloadSourceUpdatesTheEndpoint() throws {
        let body = try Self.memberBody(
            try Self.appModelSource(),
            startingAt: "func selectDownloadSource(_ source: DownloadSource?) {")
        #expect(
            body.contains("HuggingFaceEndpoint.apply("),
            """
            selectDownloadSource 里没有同步 HF 端点。
            用户点了「强制国内镜像」，模型会走镜像，而 tokenizer 仍走官方源。
            """
        )
    }

    // MARK: - 零模型 / 导入的模型

    /// 一个模型都没有时不许开始听写，且要当场说出来。
    ///
    /// `MissingModelTranscriber` 是兜底，但它只在**转写那一刻**报错——
    /// 那时用户已经对着麦克风说完一句话了。这道 guard 把这句话提前到
    /// 按下按钮的那一刻。
    @Test("零模型时 toggle 当场拒绝")
    func toggleRefusesWithoutAModel() throws {
        let body = try Self.memberBody(
            try Self.appModelSource(), startingAt: "func toggle() {")
        #expect(
            body.contains("guard hasModel else"),
            """
            toggle() 里没有 hasModel 那道守卫。
            零模型时用户会录完一整句话才收到失败，而在那之前面板一直
            表现得像一切正常。
            """
        )
    }

    /// 还没 bootstrap 的 `AppModel`（也就是「一个模型都没有」那个状态）
    /// 必须如实说 `hasModel == false`。
    ///
    /// 这一条不扫源码，真造一个 `AppModel`：把 `hasModel` 写成 `true` 是
    /// 最省事的「让红变绿」手法，而那样面板会立刻回到「零模型说就绪」。
    @MainActor
    @Test("没有模型时 hasModel 是 false")
    func freshModelHasNoModel() {
        #expect(AppModel().hasModel == false)
    }

    /// `hasModel` 读的那个字段，两个写入点一个都不许少。
    ///
    /// 少了 bootstrap 那次：开着模型启动，面板照样说「还没有语音模型」。
    /// 少了 selectModel 那次：零模型启动后导入一个模型成功，面板还在说没有。
    @Test("activeModelFolder 在启动与换模型两处都被写入")
    func activeModelFolderIsSetOnBothPaths() throws {
        let source = try Self.appModelSource()
        let bootstrap = try Self.memberBody(source, startingAt: "func bootstrap() {")
        #expect(
            bootstrap.contains("activeModelFolder = initial.folder"),
            "bootstrap 没有写 activeModelFolder：开着模型启动也会显示成零模型。")
        #expect(
            bootstrap.contains("?? ModelCatalog.noModel"),
            """
            bootstrap 的零模型占位符不是 ModelCatalog.noModel。
            原先那个占位符名叫 openai_whisper-base 而目录为空，
            按下去会去下载一个用户没要过的模型。
            """)
        #expect(
            bootstrap.contains("importedModels.revalidate"),
            "bootstrap 没有复核导入的目录：搬走的目录会一直挂在模型列表里。")

        let select = try Self.memberBody(
            source, startingAt: "func selectModel(_ model: ModelDescriptor) {")
        #expect(
            select.contains("activeModelFolder = model.folder"),
            "换模型成功后没有更新 activeModelFolder：面板会一直说「还没有语音模型」。")
    }

    /// 导入的模型目录必须被记下来，否则下次启动就没了。
    ///
    /// 这是设计里写明的那条逃生口（「把本机现成的模型目录拷给太太」）。
    /// `ImportedModelPreferenceTests` 证的是那个偏好自己对不对，
    /// 证不了 `AppModel` 真的在往里写。
    @Test("手选模型目录时记住它")
    func selectingAFolderRemembersIt() throws {
        let body = try Self.memberBody(
            try Self.appModelSource(),
            startingAt: "func selectModelFromFolder(_ folder: String) {")
        #expect(
            body.contains("importedModels.remember("),
            """
            selectModelFromFolder 里没有 importedModels.remember(...)。
            从 ~/Desktop 导入的模型这一次能用，重启就掉回「一个模型都没有」。
            """
        )
    }

    /// 重扫模型列表时必须把导入的那些并进来。
    ///
    /// 面板 `onAppear` 每次都会重扫：只在 bootstrap 里并、这里不并的话，
    /// 表现是「导入的模型开着能用，打开一次面板就从列表里消失了」。
    @Test("重扫模型时并进导入的目录")
    func refreshMergesImportedFolders() throws {
        let source = try Self.appModelSource()
        let refresh = try Self.memberBody(
            source, startingAt: "func refreshAvailableModels() {")
        #expect(
            refresh.contains("discoverModels()"),
            "refreshAvailableModels 没走 discoverModels()——导入的模型会在重扫时消失。")
        let discover = try Self.memberBody(
            source, startingAt: "private func discoverModels() -> [ModelDescriptor] {")
        #expect(
            discover.contains("ModelCatalog.merge("),
            "discoverModels 没有并进导入的目录，那份偏好等于白存。")
    }

    // MARK: - 遥控器「·」键 → 空格 / 菜单键 → Command+Tab

    /// 取某个 `hidListener.onXxx = { … }` 闭包的源码窗口。
    ///
    /// **结束锚点是「下一个 `hidListener.`」，不是写死的 `hidListener.start()`。**
    /// 2026-08-22 加菜单键那一路时，新闭包插在了「·」键与 `start()` 之间——
    /// 写死 `start()` 的话，`gravePressedBody` 会把两个闭包一起吃进来，
    /// 「·」键那几条断言就再也分不清自己看的是哪一段了。
    static func hidCallbackBody(_ source: String, _ callback: String) throws -> String {
        let anchor = "hidListener.\(callback) = {"
        let start = try #require(
            source.range(of: anchor),
            "找不到 \(callback) 的接线，这个测试的锚点失效了"
        )
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n        hidListener.")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    static func gravePressedBody(_ source: String) throws -> String {
        try hidCallbackBody(source, "onGravePressed")
    }

    static func contextMenuPressedBody(_ source: String) throws -> String {
        try hidCallbackBody(source, "onContextMenuPressed")
    }

    /// 守上面那个结束锚点：两个闭包的窗口不许互相吃进对方。
    @Test("两个回声键的接线窗口互不重叠")
    func callbackBodiesDoNotOverlap() throws {
        let source = try Self.appModelSource()
        let grave = try Self.gravePressedBody(source)
        let menu = try Self.contextMenuPressedBody(source)
        #expect(!grave.contains("appSwitcher.press()"),
                "「·」键的窗口把菜单键那段一起吃进来了，那几条断言从此分不清看的是哪一段")
        #expect(!menu.contains("postSpace()"),
                "菜单键的窗口把「·」键那段一起吃进来了")
    }

    /// 这个键要做的是**两件事**，只做一件都不合格：
    /// 只注空格 → 用户同时得到「·」和一个空格；只吞键 → 什么都没发生。
    @Test("「·」键既注入空格，也吞掉原始按键")
    func graveKeyPostsSpaceAndSwallows() throws {
        let body = try Self.gravePressedBody(try Self.appModelSource())
        #expect(
            body.contains("echoSwallower.arm(.grave)"),
            """
            onGravePressed 里没有 echoSwallower.arm(.grave)。
            系统会照常投递这个键（那就是用户看到的「·」），不吞掉的话
            按一下会同时得到「·」和一个空格。
            """
        )
        #expect(
            body.contains("remoteKeyPoster.postSpace()"),
            """
            onGravePressed 里没有 postSpace()。
            用户要的是 Finder 的 Quick Look，那是系统对空格「键」的响应。
            """
        )
    }

    /// **武装必须是无条件的，且排在听写守卫之前。**
    ///
    /// 排在守卫之后（或写进 else 分支）的后果：录音中误碰这个键，空格不注、
    /// 「·」照进——正好是最坏的一档（往正在听写的目标应用里插了个字符）。
    /// 正确的结果是什么都没发生。
    @Test("吞键的武装排在「录音中忽略」守卫之前")
    func graveArmComesBeforeIdleGuard() throws {
        let body = try Self.gravePressedBody(try Self.appModelSource())
        let arm = body.range(of: "echoSwallower.arm(.grave)")
        let guardCall = body.range(of: "graveKeyPostsSpace")
        #expect(arm != nil && guardCall != nil)
        if let arm, let guardCall {
            #expect(
                arm.lowerBound < guardCall.lowerBound,
                """
                echoSwallower.arm(.grave) 排到了 graveKeyPostsSpace 守卫之后。
                录音中误碰这个键会变成「空格不注、「·」照进目标应用」，
                比什么都不做更糟。
                """
            )
        }
    }

    /// 常开的 tap 要跟着遥控器那条路一起起、一起收。
    /// 不收的表现是「tap 活得比它的用途久」——`RemoteKeySuppressor` 为这件事
    /// 崩过四次。
    @Test("吞键器跟着遥控器一起启停")
    func echoSwallowerStartsAndStops() throws {
        let source = try Self.appModelSource()
        #expect(source.contains("echoSwallower.start()"), "startRemote 里没有 echoSwallower.start()。")
        #expect(source.contains("echoSwallower.stop()"), "stopRemote 里没有 echoSwallower.stop()。")
    }

    // MARK: - 遥控器菜单键 → Command+Tab

    /// 与「·」键同型：**两件事都要做**。只发 Command+Tab → 用户同时得到
    /// 「切了应用」和「弹出右键菜单」；只吞键 → 什么都没发生。
    @Test("菜单键既发 Command+Tab，也吞掉原始按键")
    func contextMenuKeyPostsAppSwitchAndSwallows() throws {
        let body = try Self.contextMenuPressedBody(try Self.appModelSource())
        #expect(
            body.contains("echoSwallower.arm(.contextualMenu)"),
            """
            onContextMenuPressed 里没有 echoSwallower.arm(.contextualMenu)。
            系统会照常投递这个键（那就是用户说的「唤醒菜单」），不吞掉的话
            按一下会同时切换应用并弹出右键菜单。
            """
        )
        #expect(
            body.contains("appSwitcher.press()"),
            """
            onContextMenuPressed 里没有 appSwitcher.press()。
            用户要的是「连按能在最近使用列表里一格一格往后翻」，
            那需要 Command 按住跨越多次按键——不是发一次 Command+Tab。
            """
        )
    }

    /// **武装必须是无条件的，且排在听写守卫之前。**
    ///
    /// 排在守卫之后的后果：听写中误碰这个键，应用不切、右键菜单照弹——
    /// 正好是最坏的一档。正确的结果是什么都没发生。
    @Test("菜单键的武装排在「听写中忽略」守卫之前")
    func contextMenuArmComesBeforeIdleGuard() throws {
        let body = try Self.contextMenuPressedBody(try Self.appModelSource())
        let arm = body.range(of: "echoSwallower.arm(.contextualMenu)")
        let guardCall = body.range(of: "contextMenuKeyPostsAppSwitch")
        #expect(arm != nil && guardCall != nil)
        if let arm, let guardCall {
            #expect(
                arm.lowerBound < guardCall.lowerBound,
                """
                echoSwallower.arm(.contextualMenu) 排到了守卫之后。
                听写中误碰会变成「应用不切、右键菜单照弹」，比什么都不做更糟。
                """
            )
        }
    }

    /// 日志是这一路唯一的真机判据（PM 不逐项跑清单，验收要能从日志读出来）。
    /// 三条：触发、听写中忽略、以及吞键那一行（在 `RemoteEchoSwallower` 里）。
    @Test("菜单键的两条日志都在")
    func contextMenuLogsBothOutcomes() throws {
        let body = try Self.contextMenuPressedBody(try Self.appModelSource())
        #expect(body.contains("菜单键按下，推进应用切换器"),
                "没有触发日志，真机上「按了没反应」就分不清是没识别还是注入无效")
        #expect(body.contains("菜单键按下，但正在听写，忽略"),
                "听写中被忽略这件事没有日志，用户会以为功能坏了")
    }

    // MARK: - 应用切换器的兜底接线

    /// **「听写中忽略这个键」那个守卫只挡新按键，挡不住一个已经按住的 Command。**
    ///
    /// 失效链：用户按了菜单键 → 在那 0.7 秒里又按语音键开始说话 →
    /// Command 一直按到停手计时器到点为止，期间语音键那一路的按键全变成快捷键。
    ///
    /// 挂在 `onStateChange` 而不是三个 `session.start()` 调用点上：⌥D、遥控器、
    /// 鼠标三条路都汇到这一个回调，逐个去接迟早漏一个（`keySuppressor` 的
    /// Esc 出口就漏过一次）。
    @Test("听写一开始就释放按住的 Command")
    func dictationReleasesHeldCommand() throws {
        let source = try Self.appModelSource()
        // 精确切出 onStateChange 那个闭包：`memberBody` 的结束锚点是下一个
        // 四格缩进的 `///`，在这里会一路吃到几十行之后，断言就形同虚设。
        let start = try #require(
            source.range(of: "session.onStateChange = { [weak self] state in"),
            "找不到 onStateChange 的接线，这个测试的锚点失效了")
        let rest = source[start.upperBound...]
        let end = try #require(
            rest.range(of: "\n        session.onError")?.lowerBound,
            "找不到 onStateChange 的结束锚点")
        let body = String(rest[..<end])
        #expect(
            body.contains("appSwitcher.release(reason: .dictation)"),
            """
            onStateChange 里没有 appSwitcher.release(reason: .dictation)。
            听写开始时按住的 Command 不会被抬起，说话期间的按键全变成快捷键。
            """
        )
        let release = try #require(body.range(of: "appSwitcher.release(reason: .dictation)"))
        let phaseSwitch = try #require(body.range(of: "switch state {"))
        #expect(release.lowerBound < phaseSwitch.lowerBound,
                "释放排到了状态分发之后——中间任何一步 return 都会把这条兜底跳过去")
    }

    /// 兜底之三与之五的接线：失活观察者跟着遥控器一起挂、一起摘，
    /// 摘的时候顺带无条件释放。
    @Test("应用切换器跟着遥控器一起启停")
    func appSwitcherStartsAndStops() throws {
        let source = try Self.appModelSource()
        #expect(source.contains("appSwitcher.start()"),
                "startRemote 里没有 appSwitcher.start()——「应用失活就抬起 Command」那条兜底没挂上。")
        #expect(source.contains("appSwitcher.stop()"),
                "stopRemote 里没有 appSwitcher.stop()——遥控器都停了还可能留着一个按住的 Command。")
    }

    // MARK: - 输入语言接线（Task 10）

    /// 括号配平取函数体：从 `func <名字>` 的起始花括号数到配平为止。
    ///
    /// 与 `memberBody` 分工不同：那个的结束锚点是**下一个成员级 `///`**，
    /// 对紧跟着普通声明（没有文档注释）的函数会一路吃到隔壁；这里按花括号
    /// 配平切一刀，界限是语法的，不依赖邻居长什么样。被扫的这些函数体里
    /// 没有含花括号的字符串字面量，配平不会被字符串骗到。
    static func functionBody(named name: String, in source: String) throws -> String {
        let start = try #require(
            source.range(of: "func \(name)"),
            "找不到 func \(name)，这个测试的锚点失效了")
        let rest = source[start.lowerBound...]
        let open = try #require(rest.firstIndex(of: "{"), "func \(name) 后面没有起始花括号")
        var depth = 0
        var index = open
        while index < rest.endIndex {
            switch rest[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(rest[open...index]) }
            default: break
            }
            index = rest.index(after: index)
        }
        Issue.record("func \(name) 的花括号没配平")
        return ""
    }

    /// 切出 `onStateChange` 的 `.idle` 分支（从 "case .idle:" 到下一个
    /// "case .listening"）。整文件 `contains` 会把声明行也算进去——
    /// `private func rebuildTranscriberForInputLanguage()` 那行声明本身
    /// 就含目标子串，删掉 `.idle` 分支里的调用照样绿（本仓栽过的老坑，
    /// 见 `idleResumesPendingModelAdoption` 的注释）。
    static func idleCaseBody() throws -> String {
        let source = try appModelSource()
        let start = try #require(
            source.range(of: "case .idle:"), "找不到 case .idle:，锚点失效了")
        let rest = source[start.upperBound...]
        let end = try #require(
            rest.range(of: "case .listening"), "找不到 case .listening，锚点失效了")
        return String(rest[..<end.lowerBound])
    }

    /// 换输入语言时，转写、校正、翻译三层都要跟着动——漏任何一层都是
    /// 「菜单显示英文，实际还按中文跑」这一类静默脱节。
    @Test("换输入语言要把校正、翻译、转写三层都带上")
    func inputLanguageChangeRebuildsAndReappliesEverything() throws {
        let body = try Self.functionBody(
            named: "selectInputLanguage", in: try Self.appModelSource())
        #expect(
            body.contains("applyCorrectionPreference()"),
            "selectInputLanguage 里没有 applyCorrectionPreference()——切到外语后校正管线不会被摘掉。")
        #expect(
            body.contains("applyTranslationPreference()"),
            "selectInputLanguage 里没有 applyTranslationPreference()——(input, choice) 矩阵变了翻译层却没重挂。")
        #expect(
            body.contains("rebuildTranscriberForInputLanguage()"),
            "selectInputLanguage 里没有 rebuildTranscriberForInputLanguage()——语言是转写器的构造参数，不重建等于没换。")
    }

    /// onStateChange 的 .idle 分支必须补做被推迟的转写器重建——
    /// 与校正/翻译/模型换用三条补挂并排。缺了它的表现：录音途中换的
    /// 输入语言永远不生效，而菜单已经写着新语言。
    @Test("会话回到 idle 时补做被推迟的输入语言重建")
    func idleBranchRepaysPendingInputLanguageRebuild() throws {
        let body = try Self.idleCaseBody()
        // 断言的是**调用**在分支里，不是记账变量的名字——只查名字的话，
        // `if pending { }` 这种空 if 体照样绿（正是「看着在检查其实什么都
        // 没检查」的形状）。
        #expect(
            body.contains("rebuildTranscriberForInputLanguage()"),
            """
            onStateChange 的 .idle 分支里没有 rebuildTranscriberForInputLanguage() 调用。
            录音途中换的输入语言会被 canSwitchModel 挡下（挡是对的），
            但此后再也没有人重试——转写永远停在旧语言。
            """
        )
    }

    /// 校正的机制是拼音同音字，对拉丁语种无意义——不是「以后补」，是
    /// 「不适用」。守的是 makeCorrectionPipeline 里那道语言门。
    @Test("校正管线只在输入中文时构造")
    func correctionPipelineIsChineseOnly() throws {
        let body = try Self.functionBody(
            named: "makeCorrectionPipeline", in: try Self.appModelSource())
        #expect(
            body.contains("== .chinese"),
            """
            makeCorrectionPipeline 里没有输入语言守卫。
            拼音同音字校正对拉丁语种毫无意义，非中文输入必须摘除管线，
            否则英文转写会被中文校正模型改得面目全非。
            """
        )
    }

    /// 旧键 `translation.outputLanguage` 的 "zh" 含义是「不翻译」，
    /// 迁移写好了却没人调的话，老用户升级后偏好静默丢失。
    @Test("旧偏好迁移接上了，且排在构造协调器之前")
    func legacyPreferenceMigrationIsWiredAtInit() throws {
        let source = try Self.appModelSource()
        let migration = try #require(
            source.range(of: "migrateLegacyOutputLanguageIfNeeded()"),
            """
            AppModel 里没有 migrateLegacyOutputLanguageIfNeeded() 的调用。
            迁移函数写好了但没人调等于没写——老用户的输出语言设置会被
            静默丢弃（幸好新键的默认值恰是「不翻译」，但那是运气不是设计）。
            """
        )
        let coordinator = try #require(
            source.range(of: "TranslationAttachmentCoordinator("),
            "找不到 TranslationAttachmentCoordinator( 构造，锚点失效了")
        // 位置断言：协调器构造那一刻读的必须已经是迁移后的新键。
        // 只查「调用存在」的话，把迁移挪到协调器之后照样绿——那一轮启动
        // 协调器会按默认值挂载，老用户的偏好等到下次启动才生效。
        #expect(
            migration.lowerBound < coordinator.lowerBound,
            "迁移调用排在了构造协调器之后——协调器第一次 apply() 读到的是没迁移的键。")
    }

    /// 补做不能只挂在「会话回到 idle」上：`canSwitchModel` 除会话状态外还含
    /// `loadingModelName == nil` 这个**非会话**条件。切 zh→en 起飞 rebuild
    /// （prepare 实测 14–125 秒），窗口内再切 en→es 被闸挡下记账；加载结束
    /// 只清 loadingModelName、没有任何会话事件——.idle 分支永远等不到偿还，
    /// 菜单 es、引擎 en，下一次听写整段按英文转写。两个加载 Task（重建自身
    /// 与 selectModel）的末尾必须各自补做一次。
    @Test("两个加载 Task 的末尾都补做被推迟的输入语言重建")
    func loadingTasksRepayPendingInputLanguageRebuild() throws {
        let source = try Self.appModelSource()
        let repay =
            "if self?.inputLanguageRebuildPending == true { self?.rebuildTranscriberForInputLanguage() }"
        let rebuild = try Self.functionBody(
            named: "rebuildTranscriberForInputLanguage", in: source)
        #expect(
            rebuild.contains(repay),
            """
            rebuildTranscriberForInputLanguage 的 Task 末尾没有补做。
            重建途中又换一次语言的那笔账只有这里能偿还——loadingModelName
            清掉时没有会话事件跟来。
            """
        )
        let select = try Self.functionBody(
            named: "selectModel(_ model: ModelDescriptor)", in: source)
        #expect(
            select.contains(repay),
            """
            selectModel 的 Task 末尾没有补做。
            换模型途中切了输入语言的那笔账在这里偿还：记账那一刻
            canSwitchModel 因 loadingModelName 非空而为 false，
            而这不是会话条件，.idle 分支等不到偿还事件。
            """
        )
    }
}
