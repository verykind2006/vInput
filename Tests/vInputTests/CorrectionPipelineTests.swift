import Foundation
import Testing

@testable import vInput

/// 可编程的假校正器，用于驱动各条降级路径。
private final class FakeCorrector: Corrector, @unchecked Sendable {
    enum Behavior: Sendable {
        case edits([CorrectionEdit])
        case throwsError(CorrectorError)
        case hangs
    }

    let behavior: Behavior
    var prepareCallCount = 0

    init(_ behavior: Behavior) { self.behavior = behavior }

    func prepare() async throws {
        prepareCallCount += 1
        if case .throwsError(let error) = behavior, error == .modelNotReady {
            throw error
        }
    }

    func edits(for text: String) async throws -> [CorrectionEdit] {
        switch behavior {
        case .edits(let edits):
            return edits
        case .throwsError(let error):
            throw error
        case .hangs:
            try await Task.sleep(for: .seconds(60))
            return []
        }
    }
}

@Suite("校正流水线")
struct CorrectionPipelineTests {
    @Test("正常路径应用替换")
    func appliesCorrections() async {
        let pipeline = CorrectionPipeline(
            corrector: FakeCorrector(.edits([
                CorrectionEdit(original: "耀空气", replacement: "遥控器")
            ]))
        )
        let result = await pipeline.correct("小米耀空气")
        #expect(result == "小米遥控器")
    }

    // MARK: - 四条降级路径，均须注入原文

    @Test("模型未就绪时返回原文")
    func fallsBackWhenModelNotReady() async {
        let pipeline = CorrectionPipeline(
            corrector: FakeCorrector(.throwsError(.modelNotReady))
        )
        #expect(await pipeline.correct("小米耀空气") == "小米耀空气")
    }

    @Test("引擎报错时返回原文")
    func fallsBackWhenEngineFails() async {
        let pipeline = CorrectionPipeline(
            corrector: FakeCorrector(.throwsError(.engineFailed("boom")))
        )
        #expect(await pipeline.correct("小米耀空气") == "小米耀空气")
    }

    /// 超时是最重要的一条：本地推理慢于预期时，用户宁可拿到未校正的
    /// 原文，也不愿盯着 HUD 干等。
    @Test("超时返回原文")
    func fallsBackOnTimeout() async {
        let pipeline = CorrectionPipeline(
            corrector: FakeCorrector(.hangs),
            timeout: .milliseconds(100)
        )
        let start = ContinuousClock.now
        let result = await pipeline.correct("小米耀空气")
        let elapsed = ContinuousClock.now - start

        #expect(result == "小米耀空气")
        #expect(elapsed < .seconds(2), "应在超时后立即返回，实际耗时 \(elapsed)")
    }

    @Test("全部替换被闸门拦下时返回原文")
    func fallsBackWhenAllRejected() async {
        let pipeline = CorrectionPipeline(
            corrector: FakeCorrector(.edits([
                CorrectionEdit(original: "useEffect", replacement: "副作用钩子")
            ]))
        )
        #expect(await pipeline.correct("用 useEffect") == "用 useEffect")
    }

    @Test("空清单返回原文")
    func emptyEditsReturnOriginal() async {
        let pipeline = CorrectionPipeline(corrector: FakeCorrector(.edits([])))
        #expect(await pipeline.correct("没有错字") == "没有错字")
    }

    /// 空白输入不值得唤醒模型——加载一次 4B 模型的代价远大于这次校正的价值。
    @Test("空文本不调用模型")
    func skipsEmptyText() async {
        let corrector = FakeCorrector(.edits([]))
        let pipeline = CorrectionPipeline(corrector: corrector)
        #expect(await pipeline.correct("   ") == "   ")
        #expect(corrector.prepareCallCount == 0)
    }

    // MARK: - 加载与推理必须各算各的时间预算
    //
    // 这一组守着 Task 9.5 修掉的缺陷：加载模型曾和推理共用 3 秒预算。
    // 后果按加载是否响应取消分两种，都会让校正等于没开：
    // 可取消的加载每次跑到一半被 `cancelAll()` 掐断，永远等不到就绪；
    // 不可取消的加载则把 `correct` 一起拖住——任务组要等子任务收尾才会
    // 把超时错误抛出来，用户对着光标干等几十秒才拿到未校正的原文。

    @Test("加载慢于超时预算时不被取消，模型最终就绪")
    func loadOutlivesTimeoutBudget() async throws {
        // 用朴素校正器：它自己不做任何取消保护，加载能不能活下来
        // 完全取决于流水线有没有把它挪出超时窗口。
        let corrector = FakeSlowCorrector(
            loadDuration: .milliseconds(400),
            style: .naive,
            edits: [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
        )
        let pipeline = CorrectionPipeline(corrector: corrector, timeout: .milliseconds(50))

        // 首次校正撞上未就绪：退回原文，同时后台开始加载。
        #expect(await pipeline.correct("小米耀空气") == "小米耀空气")

        try await Task.sleep(for: .milliseconds(900))
        #expect(
            await corrector.counter.finished == 1,
            "加载被超时取消了——这正是「校正一次都不生效」的根因"
        )
        #expect(await corrector.isReady)

        // 就绪之后校正真的生效，而不是每次会话白烧一遍加载。
        #expect(await pipeline.correct("小米耀空气") == "小米遥控器")
    }

    @Test("模型未就绪时立即返回原文，不等加载")
    func returnsOriginalWithoutWaitingForLoad() async throws {
        // 不可取消的加载，对应 MLX 从本地目录读权重的真实情形。
        let corrector = FakeSlowCorrector(
            loadDuration: .milliseconds(800),
            edits: [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
        )
        let pipeline = CorrectionPipeline(corrector: corrector, timeout: .seconds(3))

        let start = ContinuousClock.now
        let result = await pipeline.correct("小米耀空气")
        let elapsed = ContinuousClock.now - start

        #expect(result == "小米耀空气")
        #expect(elapsed < .milliseconds(300), "不该等模型加载，实际耗时 \(elapsed)")

        // 没等它，但也没白等：加载在后台跑完，下一句就能校正。
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await corrector.counter.finished == 1)
        #expect(await pipeline.correct("小米耀空气") == "小米遥控器")
    }

    /// 拆掉加载的超时约束时，很容易顺手把推理的也拆了。这条守着它。
    @Test("模型就绪后推理超时仍退回原文")
    func inferenceStillTimesOutAfterModelReady() async {
        let corrector = FakeSlowCorrector(
            loadDuration: .zero,
            edits: [CorrectionEdit(original: "耀空气", replacement: "遥控器")],
            inferenceHangs: true
        )
        let pipeline = CorrectionPipeline(corrector: corrector, timeout: .milliseconds(100))
        await pipeline.warmUp()
        #expect(await corrector.isReady)

        let start = ContinuousClock.now
        let result = await pipeline.correct("小米耀空气")
        let elapsed = ContinuousClock.now - start

        #expect(result == "小米耀空气")
        #expect(elapsed < .seconds(2), "推理超时后应立即返回，实际耗时 \(elapsed)")
    }

    /// 未就绪时流水线会顺手补一次后台加载。连说几句不能变成连加载几次。
    @Test("加载期间反复校正只触发一次加载")
    func repeatedCorrectionsLoadOnce() async throws {
        let corrector = FakeSlowCorrector(loadDuration: .milliseconds(400))
        let pipeline = CorrectionPipeline(corrector: corrector, timeout: .milliseconds(50))

        for _ in 0..<3 {
            #expect(await pipeline.correct("小米耀空气") == "小米耀空气")
        }

        try await Task.sleep(for: .milliseconds(900))
        #expect(await corrector.counter.started == 1)
    }

    @Test("预热后模型就绪")
    func warmUpMakesCorrectorReady() async {
        let corrector = FakeSlowCorrector(
            loadDuration: .milliseconds(50),
            edits: [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
        )
        let pipeline = CorrectionPipeline(corrector: corrector)

        #expect(await corrector.isReady == false)
        await pipeline.warmUp()
        #expect(await corrector.isReady)
        #expect(await pipeline.correct("小米耀空气") == "小米遥控器")
    }
}
