import Foundation
import Testing

@testable import vInput

/// `TruncationSignal` 的用例。
///
/// **2026-08-18 随判据一起从 `TranslationSweepTests.swift` 搬过来**：判据进了
/// 生产（`Sources/vInput/Translate/TruncationSignal.swift`），用例跟着走。
/// 下面那两条「真实观测」不是编的句子，注释里写了它们的出处——搬家时一个
/// 字都没改，否则「实测支撑」这句话就不成立了。
@Suite("疑似截断的判据")
struct TruncationSignalTests {
    @Test("完整句子不报")
    func completeSentence() {
        #expect(!TruncationSignal.looksTruncated("The unit price is twelve dollars."))
        #expect(!TruncationSignal.looksTruncated("¿Cuál es el precio?"))
        #expect(!TruncationSignal.looksTruncated("Zahl bitte!"))
    }

    @Test("句末标点后挂引号括号不报")
    func trailingClosersAreFine() {
        #expect(!TruncationSignal.looksTruncated("He said \"go home.\""))
        #expect(!TruncationSignal.looksTruncated("（见上文。）"))
        #expect(!TruncationSignal.looksTruncated("Fine.  \n"))
    }

    /// **这三条是真实观测，不是编的句子。**
    ///
    /// 2026-08-18 实测：`qwen2.5-7b-instruct-4bit`，
    /// `./scripts/translate-sweep.sh qwen2.5-7b-instruct-4bit en --limit 3 --max-tokens 5`，
    /// 三条技术类样本撞上限后的原始输出照抄如下。同一批样本在 `maxTokens=512`
    /// 下的输出分别是 102 / 114 / 89 字的完整句子，全部以句点收尾、本判据一条
    /// 不报——**「5 全报、512 全不报」这个对照就是这条判据不空的证据**，
    /// 而不是我挑了三个必然通过的字符串。
    ///
    /// 顺带量到了这个模型英文输出的 token 密度：22/26/25 字 ÷ 5 token
    /// ≈ 4.4–5.2 字每 token。Task 4 拿它把「译文字数」换算成 token 数，
    /// 判断 512 到底留了多少余量。
    @Test("撞上限的半截译文会被报出来")
    func realTruncatedOutput() {
        #expect(TruncationSignal.looksTruncated("There is an issue with"))
        #expect(TruncationSignal.looksTruncated("We write code using Claude"))
        #expect(TruncationSignal.looksTruncated("Change the return type of"))
    }

    /// 对照的另一半：同一批样本不撞上限时的完整输出，一条都不该报。
    ///
    /// 少了这一半，上面那条用「全都报」也能满分——一个恒返回 true 的实现
    /// 会让它全绿，而那正是本仓库栽过七次的那类空判据。
    @Test("同一批样本不撞上限时一条都不报")
    func realCompleteOutput() {
        #expect(
            !TruncationSignal.looksTruncated(
                "There is an issue with the code of this component, we need to add a "
                    + "dependency array in the useEffect."))
        #expect(
            !TruncationSignal.looksTruncated(
                "We write code using Claude Code, then use GitHub Actions for continuous "
                    + "integration, and finally deploy it to AWS."))
        #expect(
            !TruncationSignal.looksTruncated(
                "Change the return type of this function to Promise, then add error "
                    + "handling in the catch."))
    }

    @Test("空输出算没说完")
    func emptyIsSuspect() {
        #expect(TruncationSignal.looksTruncated(""))
        #expect(TruncationSignal.looksTruncated("   \n "))
        #expect(TruncationSignal.looksTruncated("\"\""))
    }
}
