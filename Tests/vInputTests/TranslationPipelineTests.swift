import Foundation
import Testing

@testable import vInput

@Suite("翻译流水线")
struct TranslationPipelineTests {
    /// 全部用例共用的中文原文。以句号收尾（截断判据的前置条件），
    /// 8 个显著字符。
    private static let source = "今天下午三点开会。"

    /// 一条能过闸门的译文。
    ///
    /// **不能用「Meeting today」这种不带句末标点的**：闸门的主信号是
    /// 「原文有句末标点而译文没有」，那样的译文会被判成 `.truncated`，
    /// 于是「成功路径」这条用例测的其实是闸门拦截。计划正文里给的正是
    /// 那个串，实测下来不成立，改成实测过的这一条（与
    /// `TranslationGateTests.cleanTranslationPasses` 同一对素材）。
    private static let translated = "Meeting at 3pm today."

    // MARK: - 两条「压根不该调翻译器」的短路

    @Test("目标是中文时原样返回，不调翻译器")
    func chineseTargetSkipsTranslator() async {
        let fake = FakeTranslator(.succeed(Self.translated))
        let pipeline = TranslationPipeline(translator: fake)

        let result = await pipeline.translate(Self.source, to: .chinese)

        #expect(result.text == Self.source)
        #expect(result.annotation == nil)
        // 目标是中文时连翻译器都不该碰——它可能还要为此加载模型。
        #expect(await fake.callCount == 0)
    }

    @Test("空文本不调翻译器")
    func blankTextSkipsTranslator() async {
        let fake = FakeTranslator(.succeed("whatever"))
        let pipeline = TranslationPipeline(translator: fake)

        let result = await pipeline.translate("   ", to: .english)

        #expect(result.text == "   ")
        // 用户没说话，没什么可提示的——标注是给「有话但没译成」用的。
        #expect(result.annotation == nil)
        #expect(await fake.callCount == 0)
    }

    // MARK: - 正常路径

    @Test("成功时返回译文")
    func returnsTranslation() async {
        let pipeline = TranslationPipeline(translator: FakeTranslator(.succeed(Self.translated)))

        let result = await pipeline.translate(Self.source, to: .english)

        #expect(result.text == Self.translated)
        // 正常译出时 HUD 什么都不显示。
        #expect(result.annotation == nil)
    }

    /// **数词改写真的接上了**——「值对了」和「接上了」是两件事
    /// （M8 攒的教训），`RewriteAsDigitsTests` 只证明前者，这条证明后者：
    /// 翻译器收到的必须是改写后的文本。改写本身的规则在那边测，
    /// 这里只挑一条有数词的。
    @Test("翻译器收到的是数词改写后的文本")
    func translatorReceivesRewrittenNumerals() async {
        let fake = FakeTranslator(.succeed("Contract amount is 4600000, paid in three parts."))
        let pipeline = TranslationPipeline(translator: fake)

        let result = await pipeline.translate("合同金额四百六十万，分三期付款。", to: .english)

        #expect(await fake.receivedTexts == ["合同金额4600000，分三期付款。"])
        #expect(result.text == "Contract amount is 4600000, paid in three parts.")
        #expect(result.annotation == nil)
    }

    /// 失败路径退回的必须是**未改写的原文**——用户要看到的是他说的话，
    /// 不是「合同金额4600000」这种半成品。
    ///
    /// **三条返回路径各守一条，缺一不可**（2026-08-20 QA 变异实测：只有
    /// 引擎错误这条被守着时，把闸门拒绝与超时两处的 `text` 改成
    /// `rewritten`，全量测试照样全绿——其余用例的素材不含数词，
    /// `rewritten == text`，变异不可见）。所以这三条的素材都必须带数词。
    @Test("引擎失败时退回的是未改写的中文原文")
    func failureFallsBackToUnrewrittenSource() async {
        let source = "合同金额四百六十万，分三期付款。"
        let pipeline = TranslationPipeline(
            translator: FakeTranslator(.fail(.engineFailed("boom"))))

        let result = await pipeline.translate(source, to: .english)

        #expect(result.text == source)
        #expect(result.annotation == .failed("boom"))
    }

    /// 同上：闸门拒绝那条。译文整段是中文（残留汉字 14 个）必被拦下，
    /// 拦下后拿回的必须是带数词的原话。
    @Test("闸门拦下时退回的是未改写的中文原文")
    func gateRejectFallsBackToUnrewrittenSource() async {
        let source = "合同金额四百六十万，分三期付款。"
        let pipeline = TranslationPipeline(
            translator: FakeTranslator(.succeed("合同金额四百六十万，分三期付款。")))

        let result = await pipeline.translate(source, to: .english)

        #expect(result.text == source)
        #expect(result.annotation == .rejected(.residualHan(count: 14)))
    }

    /// 同上：超时那条。
    @Test("超时时退回的是未改写的中文原文")
    func timeoutFallsBackToUnrewrittenSource() async {
        let source = "合同金额四百六十万，分三期付款。"
        let pipeline = TranslationPipeline(
            translator: FakeTranslator(.hang), timeout: .milliseconds(50))

        let result = await pipeline.translate(source, to: .english)

        #expect(result.text == source)
        #expect(result.annotation == .timedOut)
    }

    // MARK: - 失败路径，全部退回中文原文

    /// 闸门那一格的守卫。素材是「整段没译回来」——译文就是原文，
    /// 残留汉字 8 个，`residualHan` 亮。
    ///
    /// **钉到具体的 rejection 而不是只断言「被拦了」**：把闸门检查整个跳过
    /// （永远 `.pass`）时，本用例会因为 `text` 变成那段中文而红；而钉住
    /// `residualHan(count: 8)` 还额外保证了拦它的是这一条判据、
    /// 不是长度比或截断（那两条的成因不同，改阈值时得分得开）。
    ///
    /// 用**生产默认闸门**而不是显式阈值：这条路径与长度比无关，
    /// 而流水线该验的是「它接的是真的那道闸门」。
    @Test("闸门拦下时退回中文原文并标注")
    func fallsBackWhenGateRejects() async {
        let pipeline = TranslationPipeline(translator: FakeTranslator(.succeed(Self.source)))

        let result = await pipeline.translate(Self.source, to: .english)

        #expect(result.text == Self.source)
        #expect(result.annotation == .rejected(.residualHan(count: 8)))
    }

    /// 超时那条。**故意用 `.hang`（睡 600 秒）**：生产实现刻意不取消
    /// worker（取消省不下 GPU，见 `withTimeout` 的注释），所以这条用例
    /// 同时也是「不取消也不会把测试挂住」的证据——它必须在毫秒级返回。
    @Test("超时时退回中文原文并标注")
    func fallsBackOnTimeout() async {
        let pipeline = TranslationPipeline(
            translator: FakeTranslator(.hang), timeout: .milliseconds(50))

        let started = ContinuousClock.now
        let result = await pipeline.translate(Self.source, to: .english)
        let elapsed = ContinuousClock.now - started

        #expect(result.text == Self.source)
        #expect(result.annotation == .timedOut)
        // 上界远小于那 600 秒：超时真的没等 worker。
        #expect(elapsed < .seconds(5), "超时后不该等着 worker，实测耗时 \(elapsed)")
    }

    /// **「不在这里等加载」这条规则的守卫。**
    ///
    /// 墙钟断言一条是不够的：`FakeTranslator.prepare()` 是空实现，
    /// 把生产代码改成「先 `await translator.prepare()` 再继续」时它照样
    /// 毫秒级返回，1 秒的上界抓不到。真正抓得住的是 `prepareCallCount == 0`
    /// ——注入路径上一次加载都不许发起。两条一起留着：计数管「有没有调」，
    /// 墙钟管「有没有在别处干等」。
    @Test("模型未就绪时立即退回，不等加载")
    func doesNotWaitForModelLoad() async {
        let fake = FakeTranslator(.succeed(Self.translated), ready: false)
        let pipeline = TranslationPipeline(translator: fake)

        let started = ContinuousClock.now
        let result = await pipeline.translate(Self.source, to: .english)
        let elapsed = ContinuousClock.now - started

        #expect(result.text == Self.source)
        #expect(result.annotation == .modelLoading)
        #expect(await fake.prepareCallCount == 0, "注入路径上不许发起加载")
        #expect(await fake.callCount == 0, "未就绪时不该硬着头皮去推理")
        #expect(elapsed < .seconds(1), "实测耗时 \(elapsed)")
    }

    @Test("引擎报错时退回中文原文")
    func fallsBackWhenEngineFails() async {
        let pipeline = TranslationPipeline(translator: FakeTranslator(.fail(.engineFailed("boom"))))

        let result = await pipeline.translate(Self.source, to: .english)

        #expect(result.text == Self.source)
        // 消息原样带出来给日志用；HUD 不显示它（见 `hudLabel`）。
        #expect(result.annotation == .failed("boom"))
    }

    /// **缺 key 与引擎故障必须分得开。** 把 `.missingAPIKey` 并进 `.failed`
    /// 时这条红。分开的理由不是洁癖：缺 key 用户有明确的动作可做（去配 key），
    /// 引擎故障没有，两句话不一样。
    @Test("缺 API key 时的标注与引擎错误分开")
    func missingAPIKeyIsItsOwnAnnotation() async {
        let pipeline = TranslationPipeline(translator: FakeTranslator(.fail(.missingAPIKey)))

        let result = await pipeline.translate(Self.source, to: .english)

        #expect(result.text == Self.source)
        #expect(result.annotation == .missingAPIKey)
    }

    /// 引擎自报「模型没就绪」——`isReady` 与 `translate` 之间模型被卸掉
    /// 就是这个形态。对用户是同一件事：等一下再说。
    @Test("引擎自报模型未就绪时落进「加载中」")
    func engineReportedNotReadyMapsToModelLoading() async {
        let pipeline = TranslationPipeline(translator: FakeTranslator(.fail(.modelNotReady)))

        #expect(await pipeline.translate(Self.source, to: .english).annotation == .modelLoading)
    }

    /// 引擎自报超时（云端请求超时）与我们的预算判的是同一件事。
    @Test("引擎自报超时落进「超时」")
    func engineReportedTimeoutMapsToTimedOut() async {
        let pipeline = TranslationPipeline(translator: FakeTranslator(.fail(.timedOut)))

        #expect(await pipeline.translate(Self.source, to: .english).annotation == .timedOut)
    }

    /// **兜底那条 catch 的守卫。** 只 catch `TranslatorError` 的话，
    /// 云端实现漏出来的 URLError 会顺着 async 抛给调用方——而本类型对外
    /// 的承诺是「不抛错」。把兜底删掉时这条编译不过（函数得 throws），
    /// 改成 `catch {}` 吞掉时也红。
    @Test("非 TranslatorError 的错误同样退回中文原文")
    func fallsBackOnUnknownError() async {
        let pipeline = TranslationPipeline(translator: FakeTranslator(.failOther))

        let result = await pipeline.translate(Self.source, to: .english)

        #expect(result.text == Self.source)
        guard case .failed(let message) = result.annotation else {
            Issue.record("未知错误应当落进 .failed，实际是 \(String(describing: result.annotation))")
            return
        }
        #expect(message.contains("OtherError"))
    }

    // MARK: - 预热

    @Test("预热转交给翻译器")
    func prepareForwardsToTranslator() async throws {
        let fake = FakeTranslator(.succeed(Self.translated))
        let pipeline = TranslationPipeline(translator: fake)

        try await pipeline.prepareTranslator()

        #expect(await fake.prepareCallCount == 1)
    }

    /// 预热失败要**抛出去**而不是吞掉：调用方（挂载处）要据此写日志、
    /// 提示用户。这与 `translate` 的「不抛错」不矛盾——那条是注入路径上的
    /// 承诺，预热不在注入路径上。
    @Test("预热失败抛给调用方")
    func prepareRethrows() async {
        let pipeline = TranslationPipeline(
            translator: FakeTranslator(.succeed(Self.translated), prepareError: .modelNotReady))

        await #expect(throws: TranslatorError.modelNotReady) {
            try await pipeline.prepareTranslator()
        }
    }

    // MARK: - 超时预算这个数

    /// **8 秒是量出来的，得有人守着。**
    ///
    /// M8 第 0 步实测：`qwen3-4b-instruct-2507-4bit` 单条翻译最长 4.9 秒
    /// （德语 10 条），英 / 西 26 条上最长 2.9 / 4.3 秒。
    ///
    /// 下界钉住「比实测最慢的那条还长」——低于它就是在给正常输入判超时。
    /// 上界不是形式：`ModelContainer.perform` 串行，跑飞的那次会挡住下一次
    /// 推理（取消传不进 MLX，Task 8 实测 8/8），预算越长挡得越久。
    /// 计划原本写的 30 秒会让下一句话最多干等半分钟。
    @Test("默认超时钉在 8 秒")
    func defaultTimeoutIsPinned() {
        #expect(TranslationPipeline.defaultTimeout == .seconds(8))
        #expect(TranslationPipeline.defaultTimeout > .milliseconds(4900), "得比实测最慢的那条长")
        #expect(TranslationPipeline.defaultTimeout < .seconds(12), "串行队列会被跑飞的那次占住")
    }

    /// 光钉常量不够：声明 8 秒、构造器里却填 30，没有任何行为用例会红。
    @Test("默认超时真的接到了构造器上")
    func defaultTimeoutIsWiredIntoInit() {
        #expect(
            TranslationPipeline(translator: FakeTranslator(.hang)).timeout
                == TranslationPipeline.defaultTimeout)
    }
}

/// 标注的 HUD 文案。
///
/// **`!hudLabel.isEmpty` 这种断言保护不了任何东西**——把所有文案改成
/// `"x"` 它照样全绿。真正的风险有三个，下面三条用例各钉一个：
/// ①「加了一格却忘了配文案」②「两处文案漂移」③「文案退化成看不出区别的
/// 一句话」。
@Suite("翻译标注的 HUD 文案")
struct TranslationAnnotationLabelTests {
    /// 每个 case 的样本。
    ///
    /// **「加了一格」这件事测试代码看不见**——没有一个值就没法反射出
    /// 「存在这么一格」，`TranslationRejection` 带关联值也没法 `CaseIterable`。
    /// 唯一能观测到它的是编译器，所以覆盖完整性交给下面那个穷尽 switch：
    /// 加一格时 `exhaustivenessGuard` 编译不过，编译错误就落在这张样本表
    /// 旁边，人被迫回来往 `rejections` / `annotations` 里补一个样本。
    /// 生产侧的 `hudLabel` 同样是穷尽 switch（无 `default`），所以「忘了配
    /// 文案」在那边也是编译错误——两道都靠编译器，不靠人记得。
    private static let rejections: [TranslationRejection] = [
        .residualHan(count: 2),
        .chinesePunctuation(count: 1),
        .truncated,
        .tooShort(ratio: 0.4),
    ]

    /// 非 private：`TranslationAnnotationTests` 复用同一份样本表。
    /// 两处各写一份的话，加一格时补了这边忘了那边——而那正是这张表要防的事。
    static let annotations: [TranslationAnnotation] =
        [
            .modelLoading, .timedOut, .failed("boom"), .missingAPIKey, .missingLocalModel,
            .locationNotSupported,
        ]
        + rejections.map { .rejected($0) }

    /// 只为编译期存在：两个 switch 都不写 `default`，任一枚举加一格就编译不过。
    private static func exhaustivenessGuard() {
        for rejection in rejections {
            switch rejection {
            case .residualHan, .chinesePunctuation, .truncated, .tooShort: break
            }
        }
        for annotation in annotations {
            switch annotation {
            case .modelLoading, .timedOut, .failed, .missingAPIKey, .missingLocalModel,
                .locationNotSupported, .rejected:
                break
            }
        }
    }

    /// ③ 文案不能退化：**每一条都得说清「注入的是中文原文」**。
    ///
    /// 这五条路径注入的都是中文，而用户选的是外语——屏幕上出现中文本身
    /// 就是要解释的那件事。把文案改成 `"x"`、或者改成一句含糊的
    /// 「翻译失败」，这条就红。
    @Test("每条文案都说清了「注入的是中文原文」")
    func everyLabelExplainsTheChineseFallback() {
        Self.exhaustivenessGuard()
        for annotation in Self.annotations {
            #expect(
                annotation.hudLabel.contains("中文原文"),
                "\(annotation) 的文案没说清注入的是中文：\(annotation.hudLabel)")
        }
    }

    /// ③ 之二：八条文案两两不同。
    ///
    /// 「都改成 x」「新格子随手抄了隔壁那句」都会在这里撞上。
    @Test("每条文案互不相同")
    func labelsAreAllDistinct() {
        let labels = Self.annotations.map(\.hudLabel)
        #expect(Set(labels).count == labels.count, "有重复文案：\(labels)")
    }

    /// ② **两处文案漂移的守卫。**
    ///
    /// `.rejected` 那一格必须**委托**给 `TranslationRejection.hudLabel`，
    /// 不能另抄一套：日志里记的是 rejection 本身，两边一漂就成了
    /// 「HUD 说的和日志说的不一样」，很难查。
    @Test("闸门那格的文案直接委托给 TranslationRejection")
    func rejectedDelegatesToRejectionLabel() {
        for rejection in Self.rejections {
            #expect(TranslationAnnotation.rejected(rejection).hudLabel == rejection.hudLabel)
        }
    }

    /// 三条「用户能据此做点什么」的信息不许丢。
    ///
    /// 这三格分开存在的全部理由就是这三句话不一样——`missingAPIKey` 若不
    /// 提 API key，它与 `failed` 就没有区别，那就该并成一格。
    @Test("能行动的那几条文案带着行动线索")
    func actionableLabelsCarryTheirCue() {
        #expect(TranslationAnnotation.modelLoading.hudLabel.contains("加载"))
        #expect(TranslationAnnotation.timedOut.hudLabel.contains("超时"))
        #expect(TranslationAnnotation.missingAPIKey.hudLabel.contains("API key"))
    }

    /// 引擎的错误串只进日志，不进 HUD：那是 MLX 的内部描述，
    /// 对用户没有意义，还会把 HUD 撑到几行。
    @Test("引擎错误串不出现在 HUD 上")
    func engineMessageStaysOutOfTheHUD() {
        #expect(TranslationAnnotation.failed("mlx: rank mismatch").hudLabel.contains("mlx") == false)
    }
}
