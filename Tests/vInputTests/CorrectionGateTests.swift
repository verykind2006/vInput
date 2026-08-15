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

    /// 声调不同但同音的替换必须放行——同音错字绝大多数就是声调差
    /// （yào 耀 / yáo 遥），要求声调一致会把最该修的那一类全部拦掉。
    ///
    /// **例子刻意用双字词。** 原先用的「在→再」「他→她」有两个问题：
    /// 一是它们声调本就相同，根本没测到声调；二是单字替换现在被长度
    /// 规则一律拦下（见 minimumOriginalLength），用它们测声调等于把
    /// 两条无关的规则缠在一起。
    ///
    /// 「事件/时间」「主意/注意」都是真实的中文语音识别混淆。
    @Test("声调差异不影响放行")
    func toneDifferenceAllowed() {
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "事件", replacement: "时间")))
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "主意", replacement: "注意")))
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

    /// 单字替换缺少消歧所需的上下文：模型说「的→得」，我们无从知道
    /// 句子里哪个「的」该改，而全局替换会把本来正确的字一并改坏。
    /// 实测「我的书写得很好，他的笔也不错」会变成「我得书写得很好，他得笔也不错」。
    ///
    /// 取舍很明确：漏掉真正的单字错误，换取不改坏一整句。
    @Test("单字替换一律拦下")
    func rejectsSingleCharacterEdits() {
        for edit in [
            CorrectionEdit(original: "的", replacement: "得"),
            CorrectionEdit(original: "在", replacement: "再"),
            CorrectionEdit(original: "他", replacement: "她"),
        ] {
            #expect(!CorrectionGate.allows(edit), "\(edit.original)→\(edit.replacement) 应被拦下")
        }
    }

    @Test("两字及以上仍然放行")
    func allowsMultiCharacterEdits() {
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "耀空", replacement: "遥控")))
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "耀空气", replacement: "遥控器")))
    }

    @Test("单字替换不会污染整句")
    func singleCharEditLeavesTextIntact() {
        let result = CorrectionGate.apply(
            [CorrectionEdit(original: "的", replacement: "得")],
            to: "我的书写得很好，他的笔也不错"
        )
        #expect(result.text == "我的书写得很好，他的笔也不错")
        #expect(result.applied.isEmpty)
        #expect(result.rejected.count == 1)
    }

    /// 长度阈值的本意是「要有足够上下文消歧」。用字符数衡量对拉丁文
    /// 毫无意义：AI 是 2 个字符，却只是一个词、约一个音节。
    /// 实测后果：「我们用 AI 做的这个功能」→「我们用 爱 做的这个功能」，
    /// 与设计文档「英文标识符一律保持原样」正面冲突。
    @Test("短拉丁词不得被替换成汉字")
    func rejectsShortLatinToHanEdits() {
        for edit in [
            CorrectionEdit(original: "AI", replacement: "爱"),
            CorrectionEdit(original: "he", replacement: "和"),
            CorrectionEdit(original: "long", replacement: "龙"),
        ] {
            #expect(!CorrectionGate.allows(edit), "\(edit.original)→\(edit.replacement) 应被拦下")
        }
    }

    // MARK: - 被拆开的英文标识符

    /// 主场景是给 AI 写 prompt，用户口述英文标识符，Whisper 惯于把它们
    /// 拆开并首字母大写。模型给的建议是对的，闸门却因为差一个空格而拒绝。
    /// 归一化「夹在两个拉丁字母之间的空白」之后这类替换才过得去。
    @Test("拆开的英文标识符拼回去，放行")
    func allowsRejoinedIdentifiers() {
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "Use Effect", replacement: "useEffect")))
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "get User Name", replacement: "getUserName")))
    }

    /// 放宽一步也不许碰汉字：这条是防误伤的回归钉。
    ///
    /// 归一化刻意做在**原始字符串**上——那时汉字之间根本没有空白可删。
    /// 若错做在拼音之后，`xi an` 会被压成 `xian`，「西安」与「先」就混为
    /// 一谈了，而它们是两个不同的词。
    @Test("汉字之间的判定不得放宽")
    func doesNotLoosenHanComparison() {
        #expect(!CorrectionGate.allows(
            CorrectionEdit(original: "西安", replacement: "先")))
        #expect(!CorrectionGate.allows(
            CorrectionEdit(original: "小米", replacement: "米粒")))
    }

    /// 中英混排：空格一侧是汉字时不动它，前半段读音变了照样拦下。
    @Test("中英混排只合并拉丁段")
    func mergesOnlyLatinRuns() {
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "改成 Use Effect", replacement: "改成 useEffect")))
        #expect(!CorrectionGate.allows(
            CorrectionEdit(original: "改成 Use Effect", replacement: "变成 useEffect")))
    }

    /// **反方向的实际行为，如实记录。**
    ///
    /// 闸门在拉丁段上只保证「字母序列一致」：大小写本来就被
    /// `Pinyin.toneless` 抹平，词边界现在也被抹平了。所以拆分方向、
    /// 大小写乱改都不是靠读音比对挡住的：
    ///
    /// - `useEffect→Use Effect` 拦得下，但拦下它的是**长度规则**——
    ///   单个拉丁词只有 1 段，够不着 `minimumOriginalLength`。
    /// - 原文一旦本身就被拆成两段以上，长度规则就不再兜底，
    ///   `Use Effect→USEEFFECT` 这种纯大小写乱改会被放行。
    ///
    /// 那一格只剩提示词兜着（「不许改大小写，useEffect 就该一直是
    /// useEffect」）。真机上出过事故：某一版提示词让模型把本来正确的
    /// `useEffect` 改成 `useeffect`。这是已知取舍，不是遗漏。
    @Test("反方向：拦下它的是长度规则，不是读音")
    func reverseDirectionIsNotGuardedByReading() {
        #expect(!CorrectionGate.allows(
            CorrectionEdit(original: "useEffect", replacement: "Use Effect")))
        #expect(!CorrectionGate.allows(
            CorrectionEdit(original: "useEffect", replacement: "useeffect")))

        // 原文自带空格时长度规则不再兜底，纯大小写乱改就过得去了。
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "Use Effect", replacement: "USEEFFECT")))
    }

    /// **拆分方向也被放行了，如实记录。** 这是真机上兑现过的代价：
    /// 端到端那句「一个字都不能动」的样本，模型建议
    /// `…Claude CodeOpen AILLM→…Claude Code Open AI LLM`，
    /// 归一化之后两边都是同一串字母，闸门看不出区别。
    ///
    /// 合并方向（`Use Effect→useEffect`）是我们要的，拆分方向是顺带来的，
    /// 同一条规则区分不了两者。挡它的同样只有提示词那条「不许加空格删空格」。
    @Test("往拉丁段里插空格同样会被放行")
    func splittingLatinRunIsAlsoAllowed() {
        #expect(CorrectionGate.allows(CorrectionEdit(
            original: "我们说Claude CodeOpen AILLM",
            replacement: "我们说Claude Code Open AI LLM"
        )))
    }

    @Test("正常的中文多字替换仍放行")
    func stillAllowsNormalChineseEdits() {
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "耀空气", replacement: "遥控器")))
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "事件", replacement: "时间")))
    }
}
