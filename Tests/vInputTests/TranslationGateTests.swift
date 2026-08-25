import Foundation
import Testing

@testable import vInput

/// `TranslationGate` 的用例。
///
/// **每条用例只让一条判据亮起**：想验「残留汉字」就把中文标点、句末标点、
/// 长度比全部安排成合格的，否则删掉被验的那条判据用例照样红——红在别的
/// 判据上，看起来像验到了，其实没有。下面几条都在注释里写了它隔离掉了什么。
@Suite("翻译闸门")
struct TranslationGateTests {
    private let gate = TranslationGate()

    // MARK: - 四条判据各自的守卫

    @Test("干净的译文放行")
    func cleanTranslationPasses() {
        #expect(
            gate.check(
                source: "今天下午三点开会。",
                translation: "Meeting at 3pm today.",
                from: .chinese, to: .english) == .pass)
    }

    /// 隔离：译文以句点收尾（截断判据不亮）、无中文标点、长度比正常。
    /// 唯一不合格的是那两个汉字。
    @Test("残留汉字一律拦下")
    func residualHanIsRejected() {
        #expect(
            gate.check(
                source: "今天下午三点开会。",
                translation: "Meeting at 三点 today.",
                from: .chinese, to: .english) == .reject(.residualHan(count: 2)))
    }

    /// 整段没译回来是残留汉字的极端形态：译文就是原文。
    @Test("整段没译被拦下")
    func untranslatedPassthroughIsRejected() {
        let source = "今天下午三点开会。"
        #expect(
            gate.check(source: source, translation: source, from: .chinese, to: .english)
                == .reject(.residualHan(count: 8)))
    }

    /// 隔离：无汉字、以句点收尾、长度比正常。唯一不合格的是那个全角逗号。
    @Test("中文标点残留被拦下")
    func chinesePunctuationIsRejected() {
        #expect(
            gate.check(
                source: "行，没问题。",
                translation: "Sure，no problem.",
                from: .chinese, to: .english) == .reject(.chinesePunctuation(count: 1)))
    }

    /// **主信号的守卫。** 这条用例的全部意义是「长度比拦不住它，只有截断
    /// 判据能拦」——所以它同时断言这条译文的长度比是合格的。少了那半句，
    /// 把 `looksTruncated` 那一步整个删掉，本用例会因为长度比而照样红，
    /// 看起来像验到了主信号。
    ///
    /// 素材是实测数据：`Bench/reports/m8-step0/03a-4b-manifest.txt` 里
    /// punct-02 的英文译文，砍掉最后一句（这正是 Task 8 实测到的形态——
    /// 取消对 MLX 推理无效，`translate` **成功返回**半截译文）。
    @Test("半截译文被截断判据拦下——而长度比拦不住它")
    func truncatedTranslationIsRejected() {
        let source = "今天开会讨论了三个议题第一个是数据库的性能优化第二个是新功能的上线计划"
            + "第三个是关于用户反馈的处理流程我们逐个过一遍。"
        let halfway = "Today we held a meeting to discuss three topics. The first is database "
            + "performance optimization, the second is the launch plan for new features, and "
            + "the third is the process for handling user feedback"

        #expect(
            TranslationMetrics.lengthRatio(source: source, translation: halfway)
                >= gate.minimumLengthRatio,
            "这条半截译文的长度比是合格的，长度比判据碰不到它——本用例验的是截断判据")
        #expect(
            gate.check(source: source, translation: halfway, from: .chinese, to: .english)
                == .reject(.truncated))
    }

    /// 隔离：无汉字、无中文标点、以句点收尾（截断判据不亮）。
    /// 唯一不合格的是长度比。
    ///
    /// **同时钉住阈值本身**：同一条输入在阈值 0.3（计划里的旧值）下必须放行。
    /// 少了这半句，把默认阈值改成 0.3 不会有任何用例变红。
    @Test("译文过短被拦下——并钉住阈值")
    func tooShortIsRejected() {
        let source = "今天开会讨论了三个议题第一个是数据库的性能优化第二个是新功能的上线计划"
            + "第三个是关于用户反馈的处理流程我们逐个过一遍。"
        let stub = "We discussed three topics in today's meeting."

        guard case .reject(.tooShort(let ratio)) = gate.check(
            source: source, translation: stub, from: .chinese, to: .english)
        else {
            Issue.record("过短的译文应当被 tooShort 拦下")
            return
        }
        #expect(ratio < gate.minimumLengthRatio)

        // 阈值放到 0.3 就放行——证明拦下它的是阈值这个数，不是别的判据。
        #expect(
            TranslationGate(minimumLengthRatio: 0.3)
                .check(source: source, translation: stub, from: .chinese, to: .english) == .pass)
    }

    // MARK: - 阈值的两条边界

    /// **实测里最短的那条正常译文必须放行。**
    ///
    /// 86 条 4B 正常译文里长度比最小的一条（`03a-4b-manifest.txt`，
    /// tech-hold-02 英文），真值 1.2040816…。它长度比低是因为一半内容是
    /// 原样保留的代码标识符——那是正确行为，而且是本工具的主场景。
    /// 阈值抬到 1.21 以上这条就红。
    @Test("实测最小的那条正常译文放行")
    func observedMinimumPasses() {
        #expect(
            gate.check(
                source: Self.shortestSource,
                translation: Self.shortestTranslation,
                from: .chinese, to: .english) == .pass)
        #expect(
            TranslationMetrics.lengthRatio(
                source: Self.shortestSource, translation: Self.shortestTranslation)
                > gate.minimumLengthRatio,
            "阈值必须严格低于实测最小值")
    }

    /// **余量不能只有零个字符。**
    ///
    /// 上面那条样本是 59 显著字符 ÷ 49 = 1.2040816…，而计划原本给的阈值
    /// 正是 1.2 —— 1.2 × 49 = 58.8，译文少吐一个字母（58/49 = 1.1837）
    /// 就被误杀。**阈值恰好压在样本最小值上是教科书式的边界 bug**，
    /// 本仓库 M8 Task 2 刚在同一个坑里栽过。
    ///
    /// 这条用例把「余量」这个词变成机械可查的：从那条译文里去掉一个显著
    /// 字符，仍须放行。阈值写回 1.2 它就红。
    @Test("阈值对实测最小值留了不止一个字符的余量")
    func thresholdLeavesMarginBelowObservedMinimum() {
        let shorter = Self.droppingLastSignificantCharacter(Self.shortestTranslation)
        #expect(
            BenchMetrics.significantCharacters(shorter).count
                == BenchMetrics.significantCharacters(Self.shortestTranslation).count - 1,
            "辅助函数必须恰好少掉一个显著字符，否则这条用例验的不是它声称的东西")
        #expect(
            gate.check(source: Self.shortestSource, translation: shorter, from: .chinese, to: .english)
                == .pass)
    }

    // MARK: - 截断判据的前置条件

    /// **「原文自己得以句末标点收尾」这半个条件的守卫。**
    ///
    /// 用户松手早了、半句话就停了转写，原文本身没有句末标点，译文照实译
    /// 出来也不会有——那是正常输出，不是截断。删掉闸门里
    /// `!TruncationSignal.looksTruncated(source)` 那半句，本用例就红。
    @Test("原文自己没说完时，译文没说完不算截断")
    func unterminatedSourceDoesNotTriggerTruncation() {
        #expect(TruncationSignal.looksTruncated("我想订三张下周五的机票"), "原文本身就没有句末标点")
        #expect(
            gate.check(
                source: "我想订三张下周五的机票",
                translation: "I'd like to book three tickets for next Friday",
                from: .chinese, to: .english) == .pass)
    }

    /// 空译文也是「成功返回但没说完」，落进 `truncated`
    /// （`TruncationSignal` 把空串判为没说完，见它的注释）。
    @Test("空译文被拦下")
    func emptyTranslationIsRejected() {
        #expect(
            gate.check(source: "今天下午三点开会。", translation: "", from: .chinese, to: .english)
                == .reject(.truncated))
    }

    /// 原文也没有句末标点时截断判据不亮，空译文改由长度比兜住——
    /// 两条判据的接缝，缺一条就漏。
    @Test("原文没有句末标点时，空译文由长度比兜住")
    func emptyTranslationWithUnterminatedSourceFallsToLengthRatio() {
        #expect(
            gate.check(source: "我想订三张下周五的机票", translation: "", from: .chinese, to: .english)
                == .reject(.tooShort(ratio: 0)))
    }

    // MARK: - 分流

    @Test("中文目标不套拉丁判据")
    func nonLatinTargetPasses() {
        // 元断言：闸门靠这个属性分流，它要是 true，下面那条 pass 就没有意义了。
        #expect(Language.chinese.usesLatinScript == false)
        // 中文目标走自己的弱闸门（含汉字＋截断，见 chineseTargetRequiresHan 等），
        // 拉丁那四条判据一条都不套：这段译文中文标点、没句末标点（源同样没有，
        // 截断判据的前置条件不成立）、长度比 1.0，仍须放行。
        #expect(
            gate.check(source: "今天开会，三点", translation: "今天开会，三点", from: .chinese, to: .chinese)
                == .pass)
    }

    /// **今天这条断言恒真，而这正是它存在的理由——不假装它抓到了什么。**
    ///
    /// 闸门用 `usesLatinScript` 分流而不是 `requiresTranslation`，理由写在
    /// `check` 里。但两个属性今天在全部 7 个 case 上取值相同，也就是说
    /// 「把闸门里的 `usesLatinScript` 换成 `requiresTranslation`」这个变异
    /// **现在没有任何用例抓得到**（M8 Task 1 那条循环断言正是同款形态，
    /// 这里不重复那个错误）。
    ///
    /// 这条用例是根绊线：将来加日语（`usesLatinScript` = false、
    /// `requiresTranslation` = true）时它会变红，读到这段注释的人才会想起
    /// 去看闸门用的是哪一个——那一天两者的差别才开始要命。
    @Test("两个属性今天还等价——它们分家那天，回来看闸门用的是哪一个")
    func latinScriptAndRequiresTranslationStillAgree() {
        for target in Language.allCases {
            #expect(
                target.usesLatinScript == target.requiresTranslation,
                "\(target.rawValue) 上两个属性分家了：请回去确认 TranslationGate.check 的分流依据仍然是 usesLatinScript")
        }
    }

    @Test("六种拉丁字母语言的判据一致")
    func allLatinTargetsShareTheSameCriteria() {
        let latin = Language.allCases.filter(\.usesLatinScript)
        #expect(latin.count == 6, "少了语言的话下面的循环会静默地什么都不验")

        for target in latin {
            #expect(
                gate.check(
                    source: "今天下午三点开会。",
                    translation: "Meeting at 3pm today.",
                    from: .chinese, to: target) == .pass,
                "\(target.rawValue)")
            #expect(
                gate.check(
                    source: "今天下午三点开会。",
                    translation: "Meeting at 三点 today.",
                    from: .chinese, to: target) == .reject(.residualHan(count: 2)),
                "\(target.rawValue)")
        }
    }

    // MARK: - HUD 文案

    /// 「没说完」与「整段太短」是两种失败形态，Task 11 的 HUD 要分别说话。
    /// 五种成因的文案两两不同，且都说明了「已退回原文」——否则用户会以为
    /// 翻译开关没生效。（措辞不再说「中文原文」：源不恒为中文了，
    /// 见 `rejectionLabelsSayOriginalNotChinese`。）
    @Test("五种拒绝理由的 HUD 文案两两不同")
    func hudLabelsAreDistinct() {
        let labels = [
            TranslationRejection.residualHan(count: 1).hudLabel,
            TranslationRejection.chinesePunctuation(count: 1).hudLabel,
            TranslationRejection.truncated.hudLabel,
            TranslationRejection.tooShort(ratio: 0.5).hudLabel,
            TranslationRejection.noHan.hudLabel,
        ]
        #expect(Set(labels).count == labels.count)
        for label in labels { #expect(label.contains("退回原文")) }
    }

    // MARK: - 按 (源, 目标) 分流

    @Test func chineseTargetRequiresHan() {
        let gate = TranslationGate()
        // 整段没译（模型把英文原样吐回来）必须拦下。
        let verdict = gate.check(
            source: "Please review the fallback logic.",
            translation: "Please review the fallback logic.",
            from: .english, to: .chinese)
        #expect(verdict == .reject(.noHan))
    }

    @Test func chineseTargetPassesNormalTranslationWithTerms() {
        let gate = TranslationGate()
        // 中文译文合法保留英文术语——不查拉丁残留正是我们自己的规则。
        let verdict = gate.check(
            source: "Please review the fallback logic.",
            translation: "请检查一下 fallback 逻辑。",
            from: .english, to: .chinese)
        #expect(verdict == .pass)
    }

    @Test func latinToLatinSkipsLengthRatio() {
        let gate = TranslationGate(minimumLengthRatio: 99)  // 极端阈值：只要读了就必拦
        // 英→西的长度比天然在 1.0 附近，1.1 阈值是 zh→拉丁语料标定的，
        // 源非中文时不启用——否则正常译文大面积误杀。
        let verdict = gate.check(
            source: "Book three tickets for Friday.",
            translation: "Reserva tres billetes para el viernes.",
            from: .english, to: .spanish)
        #expect(verdict == .pass)
    }

    @Test func residualHanStillFiresForLatinTargetRegardlessOfSource() {
        let gate = TranslationGate()
        let verdict = gate.check(
            source: "Confirm the deployment.",
            translation: "Confirma el despliegue 部署.",
            from: .english, to: .spanish)
        #expect(verdict == .reject(.residualHan(count: 2)))
    }

    /// **M1 的守卫：非中文源 + 原文无句末标点（松手早）时，空译文不得静默放行。**
    ///
    /// 没有专门兜底的话，这条输入三条判据全部沉默：残留汉字 0、中文标点 0、
    /// 截断判据因 `!looksTruncated(source)` 前置不成立而跳过、长度比因
    /// 源非中文（未标定）不启用——`.pass` 意味着把一段空白静默注入。
    /// 今天 TEMP 桥恒传 `.chinese` 还踩不到，Task 6 接上真源语言就会活。
    @Test func emptyTranslationIsRejectedForLatinTargetFromLatinSource() {
        let gate = TranslationGate()
        let verdict = gate.check(
            source: "Book tickets",
            translation: "",
            from: .english, to: .spanish)
        #expect(verdict == .reject(.tooShort(ratio: 0)))
    }

    /// 变异验证 ④ 补的用例：把中文目标分支里的截断判据删掉，此前没有任何
    /// 用例会红。前置条件与拉丁分支同款：源自己有句末标点、译文没有。
    @Test func chineseTargetCatchesTruncation() {
        let gate = TranslationGate()
        let verdict = gate.check(
            source: "Confirm it.",
            translation: "请确认",
            from: .english, to: .chinese)
        #expect(verdict == .reject(.truncated))
    }

    @Test func rejectionLabelsSayOriginalNotChinese() {
        // 源不再恒为中文，「已退回中文原文」在英文输入下是错话。
        for rejection: TranslationRejection in [
            .residualHan(count: 1), .chinesePunctuation(count: 1),
            .truncated, .tooShort(ratio: 0.5), .noHan,
        ] {
            #expect(rejection.hudLabel.contains("已退回原文"))
            #expect(!rejection.hudLabel.contains("中文原文"))
        }
    }

    // MARK: - 素材

    /// 86 条 4B 正常译文里长度比最小的那条，出处见
    /// `TranslationGate.defaultMinimumLengthRatio` 的注释。
    private static let shortestSource =
        "你把 useMemo 换成 useCallback，然后在 Zustand 的 store 里加个 selector。"
    private static let shortestTranslation =
        "Change useMemo to useCallback, then add a selector in the Zustand store."

    /// 去掉最后一个显著字符（字母或数字），其余原样——句点留在原地，
    /// 免得顺手把截断判据也点着了。**结果由 `significantCharacters` 复核**，
    /// 见调用处。
    private static func droppingLastSignificantCharacter(_ text: String) -> String {
        var chars = Array(text)
        for index in stride(from: chars.count - 1, through: 0, by: -1)
        where chars[index].isLetter || chars[index].isNumber {
            chars.remove(at: index)
            break
        }
        return String(chars)
    }
}
