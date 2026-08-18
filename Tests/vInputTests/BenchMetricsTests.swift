import Testing

@testable import vInput

@Suite("基准集度量")
struct BenchMetricsTests {
    // MARK: - 字错误率

    @Test("完全一致时错误率为零")
    func identicalTextHasZeroErrorRate() {
        #expect(BenchMetrics.characterErrorRate(reference: "今天天气不错", hypothesis: "今天天气不错") == 0)
    }

    @Test("替换一个字")
    func singleSubstitution() {
        // 六个字里错一个
        let rate = BenchMetrics.characterErrorRate(reference: "今天天气不错", hypothesis: "今天天气不对")
        #expect(abs(rate - 1.0 / 6.0) < 0.0001)
    }

    @Test("漏一个字")
    func singleDeletion() {
        let rate = BenchMetrics.characterErrorRate(reference: "会议室见面", hypothesis: "会议室见")
        #expect(abs(rate - 1.0 / 5.0) < 0.0001)
    }

    /// 标点不计入字错误率——它由独立的标点指标衡量。
    /// 混在一起的话，一次标点改善会掩盖一次真实的漏字。
    @Test("标点不计入错误率")
    func punctuationExcluded() {
        #expect(BenchMetrics.characterErrorRate(
            reference: "今天天气不错我们出去走走",
            hypothesis: "今天天气不错，我们出去走走。"
        ) == 0)
    }

    @Test("空假设的错误率为一")
    func emptyHypothesis() {
        #expect(BenchMetrics.characterErrorRate(reference: "今天天气不错", hypothesis: "") == 1.0)
    }

    // MARK: - 标点

    @Test("数出标点个数")
    func countsPunctuation() {
        #expect(BenchMetrics.punctuationCount("今天天气不错，我们出去走走。") == 2)
        #expect(BenchMetrics.punctuationCount("今天天气不错我们出去走走") == 0)
    }

    // MARK: - 技术词命中

    /// 大小写必须严格比对——`github actions` 不算命中。
    /// M4 真机上大小写丢失正是主要失败形态之一。
    @Test("技术词大小写敏感")
    func technicalTermsAreCaseSensitive() {
        let terms = ["Claude Code", "GitHub Actions", "AWS"]
        #expect(BenchMetrics.termHitRate(
            terms: terms, in: "我们用 Claude Code 和 GitHub Actions，部署到 AWS。"
        ) == 1.0)
        #expect(BenchMetrics.termHitRate(
            terms: terms, in: "我们用 claude code 和 github actions，部署到 aws。"
        ) == 0.0)
    }

    @Test("部分命中")
    func partialTermHit() {
        let rate = BenchMetrics.termHitRate(terms: ["AWS", "GitHub"], in: "部署到 AWS 上面")
        #expect(abs(rate - 0.5) < 0.0001)
    }

    @Test("空词表命中率为一")
    func emptyTermsHitFully() {
        #expect(BenchMetrics.termHitRate(terms: [], in: "任意文本") == 1.0)
    }

    // MARK: - 技术词抽取

    /// 从标准文本自动抽词而非手工维护列表——文本改了词表自动跟着改。
    @Test("抽出多词与单词的技术名")
    func extractsTechnicalTerms() {
        let terms = BenchMetrics.technicalTerms(
            in: "我们用 Claude Code 和 GitHub Actions，部署到 AWS 上面。"
        )
        #expect(terms.contains("Claude Code"))
        #expect(terms.contains("GitHub Actions"))
        #expect(terms.contains("AWS"))
    }

    @Test("纯中文文本抽不出技术词")
    func chineseOnlyHasNoTerms() {
        #expect(BenchMetrics.technicalTerms(in: "今天天气不错，我们出去走走。").isEmpty)
    }

    // MARK: - 半角标点（漏转检测）

    /// 这个指标最初是 `fullWidthConversions(...).count`，与转换器共用同一个
    /// 函数、又跑在转换之后，于是**恒读 0**——基准集 26 条全是「半角=0」，
    /// 那不是测量结果是恒等式。下面这几条钉住新判据确实独立于转换器。
    @Test("两个汉字之间的半角标点会被数出来")
    func countsHalfWidthBetweenHanCharacters() {
        #expect(BenchMetrics.halfWidthPunctuationInChinese("你好,世界") == 1)
        #expect(BenchMetrics.halfWidthPunctuationInChinese("对吗?我不确定") == 1)
        #expect(BenchMetrics.halfWidthPunctuationInChinese("注意:这里有坑") == 1)
        #expect(BenchMetrics.halfWidthPunctuationInChinese("先装依赖;再跑测试") == 1)
        #expect(BenchMetrics.halfWidthPunctuationInChinese("太好了!这就上线") == 1)
    }

    /// 判据刻意比转换器窄：只认「两侧都是汉字」。窄的好处是凡报出来的都
    /// 无疑是错的，不需要为千分位、代码、URL 写特例。
    @Test("代码与数字里的半角标点一律不数")
    func ignoresCodeAndNumbers() {
        for text in [
            "金额是 1,200,000 元",
            "先跑 foo(a, b) 再说",
            "下午 3:30 开会",
            "比例是 16:9",
            "打开 https://x.com/s?q=vinput 看看",
            "写成 int x = 1; 然后编译",
        ] {
            #expect(
                BenchMetrics.halfWidthPunctuationInChinese(text) == 0,
                "误报了：\(text)"
            )
        }
    }

    /// 空白要跳过——真实转写里「你好, 世界」这种带空格的形态很常见。
    @Test("跳过空白找邻居")
    func skipsWhitespaceWhenLookingAtNeighbours() {
        #expect(BenchMetrics.halfWidthPunctuationInChinese("你好, 世界") == 1)
        #expect(BenchMetrics.halfWidthPunctuationInChinese("你好 , 世界") == 1)
    }

    /// 全角的不该被数——否则转换器做对了指标反而变难看。
    @Test("已经是全角的不计入")
    func fullWidthIsNotCounted() {
        #expect(BenchMetrics.halfWidthPunctuationInChinese("你好，世界。对吗？") == 0)
    }

    /// 单侧是汉字不算。转换器会转（它的规则是「任一侧」），但度量不报——
    /// 这正是「窄」的含义：度量不替转换器判那些有争议的位置。
    @Test("只有一侧是汉字时不计入")
    func singleSidedContextIsNotCounted() {
        #expect(BenchMetrics.halfWidthPunctuationInChinese("部署到 AWS,先跑") == 0)
        #expect(BenchMetrics.halfWidthPunctuationInChinese("我用 React,Vue 和它") == 0)
    }


    /// 句末标点没有右邻居——这一档必须单独钉住，它是最常见的真实形态。
    /// 用户 2026-08-17 的日志：「…把 M8 的分场景优化改成?」，句号全角、
    /// 句末问号半角。要求右邻存在的话这一类一个都数不到。
    @Test("句末的半角标点也要数出来")
    func countsSentenceFinalPunctuation() {
        #expect(BenchMetrics.halfWidthPunctuationInChinese("有没有可能?") == 1)
        #expect(BenchMetrics.halfWidthPunctuationInChinese("我在想,有没有可能?") == 2)
        #expect(BenchMetrics.halfWidthPunctuationInChinese("太好了!") == 1)
    }

    /// 末尾那一档只放宽右邻，左邻仍然必须是汉字，否则代码结尾会误报。
    @Test("末尾但左邻不是汉字时仍不数")
    func trailingAfterLatinIsNotCounted() {
        #expect(BenchMetrics.halfWidthPunctuationInChinese("跑一下 npm install;") == 0)
        #expect(BenchMetrics.halfWidthPunctuationInChinese("Is it ready?") == 0)
    }

}
