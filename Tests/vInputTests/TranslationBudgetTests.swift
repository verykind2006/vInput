import Foundation
import Testing

@testable import vInput

/// 翻译预算随长度放大。
///
/// 这套用例钉的是 2026-08-19 那轮分档实测得出的结论，**每一条都对着
/// 实测数字写，不是拍的**（数据见 `TranslationBudget` 的文档注释）。
@Suite("翻译预算")
struct TranslationBudgetTests {
    /// **190 字左右是老的 8 秒预算被击穿的地方。**
    ///
    /// 实测：191 字要 7.1 秒（贴着线），315 字要 11.1 秒（超）。
    /// 这条钉住「放大之后这两档都够用」——把系数调回 0 或者把放大整个删掉，
    /// 它就会红。
    @Test("实测过的三档长文本都拿得到够用的预算")
    func measuredLongformLengthsGetEnoughTime() {
        // 实测耗时，来自 Bench/translate-longform.json 那一轮。
        let measured: [(chars: Int, seconds: Double)] = [
            (191, 7.1), (315, 11.1), (589, 24.7),
        ]
        for case let (chars, seconds) in measured {
            let budget = TranslationBudget.scaled(forCharacters: chars)
            #expect(
                budget > .seconds(seconds),
                "\(chars) 字实测要 \(seconds) 秒，预算只给了 \(budget)"
            )
        }
    }

    /// 短句的预算不该超过下限——那一档本来就够，放大它只会让失败路径拖更久。
    ///
    /// 实测：基准集最长 64 字、单句最长耗时 4.9 秒（德语）。
    @Test("基准集那个量级的短句用不到放大")
    func shortTextStaysAtTheFloor() {
        // 64 字 × 0.05 = 3.2 秒，低于 8 秒下限，因此由调用方的下限接管。
        #expect(TranslationBudget.scaled(forCharacters: 64) < TranslationBudget.floor)
        #expect(TranslationBudget.scaled(forCharacters: 37) < TranslationBudget.floor)
    }

    /// **上限必须封死。**
    ///
    /// 不封的话，一段异常长的文本会把串行的模型容器占死几分钟——而超时
    /// 并不会真的停下推理（取消传不进 MLX），所以这个数同时也是
    /// 「最坏情况下后面那句话要等多久」。
    @Test("再长也不超过上限")
    func ceilingIsEnforced() {
        for chars in [1_000, 10_000, 1_000_000] {
            #expect(TranslationBudget.scaled(forCharacters: chars) <= TranslationBudget.ceiling)
        }
        // 上限本身也钉住：改成 5 分钟时这条会红。
        #expect(TranslationBudget.ceiling == .seconds(30))
    }

    /// **只夹上限，不夹下限。**
    ///
    /// 在这里再夹一次下限的话，`TranslationPipeline` 的 `timeout` 构造参数
    /// 就变成「只能抬不能降」——显式传一个小超时会被无声忽略，而那正是
    /// 测试验证超时路径的手段。这个错误我犯过一次，被
    /// `TranslationPipelineTests` 的超时用例当场拦下。
    @Test("短到极致时不被抬到下限")
    func doesNotClampUpwards() {
        #expect(TranslationBudget.scaled(forCharacters: 0) < TranslationBudget.floor)
        #expect(TranslationBudget.scaled(forCharacters: 1) < TranslationBudget.floor)
    }

    /// 单调不减：字越多给的时间不能反而变少。
    @Test("预算随字数单调不减")
    func monotonic() {
        var previous = Duration.zero
        for chars in stride(from: 0, through: 1_200, by: 37) {
            let budget = TranslationBudget.scaled(forCharacters: chars)
            #expect(budget >= previous, "\(chars) 字的预算比更短的还少")
            previous = budget
        }
    }

    // MARK: - token 上限

    /// **589 字那一条实测贴着 512 的天花板**（译文 2459 字符 ≈ 470–560 token）。
    /// 放大之后必须离开天花板，否则再长一点就是静默截断。
    @Test("实测贴着天花板的那一档拿到明显更高的上限")
    func longformGetsHeadroomAboveTheOldCeiling() {
        let budget = TranslationBudget.maxTokens(forCharacters: 589)
        #expect(budget > 560, "589 字实测要 470–560 token，上限只给了 \(budget)")
        // 两倍余量：给大的代价很小（限不住耗时），给小的代价是静默截断。
        #expect(budget >= 589 * 2)
    }

    /// 短句照旧 512，与改动前逐字一致。
    @Test("短句的 token 上限不变")
    func shortTextKeepsTheOldTokenCeiling() {
        #expect(TranslationBudget.maxTokens(forCharacters: 37) == 512)
        #expect(TranslationBudget.maxTokens(forCharacters: 64) == 512)
        #expect(TranslationBudget.minimumTokens == 512)
    }

    /// token 上限同样单调不减。
    @Test("token 上限随字数单调不减")
    func tokenBudgetMonotonic() {
        var previous = 0
        for chars in stride(from: 0, through: 1_200, by: 37) {
            let budget = TranslationBudget.maxTokens(forCharacters: chars)
            #expect(budget >= previous)
            previous = budget
        }
    }

    /// **token 上限不设天花板是有意的。**
    ///
    /// 它限的是单次推理长度，限不住耗时——真正的时间闸门在 `scaled` 那一侧。
    /// 给它也封一个顶的话，长文本会先撞 token 上限被静默截断，
    /// 而那种失败与超时半途而废长得一模一样，事后分不开。
    @Test("token 上限不封顶")
    func tokenBudgetHasNoCeiling() {
        #expect(TranslationBudget.maxTokens(forCharacters: 10_000) >= 20_000)
    }
}

/// 流水线**真的按文本长度放大预算**。
///
/// 上面那套用例只验了预算函数自己算得对；把流水线里那一句改回
/// `let budget = timeout`（不放大），它们一条都不会红——实测确认过。
/// 这一条补的就是那个洞。
///
/// 手法：同一个假翻译器固定睡 300 毫秒，下限压到 1 毫秒，于是预算完全由
/// 长度决定。**短文本超时、长文本成功，两者的差别只能来自放大。**
@Suite("流水线按长度放大预算")
struct TranslationPipelineBudgetTests {
    /// 译文要够长才过得了闸门的长度比（下限 1.1，实测最小 1.2040816）。
    /// 第一版写了一句 21 个字符的英文对 20 个中文字，比值 0.85——
    /// 被闸门当成漏译拦下，用例红在了一个与预算无关的地方。**闸门是对的。**
    private static let output = String(
        repeating: "We will meet at three this afternoon. ", count: 3)

    private func pipeline(delay: Duration) -> TranslationPipeline {
        TranslationPipeline(
            translator: FakeTranslator(.slow(delay, Self.output)),
            // 下限压到 1 毫秒：不压的话 8 秒下限会盖过长度的影响，
            // 这条用例就退化成「等 8 秒然后成功」，什么都没验到。
            timeout: .milliseconds(1)
        )
    }

    /// 4 个字 × 0.05 = 0.2 秒 < 0.3 秒的延迟 → 超时。
    @Test("短文本的预算不够，超时退回中文")
    func shortTextTimesOut() async {
        let result = await pipeline(delay: .milliseconds(300))
            .translate("今天开会", to: .english)
        #expect(result.annotation == .timedOut)
        #expect(result.text == "今天开会")
    }

    /// 20 个字 × 0.05 = 1.0 秒 > 0.3 秒的延迟 → 来得及。
    ///
    /// **同一个延迟、同一个翻译器，只有文本长度不同。** 这条过而上面那条
    /// 超时，证明的正是「预算随长度走」这件事本身。
    @Test("长文本拿到更多时间，同一个延迟就来得及了")
    func longerTextGetsMoreTime() async {
        let long = String(repeating: "今天开会", count: 5)   // 20 字
        let result = await pipeline(delay: .milliseconds(300)).translate(long, to: .english)
        #expect(result.annotation == nil, "长文本没拿到放大的预算：\(String(describing: result.annotation))")
        #expect(result.text == Self.output)
    }
}
