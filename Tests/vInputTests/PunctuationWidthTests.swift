import Testing
@testable import vInput

/// M6 ⑤：说中文时 Whisper 输出半角 `,`，句号却是全角 `。`。
///
/// **难点全在中英混排**——`用 Claude Code 部署到 AWS,先跑 npm install`
/// 里那个逗号该转全角，而英文短语内部的逗号该保持半角。判据取「离逗号最近
/// 的那个实字符是不是中文语境」，与 `CorrectionGate.joiningLatinWords`
/// 处理拉丁词边界是同一种做法：在原始字符串上看邻居，不做整段语言判定。
@Suite("中文语境的半角逗号")
struct PunctuationWidthTests {

    // MARK: - 该转的

    @Test("两侧都是汉字时转全角")
    func convertsBetweenChinese() {
        #expect(TranscriptCleaner.clean("我在想,有没有可能") == "我在想，有没有可能")
    }

    @Test("中英混排：英文词收尾、中文起头的那个逗号要转")
    func convertsAfterLatinBeforeChinese() {
        #expect(
            TranscriptCleaner.clean("用 Claude Code 部署到 AWS,先跑 npm install")
                == "用 Claude Code 部署到 AWS，先跑 npm install"
        )
    }

    @Test("中英混排：中文收尾、英文起头的那个逗号也要转")
    func convertsAfterChineseBeforeLatin() {
        #expect(TranscriptCleaner.clean("先装好依赖,npm install 就够了")
                == "先装好依赖，npm install 就够了")
    }

    @Test("一句话里多个逗号各判各的")
    func judgesEachCommaIndependently() {
        #expect(
            TranscriptCleaner.clean("先跑 npm run build, npm run test,然后再部署")
                == "先跑 npm run build, npm run test，然后再部署"
        )
    }

    @Test("逗号在末尾时看前面那个字")
    func usesPrecedingCharacterAtEnd() {
        #expect(TranscriptCleaner.clean("他说,") == "他说，")
    }

    @Test("紧邻中文标点也算中文语境，哪怕另一侧是拉丁词")
    func treatsChinesePunctuationAsContext() {
        // 左边只有一个中文右引号，右边是纯拉丁词——判据是「最近的实字符」，
        // 不是「两侧都得是汉字」。
        #expect(TranscriptCleaner.clean("「好的」,OK") == "「好的」，OK")
    }

    @Test("转换时吃掉紧邻的空格：全角逗号自带间距")
    func swallowsAdjacentSpaces() {
        #expect(TranscriptCleaner.clean("部署到 AWS, 先跑 npm install")
                == "部署到 AWS，先跑 npm install")
        #expect(TranscriptCleaner.clean("部署到 AWS ,先跑 npm install")
                == "部署到 AWS，先跑 npm install")
    }

    // MARK: - 不该转的

    @Test("纯英文句子里的逗号保持半角")
    func keepsCommaInEnglishSentence() {
        #expect(TranscriptCleaner.clean("Run npm install, then npm test")
                == "Run npm install, then npm test")
    }

    @Test("千分位不能动——这是最贵的一个误伤")
    func keepsThousandSeparator() {
        #expect(TranscriptCleaner.clean("这轮融资 1,200,000 美元") == "这轮融资 1,200,000 美元")
    }

    @Test("中文句子里被引号括起来的英文，内部逗号保持半角")
    func keepsCommaInsideQuotedEnglish() {
        #expect(TranscriptCleaner.clean("他说 \"Hello, world\" 然后走了")
                == "他说 \"Hello, world\" 然后走了")
    }

    @Test("代码里的参数列表保持半角")
    func keepsCommaInCode() {
        #expect(TranscriptCleaner.clean("写成 foo(a, b) 就行") == "写成 foo(a, b) 就行")
    }

    @Test("已经是全角的逗号不动")
    func leavesFullWidthAlone() {
        #expect(TranscriptCleaner.clean("我在想，有没有可能") == "我在想，有没有可能")
    }

    @Test("没有逗号的文本原样返回")
    func leavesTextWithoutCommas() {
        #expect(TranscriptCleaner.clean("今天天气不错。") == "今天天气不错。")
    }

    @Test("只改逗号，不碰句号问号——那两个不在本轮已定的范围内")
    func onlyTouchesComma() {
        // 半角问号确实也会出现（Roadmap 里 session 103 的日志就是
        // 「改成?」），但 2026-08-17 定的范围只有逗号。度量能看见它，
        // 要不要改由用户再定。
        #expect(TranscriptCleaner.clean("有没有可能?") == "有没有可能?")
        #expect(TranscriptCleaner.clean("今天天气不错.") == "今天天气不错.")
    }

    // MARK: - 度量

    @Test("中文语境里的半角标点被数出来")
    func countsHalfWidthInChinese() {
        #expect(BenchMetrics.halfWidthPunctuationInChinese("我在想,有没有可能?") == 2)
    }

    @Test("全角标点不计入")
    func fullWidthNotCounted() {
        #expect(BenchMetrics.halfWidthPunctuationInChinese("我在想，有没有可能？") == 0)
    }

    @Test("英文语境里的半角标点不计入——它们本来就该是半角")
    func latinContextNotCounted() {
        #expect(BenchMetrics.halfWidthPunctuationInChinese("Run npm install, then test.") == 0)
        #expect(BenchMetrics.halfWidthPunctuationInChinese("这轮融资 1,200,000 美元") == 0)
        #expect(BenchMetrics.halfWidthPunctuationInChinese("版本是 3.14 那个") == 0)
    }

    @Test("这个指标正是基准集从第一天起就屏蔽掉的那个不匹配")
    func exposesTheBlindSpot() {
        let reference = "今天下午三点开会，讨论一下发版计划。"
        let hypothesis = "今天下午三点开会,讨论一下发版计划."

        // CER 刻意排除标点，两者一模一样——这就是它藏了这么久的原因。
        #expect(BenchMetrics.characterErrorRate(reference: reference, hypothesis: hypothesis) == 0)
        // punctuationCount 只数个数，也一模一样。
        #expect(BenchMetrics.punctuationCount(reference) == BenchMetrics.punctuationCount(hypothesis))
        // 只有新指标看得见。
        #expect(BenchMetrics.halfWidthPunctuationInChinese(reference) == 0)
        #expect(BenchMetrics.halfWidthPunctuationInChinese(hypothesis) == 2)
    }
}
