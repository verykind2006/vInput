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
}
