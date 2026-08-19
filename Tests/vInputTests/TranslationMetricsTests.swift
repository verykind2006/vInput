import Foundation
import Testing

@testable import vInput

@Suite("翻译度量")
struct TranslationMetricsTests {
    // MARK: - 残留汉字：最硬的一条

    @Test("译文里的汉字被数出来")
    func countsResidualHanCharacters() {
        #expect(TranslationMetrics.residualHanCount("Hello world") == 0)
        #expect(TranslationMetrics.residualHanCount("Hello 世界") == 2)
        // 整句没译＝全是汉字。
        #expect(TranslationMetrics.residualHanCount("你好世界") == 4)
        // **中文标点不算汉字。** 这两件事分开数是整个类型存在的理由
        // （「英文句子配全角逗号」和「整段没译」是两种不同的失败形态），
        // 而在补这条之前没有任何测试验证它们真的分开——把 isHan 的下界
        // 放宽到 0x3000 会让标点混进来，此前测不出。
        #expect(TranslationMetrics.residualHanCount("Hello，world。") == 0)
    }

    /// 中文标点同样是没译干净的信号，但要与英文标点分开数——
    /// 英文译文里出现「，」和出现汉字是两种不同的失败形态。
    @Test("中文标点残留单独数")
    func countsChinesePunctuation() {
        #expect(TranslationMetrics.residualChinesePunctuationCount("Hello, world.") == 0)
        #expect(TranslationMetrics.residualChinesePunctuationCount("Hello，world。") == 2)
        #expect(TranslationMetrics.residualChinesePunctuationCount("Really？Yes！") == 2)
        // 反向：汉字不算标点。与上面那条合起来钉死两者互不重叠。
        #expect(TranslationMetrics.residualChinesePunctuationCount("你好世界") == 0)
        // 集合有 13 个成员，只碰四个的话删掉其余九个不会红。逐个点名。
        #expect(
            TranslationMetrics.residualChinesePunctuationCount("：；、（）「」《》") == 9
        )
    }

    // MARK: - 术语保留

    /// 技术术语译过去不该变形。复用 BenchMetrics.technicalTerms 抽词——
    /// 抽而不是手写清单，标准文本改了词表自动跟着改（M5 的做法）。
    @Test("原文里的技术术语在译文里应当原样出现")
    func measuresTermPreservation() {
        let source = "这个服务部署在 Azure 上，用 Terraform 管配置。"
        let good = "This service is deployed on Azure and configured with Terraform."
        let bad = "This service is deployed on Azur and configured with Terra Form."
        #expect(TranslationMetrics.termPreservationRate(source: source, translation: good) == 1.0)
        #expect(TranslationMetrics.termPreservationRate(source: source, translation: bad) < 1.0)
    }

    /// 原文没有术语时返回 1.0 而不是 0——否则口语类会把平均值拖垮，
    /// 而「没有术语可丢」不该被算成「术语全丢了」。
    @Test("原文没有术语时算满分")
    func noTermsMeansPerfect() {
        #expect(TranslationMetrics.termPreservationRate(
            source: "今天天气不错", translation: "Nice weather today") == 1.0)
    }

    // MARK: - 数字保留：报价场景最贵的错

    @Test("阿拉伯数字被抽出来")
    func extractsDigits() {
        #expect(TranslationMetrics.digitsIn("MOQ 500 pieces, 35 days by sea") == ["500", "35"])
        #expect(TranslationMetrics.digitsIn("no numbers here").isEmpty)
    }

    /// **中文数字不算数字。** `Character.isNumber` 对「三」「两」「百」「十」
    /// 「零」「①」「Ⅲ」全返回 true，用它做判据会让每个中文数字都被记成
    /// 「原文里的阿拉伯数字」，而译文里它们理应是 `three` 这样的英文词、
    /// 匹配不上，于是全部记成丢失。
    ///
    /// 这不是假想：2026-08-18 用 `isNumber` 版本跑 qwen2.5-7b × 英文 ×
    /// 26 条，汇总写的是「数字丢失 17 / 原文共 17 个」，而那 26 条里
    /// 一个 ASCII 数字都没有。这条用例就是那次的回归。
    @Test("中文数字不被当成阿拉伯数字")
    func chineseNumeralsAreNotDigits() {
        #expect(TranslationMetrics.digitsIn("今天开会讨论了三个议题第一个是数据库").isEmpty)
        #expect(TranslationMetrics.digitsIn("两百五十件，十天到货").isEmpty)
        #expect(TranslationMetrics.digitsIn("第①项和第Ⅲ项").isEmpty)
        // 混排时只抽 ASCII 的那部分。
        #expect(TranslationMetrics.digitsIn("第三批一共 250 件") == ["250"])
    }

    /// 承接上一条：中文数字译成英文词不该被记成丢数字。
    @Test("中文数字译成英文词不算丢失")
    func chineseNumeralTranslationIsNotLoss() {
        #expect(TranslationMetrics.lostDigits(
            source: "今天开会讨论了三个议题",
            translation: "We discussed three topics in today's meeting.").isEmpty)
    }

    /// 原文已经带阿拉伯数字时，译文丢一个就是丢一个。
    @Test("原文的阿拉伯数字丢失能被发现")
    func detectsLostDigits() {
        let source = "先跑 npm install，再看 3 个依赖。"
        #expect(TranslationMetrics.lostDigits(
            source: source, translation: "Run npm install, then check 3 dependencies").isEmpty)
        #expect(TranslationMetrics.lostDigits(
            source: source, translation: "Run npm install, then check dependencies") == ["3"])
    }

    // MARK: - 长度比：漏译会明显偏短

    @Test("长度比按显著字符算")
    func measuresLengthRatio() {
        // 中译英按字符数通常更长。
        let ratio = TranslationMetrics.lengthRatio(
            source: "今天下午三点开会", translation: "Meeting at 3pm today")
        #expect(ratio > 1.0)
        // 只译出一个词——**数据要留余量，不要压在阈值上**。
        // 计划原稿用 "Meeting"（7 / 14 = 恰好 0.5）配 `< 0.5`，
        // 是手算期望值压在边界上，实测才发现。这里实测 4 / 14 ≈ 0.286。
        let short = TranslationMetrics.lengthRatio(
            source: "今天下午三点开会讨论发版计划", translation: "Meet")
        #expect(short < 0.4)
    }

    /// 注释声称「用 significantCharacters 而不是 count：标点与空白不该计入，
    /// 否则中英文的标点密度差异会污染这个比值」。**这条测试守那句话**——
    /// 在补它之前，把分子改成 String.count 测试全绿，注释在声称一个测试
    /// 覆盖不到的性质。
    @Test("标点与空白不计入长度比")
    func lengthRatioIgnoresPunctuationAndWhitespace() {
        // 同样的内容，一个密集加标点、一个不加，比值应当一致。
        // 实测两侧都是 19 / 8 = 2.375，严格相等，不需要近似判断：
        // significantCharacters 只留字母与数字，标点空白在进除法之前
        // 就被滤掉了，两个比值来自同一对整数。
        let dense = TranslationMetrics.lengthRatio(
            source: "今天，下午，三点，开会。", translation: "Meeting, at, three, today.")
        let bare = TranslationMetrics.lengthRatio(
            source: "今天下午三点开会", translation: "Meeting at three today")
        #expect(dense == bare)
    }

    @Test("空译文的长度比是 0 而不是崩溃")
    func emptyTranslationIsSafe() {
        #expect(TranslationMetrics.lengthRatio(source: "有内容", translation: "") == 0)
    }

    @Test("空原文不除零")
    func emptySourceIsSafe() {
        #expect(TranslationMetrics.lengthRatio(source: "", translation: "anything") == 0)
    }
}

/// 忽略大小写的术语保留率。
///
/// 2026-08-19 六语对照实测暴露的问题：严格判据把「德语名词大写」和
/// 「术语被译走了」记成同一件事，于是菜单上给用户看的语种等级是反的。
@Suite("术语保留：大小写")
struct TermPreservationCaseTests {
    /// **德语的真实形态。** 这四个词全部只差首字母大小写，
    /// 而那是正确的德语正字法。
    @Test("只差大小写时宽松判据算保留，严格判据不算")
    func caseOnlyDifferenceCountsAsPreserved() {
        let source = "这个 API 返回的 token 过期了，需要重新调一次 refresh 接口。"
        let german = "Dieser API-Token ist abgelaufen und muss erneut über den Refresh-Endpoint aktualisiert werden."

        #expect(
            TranslationMetrics.termPreservationRateIgnoringCase(
                source: source, translation: german) == 1.0,
            "只差大小写，术语其实一个都没丢"
        )
        #expect(
            TranslationMetrics.termPreservationRate(source: source, translation: german) < 1.0,
            "严格判据应当仍然记它为未逐字保留——两个数的差值才是「只差大小写」那部分"
        )
    }

    /// **西语的真实形态：术语被译走了。** 宽松判据同样要判它丢失，
    /// 否则这个指标就什么都不管了。
    @Test("术语被译成别的词时，宽松判据也算丢失")
    func translatedAwayTermIsStillLost() {
        let source = "这个 API 返回的 token 过期了，需要重新调一次 refresh 接口。"
        let spanish = "Este token devuelto por el API ha expirado y es necesario llamar nuevamente al interfaz de actualización."

        let loose = TranslationMetrics.termPreservationRateIgnoringCase(
            source: source, translation: spanish)
        #expect(loose < 1.0, "refresh 被译成 actualización，那是真丢了")
        // 三个术语丢一个。
        #expect(abs(loose - 2.0 / 3.0) < 0.01)
    }

    /// 两个判据不是同一个函数的两个名字。
    ///
    /// 防的是「宽松版直接调严格版」或反过来——那样上面两条里总有一条会绿得
    /// 毫无意义。本仓库栽过八次这类「看着在检查其实什么都没检查」。
    @Test("两个判据在同一素材上给出不同的数")
    func twoCriteriaActuallyDiffer() {
        let source = "先跑 pnpm build，失败的话看 Vite 的 rollup 阶段。"
        let translated = "Führe zuerst pnpm build aus, dann schaue dir den Rollup-Step von Vite an."
        #expect(
            TranslationMetrics.termPreservationRate(source: source, translation: translated)
                != TranslationMetrics.termPreservationRateIgnoringCase(
                    source: source, translation: translated)
        )
    }

    /// 原文没有技术术语时两个都返回 1.0（分母为空的约定）。
    @Test("没有术语时两个判据都是 1.0")
    func emptyDenominatorIsOne() {
        let source = "今天下午三点开会。"
        #expect(TranslationMetrics.termPreservationRate(source: source, translation: "Meeting.") == 1.0)
        #expect(
            TranslationMetrics.termPreservationRateIgnoringCase(
                source: source, translation: "Meeting.") == 1.0)
    }
}
