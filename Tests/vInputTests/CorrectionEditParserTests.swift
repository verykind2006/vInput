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
}
