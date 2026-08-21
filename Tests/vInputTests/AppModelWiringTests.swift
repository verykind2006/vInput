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
    @Test("换输出语言时缺模型要当场弹 HUD")
    func selectingOutputLanguageWarnsWhenModelMissing() throws {
        let body = try Self.memberBody(
            try Self.appModelSource(),
            startingAt: "func selectOutputLanguage(_ target: TranslationTarget) {")
        #expect(
            body.contains("if translationModelMissing"),
            """
            selectOutputLanguage 里没有「缺模型目录就提示」的判断。
            菜单当场就关了，用户这一刻唯一看得见的反馈就是 HUD。
            """
        )
        // 文案取自 `TranslationAnnotation`，不另写一句——「翻译为什么没生效」
        // 只该有一处措辞。写死一个字符串字面量时这条会红。
        #expect(
            body.contains("showHUDNotice(TranslationAnnotation.missingLocalModel.hudLabel)"),
            """
            selectOutputLanguage 里没有 showHUDNotice(
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

    // MARK: - 遥控器「·」键 → 空格

    /// 取 `hidListener.onGravePressed` 那个闭包的源码窗口。
    static func gravePressedBody(_ source: String) throws -> String {
        let start = try #require(
            source.range(of: "hidListener.onGravePressed = {"),
            "找不到 onGravePressed 的接线，这个测试的锚点失效了"
        )
        // 闭包本体十几行；到下一个 `hidListener.` 或 `graveSwallower.start()` 为止。
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n        hidListener.start()")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// 这个键要做的是**两件事**，只做一件都不合格：
    /// 只注空格 → 用户同时得到「·」和一个空格；只吞键 → 什么都没发生。
    @Test("「·」键既注入空格，也吞掉原始按键")
    func graveKeyPostsSpaceAndSwallows() throws {
        let body = try Self.gravePressedBody(try Self.appModelSource())
        #expect(
            body.contains("graveSwallower.arm()"),
            """
            onGravePressed 里没有 graveSwallower.arm()。
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
        let arm = body.range(of: "graveSwallower.arm()")
        let guardCall = body.range(of: "graveKeyPostsSpace")
        #expect(arm != nil && guardCall != nil)
        if let arm, let guardCall {
            #expect(
                arm.lowerBound < guardCall.lowerBound,
                """
                graveSwallower.arm() 排到了 graveKeyPostsSpace 守卫之后。
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
    func graveSwallowerStartsAndStops() throws {
        let source = try Self.appModelSource()
        #expect(source.contains("graveSwallower.start()"), "startRemote 里没有 graveSwallower.start()。")
        #expect(source.contains("graveSwallower.stop()"), "stopRemote 里没有 graveSwallower.stop()。")
    }
}
