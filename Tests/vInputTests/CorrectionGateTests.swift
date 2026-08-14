import Testing

@testable import vInput

@Suite("拼音闸门")
struct CorrectionGateTests {
    @Test("同音替换放行")
    func allowsHomophones() {
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "耀空气", replacement: "遥控器")))
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "数据裤", replacement: "数据库")))
    }

    /// 这条是闸门存在的全部理由：模型「好心」把术语翻译成中文，
    /// 或自作主张重写句子，都必须被拦下。
    @Test("异音替换拦下")
    func rejectsRewrites() {
        #expect(!CorrectionGate.allows(
            CorrectionEdit(original: "useEffect", replacement: "副作用钩子")))
        #expect(!CorrectionGate.allows(
            CorrectionEdit(original: "那我明天再看看吧", replacement: "明日再议")))
    }

    /// 英文标识符之间的替换必须拦下：它们拼音转换后都是原样，
    /// 靠字面即可区分，不需要额外规则。
    @Test("英文标识符之间不得互换")
    func rejectsIdentifierSwaps() {
        #expect(!CorrectionGate.allows(
            CorrectionEdit(original: "useState", replacement: "useEffect")))
    }

    @Test("声调差异不影响放行")
    func toneDifferenceAllowed() {
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "在", replacement: "再")))
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "他", replacement: "她")))
    }

    @Test("增删字数导致读音不同，拦下")
    func lengthChangeRejected() {
        #expect(!CorrectionGate.allows(
            CorrectionEdit(original: "遥控器", replacement: "蓝牙遥控器")))
    }

    // MARK: - 应用替换

    @Test("放行的替换被应用")
    func appliesAllowedEdits() {
        let result = CorrectionGate.apply(
            [CorrectionEdit(original: "耀空气", replacement: "遥控器")],
            to: "小米耀空气很好用"
        )
        #expect(result.text == "小米遥控器很好用")
        #expect(result.applied == [CorrectionEdit(original: "耀空气", replacement: "遥控器")])
        #expect(result.rejected.isEmpty)
    }

    /// 部分采纳：一条不合格只回退那一条，其余照常生效。
    /// 因一处可疑而丢弃全部校正，是把谨慎错用成了浪费。
    @Test("部分采纳，不合格的单独回退")
    func partialAcceptance() {
        let edits = [
            CorrectionEdit(original: "耀空气", replacement: "遥控器"),
            CorrectionEdit(original: "useEffect", replacement: "副作用钩子"),
        ]
        let result = CorrectionGate.apply(edits, to: "用 useEffect 控制耀空气")
        #expect(result.text == "用 useEffect 控制遥控器")
        #expect(result.applied.count == 1)
        #expect(result.rejected == [CorrectionEdit(original: "useEffect", replacement: "副作用钩子")])
    }

    /// 模型偶尔会「引用」一个它自己改写过的片段，那种条目无从定位。
    @Test("原文不在文本中的条目丢弃")
    func dropsEditsNotPresent() {
        let result = CorrectionGate.apply(
            [CorrectionEdit(original: "不存在的词", replacement: "别的词")],
            to: "小米遥控器"
        )
        #expect(result.text == "小米遥控器")
        #expect(result.applied.isEmpty)
        #expect(result.rejected == [CorrectionEdit(original: "不存在的词", replacement: "别的词")])
    }

    /// 同一个词在一句话里听错两次会错成同一个样子，
    /// 只改第一处会留下一个自相矛盾的句子。
    @Test("同一片段出现多次时全部替换")
    func replacesAllOccurrences() {
        let result = CorrectionGate.apply(
            [CorrectionEdit(original: "耀空气", replacement: "遥控器")],
            to: "耀空气和另一个耀空气"
        )
        #expect(result.text == "遥控器和另一个遥控器")
    }

    /// 短片段先替换会破坏长片段的匹配，因此按长度降序应用。
    @Test("按原文长度降序应用，避免互相破坏")
    func longestFirst() {
        let edits = [
            CorrectionEdit(original: "据裤", replacement: "据库"),
            CorrectionEdit(original: "数据裤", replacement: "数据库"),
        ]
        let result = CorrectionGate.apply(edits, to: "查一下数据裤")
        #expect(result.text == "查一下数据库")
        #expect(result.applied.count == 1)
    }

    @Test("空清单原样返回")
    func emptyEdits() {
        let result = CorrectionGate.apply([], to: "原文不动")
        #expect(result.text == "原文不动")
        #expect(result.applied.isEmpty)
        #expect(result.rejected.isEmpty)
    }
}
