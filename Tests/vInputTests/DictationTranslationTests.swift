import Foundation
import Testing

@testable import vInput

/// 把「上限」改回「上线」的假校正器，顺带记下自己被调到的时刻。
///
/// 素材不是随手挑的：「上限 / 上线」是同音错字，正是「校正必须在翻译之前」
/// 那条规则的成因——译过去就是 upper limit，译文里再也看不出这是个错字。
private final class OrderRecordingCorrector: Corrector, @unchecked Sendable {
    private let log: CallOrderLog?

    init(log: CallOrderLog? = nil) {
        self.log = log
    }

    func prepare() async throws {}

    func edits(for text: String) async throws -> [CorrectionEdit] {
        await log?.record("correct")
        return [CorrectionEdit(original: "上限", replacement: "上线")]
    }
}

@Suite("会话中的翻译")
@MainActor
struct DictationTranslationTests {
    /// 转写出来的中文原文。**「上限」是「上线」的同音错字。**
    private static let transcript = "今天下午上限。"
    /// 校正之后的中文。
    private static let corrected = "今天下午上线。"
    /// 一条能过闸门的译文。
    ///
    /// **不能用「We go live today」这种不带句末标点的**：闸门的主信号是
    /// 「原文有句末标点而译文没有」，那样的译文会被判成 `.truncated`，
    /// 于是「成功路径」这条用例测的其实是闸门拦截。计划正文给的
    /// `"Meeting today"` 正是那个形态（`TranslationPipelineTests` 已经在
    /// 同一个坑里栽过一次）。
    ///
    /// 本串是先跑一遍量出来的，不是手算的：长度比 3.5（阈值 1.1）、
    /// 残留汉字 0、中文标点 0、原文与译文都以句末标点收尾 → `.pass`。
    private static let translated = "We go live this afternoon."

    /// 组装一套全替身的会话。**沿用 `DictationSessionTests.makeSession` 的形状**
    /// （`FakeAudioSource` / `FakeTranscriber` / `SpySink` / `TargetAppGuard`
    /// 都是现成的），只多一个可选的校正器。
    ///
    /// 翻译流水线不走构造器：`DictationSession` 只提供 `attachTranslation`，
    /// 而那个入口的时机语义（只在 idle 时接受）本身就是本文件要守的东西。
    private func makeSession(
        transcript: String = DictationTranslationTests.transcript,
        corrector: Corrector? = nil,
        sinkError: Error? = nil,
        rescue: SpyRescue? = nil
    ) -> (DictationSession, FakeAudioSource, SpySink) {
        let source = FakeAudioSource()
        let transcriber = FakeTranscriber()
        transcriber.result = transcript
        let sink = SpySink()
        sink.error = sinkError
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }

        let session = DictationSession(
            audioSource: source,
            transcriber: transcriber,
            sink: sink,
            targetGuard: guardian,
            correctionPipeline: corrector.map { CorrectionPipeline(corrector: $0) },
            rescue: rescue
        )
        return (session, source, sink)
    }

    private func runSession(_ session: DictationSession, _ source: FakeAudioSource) async throws {
        try await session.start()
        source.emit(Array(repeating: 0.1, count: 16_000))
        await session.finish()
    }

    private func pipeline(_ output: String, log: CallOrderLog? = nil) -> TranslationPipeline {
        // **闸门与超时都用默认值。** 两个数各自有实测支撑（闸门 1.1、超时 8 秒）
        // 且各自有测试守着，在这里硬写一个数等于绕过那两条守卫，而且不会有人
        // 发现——计划正文里写的 `minimumLengthRatio: 0.3` / `timeout: .seconds(30)`
        // 正是那个形态。
        TranslationPipeline(
            translator: FakeTranslator(.succeed(output), log: log),
            source: .chinese, target: .english)
    }

    // MARK: - 顺序：校正在前，翻译在后

    /// **这条钉的是真实调用顺序，不是那个静态数组。**
    ///
    /// `allCasesInPipelineOrder` 是手写的：把 `process()` 里校正与翻译两段
    /// 代码对调，它一个字都不用改，断言照样全绿——那正是本仓库栽过七次的
    /// 「看着在检查什么，其实什么都没检查」。所以这里换成两条行为证据：
    ///
    /// ① 校正器与翻译器各自记下被调到的时刻，断言的是先后本身；
    /// ② 更硬的一条——**翻译器收到的是校正之后的中文**。顺序对调的话它收到的
    ///    是「今天下午上限。」，而那恰恰是这条规则要防的事本身：同音错字被译
    ///    过去固化成 upper limit，译文里再也看不出来。
    @Test("校正确实先于翻译发生")
    func stateOrderPutsCorrectionFirst() async throws {
        let log = CallOrderLog()
        let translator = FakeTranslator(.succeed(Self.translated), log: log)
        let (session, source, sink) = makeSession(corrector: OrderRecordingCorrector(log: log))
        session.attachTranslation(
            TranslationPipeline(translator: translator, source: .chinese, target: .english))

        try await runSession(session, source)

        #expect(await log.calls == ["correct", "translate"])
        #expect(
            await translator.receivedTexts == [Self.corrected],
            "翻译器必须拿到校正后的中文，否则同音错字会被译文固化")
        #expect(sink.received == [Self.translated])
    }

    /// 让 `allCasesInPipelineOrder` 有牙口：实测到的状态序列必须与它同序。
    ///
    /// 单独一条而不是并进上面：上面守的是「谁先被调用」，这条守的是「HUD 看到
    /// 的状态序列与声明的一致」。把数组里 `.correcting` 与 `.translating` 对调，
    /// 这条红；把 `process()` 里两段代码对调，两条一起红。
    @Test("实测状态序列与 allCasesInPipelineOrder 同序")
    func observedStatesFollowDeclaredOrder() async throws {
        let (session, source, _) = makeSession(corrector: OrderRecordingCorrector())
        session.attachTranslation(pipeline(Self.translated))
        var observed: [DictationSession.State] = []
        session.onStateChange = { observed.append($0) }

        try await runSession(session, source)

        #expect(observed.last == .idle, "会话总要回到 idle，实测 \(observed)")
        // 收尾那次回 idle 摘掉之后，剩下的应当逐格对上声明的顺序。
        #expect(
            Array(observed.dropLast())
                == DictationSession.State.allCasesInPipelineOrder.filter { $0 != .idle },
            "实测 \(observed)")
    }

    // MARK: - 目标语言决定走不走翻译

    /// Task 6 起会话侧只认「有没有管线」：目标是中文＝协调器把管线摘掉
    /// （`TranslationAttachment.detach`），会话拿到的是 nil。原先这条断言的
    /// 「target 传进了会话、目标是中文就不翻译」，其意图改由「管线自带
    /// (源, 目标)、中文那格压根不存在管线」承接——协调器侧由
    /// `TranslationAttachmentCoordinatorTests` 的中文格与 `.detach` 用例守着，
    /// 管线侧由 `TranslationPipelineTests.sameSourceAndTargetPassesThrough`
    /// 兜底。
    @Test("没有翻译管线时不进 .translating，注入中文原文")
    func noPipelineSkipsTranslatingState() async throws {
        let (session, source, sink) = makeSession()
        session.attachTranslation(nil)
        var observed: [DictationSession.State] = []
        session.onStateChange = { observed.append($0) }
        var annotationCalls = 0
        session.onTranslation = { _ in annotationCalls += 1 }

        try await runSession(session, source)

        #expect(!observed.contains(.translating), "实测序列 \(observed)")
        #expect(sink.received == [Self.transcript])
        // 用户没要翻译，屏幕上就不该冒出任何与翻译有关的字——与 `onCorrection`
        // 「校正关闭时一次都不回调」同一条规矩。
        #expect(annotationCalls == 0)
    }

    @Test("目标是外语时进 .translating，注入译文")
    func foreignTargetEntersTranslatingState() async throws {
        let (session, source, sink) = makeSession()
        session.attachTranslation(pipeline(Self.translated))
        var observed: [DictationSession.State] = []
        session.onStateChange = { observed.append($0) }
        var annotations: [TranslationAnnotation?] = []
        session.onTranslation = { annotations.append($0) }
        var delivered: [String] = []
        session.onText = { delivered.append($0) }

        try await runSession(session, source)

        #expect(observed.contains(.translating), "实测序列 \(observed)")
        #expect(sink.received == [Self.translated])
        // `onText` 送出的必须也是译文：`AppModel` 拿它写日志、填「上次结果」，
        // 送中文进去的话日志与菜单显示的和屏幕上出现的是两样东西。
        #expect(delivered == [Self.translated])
        // 正常译出时回调**仍要发生一次**，值是 nil（HUD 什么都不显示）。
        // 把 `onTranslation?(result.annotation)` 整行删掉时这条红。
        #expect(annotations == [nil])
    }

    /// 规则二在翻译这一层的形态：注入失败时进剪贴板的必须是**译文**。
    ///
    /// 救成中文原文的话这次翻译白做了——用户粘出来的是一段他并不想要的中文，
    /// 而他甚至看不出这是兜底路径救错了东西。
    @Test("注入失败时交给兜底的是译文，不是中文原文")
    func rescueCarriesTheTranslation() async throws {
        let rescue = SpyRescue()
        let (session, source, _) = makeSession(
            sinkError: TextSinkError.accessibilityDenied, rescue: rescue)
        session.attachTranslation(pipeline(Self.translated))

        try await runSession(session, source)

        #expect(rescue.rescued.map(\.text) == [Self.translated])
    }

    // MARK: - 规则二：翻译失败不得让用户说的话消失

    /// 翻译器把中文原样吐回来 ＝ 整段没译。实测标注是
    /// `.rejected(.residualHan(count: 6))`（「今天下午上限」6 个汉字）。
    ///
    /// **钉到具体的 rejection 而不是只断言「有标注」**：把标注换成任何一格
    /// 别的，用户看到的解释就错了，而「有标注」这种断言分不出来。
    @Test("翻译被闸门拦下时注入中文原文并带标注")
    func rejectedTranslationFallsBackToChinese() async throws {
        let (session, source, sink) = makeSession()
        session.attachTranslation(pipeline(Self.transcript))
        var annotations: [TranslationAnnotation?] = []
        session.onTranslation = { annotations.append($0) }
        var errors: [Error] = []
        session.onError = { errors.append($0) }

        try await runSession(session, source)

        #expect(sink.received == [Self.transcript])
        #expect(annotations == [.rejected(.residualHan(count: 6))])
        // 翻译失败不是会话错误：用户拿到了文字（中文原文），没有任何需要他
        // 处理的事——与「校正失败不上报为会话错误」同一取向。
        #expect(errors.isEmpty)
    }

    // MARK: - 说话途中换语言

    /// **一次会话内规则不变。** 用户是在他当时选的语言下开口的；说到一半改
    /// 主意就把这句话改译成别的，等于拿他说完之后才做的选择去处理他说完之前
    /// 的话——而这一句会被直接注进他即将发出的窗口。与校正那边同款
    /// （`CorrectionPendingApplyTests`），`AppModel` 侧靠
    /// `translationApplyPending` 在回到 idle 后补挂。
    @Test("说话途中挂上翻译：本次仍出中文，下一轮才生效")
    func attachMidSessionAppliesNextRound() async throws {
        let (session, source, sink) = makeSession()

        try await session.start()
        session.attachTranslation(pipeline(Self.translated))
        source.emit(Array(repeating: 0.1, count: 16_000))
        await session.finish()
        #expect(sink.received == [Self.transcript], "这一句是冲着中文说的，就该出中文")

        // 回到 idle 后补挂，下一轮生效。
        session.attachTranslation(pipeline(Self.translated))
        try await runSession(session, source)
        #expect(sink.received == [Self.transcript, Self.translated], "补挂后应当生效")
    }

    /// 反方向同理——**摘掉也要等到下一轮。**
    ///
    /// 单独一条是因为它守的是另一格：只在「挂上」那一侧判 idle、摘的时候
    /// 立刻生效，会让用户说到一半切回中文时这句话半路改主意。
    @Test("说话途中切回中文：本次仍出译文，下一轮才停")
    func detachMidSessionAppliesNextRound() async throws {
        let (session, source, sink) = makeSession()
        session.attachTranslation(pipeline(Self.translated))

        try await session.start()
        session.attachTranslation(nil)
        source.emit(Array(repeating: 0.1, count: 16_000))
        await session.finish()
        #expect(sink.received == [Self.translated], "这一句是冲着英文说的，就该出英文")

        session.attachTranslation(nil)
        try await runSession(session, source)
        #expect(sink.received == [Self.translated, Self.transcript], "切回中文应当在下一轮生效")
    }
}
