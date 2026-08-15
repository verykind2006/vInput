import Testing

@testable import vInput

@Suite("替换清单解析")
struct CorrectionEditParserTests {
    @Test("解析标准格式")
    func parsesStandardFormat() {
        let edits = CorrectionEditParser.parse("耀空气→遥控器\n数据裤→数据库")
        #expect(edits == [
            CorrectionEdit(original: "耀空气", replacement: "遥控器"),
            CorrectionEdit(original: "数据裤", replacement: "数据库"),
        ])
    }

    /// 4B 量级的模型格式不稳定，箭头可能写成 ASCII 或带空格。
    /// 与其要求模型精确，不如让解析宽容——宽容的代价只是多认几种写法，
    /// 严格的代价是整次校正作废。
    @Test("容忍箭头变体与空白")
    func toleratesArrowVariants() {
        let edits = CorrectionEditParser.parse("  耀空气 -> 遥控器  \n数据裤 => 数据库")
        #expect(edits == [
            CorrectionEdit(original: "耀空气", replacement: "遥控器"),
            CorrectionEdit(original: "数据裤", replacement: "数据库"),
        ])
    }

    /// 单条畸形只丢弃该条，不影响其余——与闸门的部分采纳一致。
    @Test("畸形行被丢弃，其余保留")
    func skipsMalformedLines() {
        let edits = CorrectionEditParser.parse("""
            耀空气→遥控器
            这一行没有箭头
            →只有右边
            只有左边→
            数据裤→数据库
            """)
        #expect(edits == [
            CorrectionEdit(original: "耀空气", replacement: "遥控器"),
            CorrectionEdit(original: "数据裤", replacement: "数据库"),
        ])
    }

    /// 模型常在清单前后加解释性文字，这些行没有箭头，自然被丢弃。
    @Test("忽略模型的解释性文字")
    func ignoresProse() {
        let edits = CorrectionEditParser.parse("""
            好的，我发现了以下问题：
            耀空气→遥控器
            希望对你有帮助！
            """)
        #expect(edits == [CorrectionEdit(original: "耀空气", replacement: "遥控器")])
    }

    @Test("空输出得到空清单")
    func emptyOutput() {
        #expect(CorrectionEditParser.parse("").isEmpty)
        #expect(CorrectionEditParser.parse("\n\n  \n").isEmpty)
    }

    /// 一行里出现多个箭头无法确定切分点，整行丢弃。
    /// 猜错的代价是改错用户的话，不猜的代价只是少改一处。
    @Test("多箭头的行整行丢弃")
    func multipleArrowsRejected() {
        #expect(CorrectionEditParser.parse("甲→乙→丙").isEmpty)
    }

    @Test("原文与替换相同的条目丢弃")
    func noOpEditsDropped() {
        #expect(CorrectionEditParser.parse("遥控器→遥控器").isEmpty)
    }

    /// 4B 模型输出带项目符号是常态。装饰一出现就整条丢弃的话，
    /// 用户看到的是「开关校正没差别」，而日志里什么异常都没有。
    @Test("剥离行首的列表符号")
    func stripsListMarkers() {
        let expected = [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
        for line in ["- 耀空气→遥控器", "* 耀空气→遥控器", "• 耀空气→遥控器",
                     "1. 耀空气→遥控器", "2) 耀空气→遥控器"] {
            #expect(CorrectionEditParser.parse(line) == expected, "未能解析：\(line)")
        }
    }

    /// 提示词的示例以「输出：」开头，模型很容易照着回显。
    @Test("剥离行首的标签前缀")
    func stripsLabelPrefix() {
        let expected = [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
        for line in ["输出：耀空气→遥控器", "输出: 耀空气→遥控器"] {
            #expect(CorrectionEditParser.parse(line) == expected, "未能解析：\(line)")
        }
    }

    @Test("剥离包裹的引号与行尾句点")
    func stripsQuotesAndTrailingPunctuation() {
        let expected = [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
        for line in ["「耀空气」→「遥控器」", "\"耀空气\"→\"遥控器\"",
                     "耀空气→遥控器。", "耀空气→遥控器."] {
            #expect(CorrectionEditParser.parse(line) == expected, "未能解析：\(line)")
        }
    }

    /// 剥离不得伤及正文：替换文本内部的标点必须原样保留。
    /// 这条是上面三条的安全网——过度剥离会悄悄改坏用户的文字。
    @Test("不剥离词内部的字符")
    func doesNotStripInteriorCharacters() {
        #expect(
            CorrectionEditParser.parse("三点一四→3.14")
                == [CorrectionEdit(original: "三点一四", replacement: "3.14")]
        )
        #expect(
            CorrectionEditParser.parse("句号→。") == []
        )
    }

    /// 提示词以「回答：」结尾，模型回显这个词的概率最高。
    /// 早先提示词用的是「输出：」，两种都要认——模型也可能受训练数据
    /// 影响输出另一种。
    @Test("剥离回答标签前缀")
    func stripsAnswerLabelPrefix() {
        let expected = [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
        for line in ["回答：耀空气→遥控器", "回答: 耀空气→遥控器",
                     "输出：耀空气→遥控器"] {
            #expect(CorrectionEditParser.parse(line) == expected, "未能解析：\(line)")
        }
    }

    /// `\d+[.)]` 不区分列表编号与小数点。列表编号后面总有空白，
    /// 小数点后面紧跟数字——用这个区分，别让剥离逻辑吃掉正文。
    @Test("不把小数点当列表编号")
    func doesNotMistakeDecimalForListMarker() {
        #expect(
            CorrectionEditParser.parse("1.5→一点五")
                == [CorrectionEdit(original: "1.5", replacement: "一点五")]
        )
        #expect(
            CorrectionEditParser.parse("2)3→二三")
                == [CorrectionEdit(original: "2)3", replacement: "二三")]
        )
    }

    /// 上一条测试收紧了规则，这条确认没有误伤：真正的列表编号
    /// （编号后带空格）仍然照常剥离。
    @Test("带空白的列表编号仍被剥离")
    func stripsNumberedListMarkers() {
        let expected = [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
        #expect(CorrectionEditParser.parse("1. 耀空气→遥控器") == expected)
        #expect(CorrectionEditParser.parse("2) 耀空气→遥控器") == expected)
    }
}
