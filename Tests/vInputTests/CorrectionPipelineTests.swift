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

    /// 超时必须真的中断等待，而不是等工作自然结束。
    ///
    /// 这条测试存在的理由：原实现用 TaskGroup，而 TaskGroup 在重抛错误前
    /// 会等所有子任务收尾。若传进去的工作不响应取消，超时就形同虚设——
    /// `correct` 会一直等到工作跑完。真机上这意味着用户说完话后盯着
    /// 「正在校正」干等十几秒，以为程序卡死。
    ///
    /// 假对象必须用**不响应取消**的忙等，不能用 `Task.sleep`——后者可取消，
    /// 测不出这个问题。
    @Test("工作不响应取消时，超时仍在预算内返回")
    func timeoutReturnsEvenIfWorkIgnoresCancellation() async {
        let pipeline = CorrectionPipeline(
            corrector: UncancellableCorrector(inferenceSeconds: 2.0),
            timeout: .milliseconds(200)
        )
        let start = ContinuousClock.now
        let result = await pipeline.correct("小米耀空气")
        let elapsed = ContinuousClock.now - start

        #expect(result == "小米耀空气")
        #expect(
            elapsed < .milliseconds(800),
            "超时应在预算内返回，实际耗时 \(elapsed)——说明等到了工作自然结束"
        )
    }

    // MARK: - 被放弃的推理不得堆积
    //
    // 这一组守着 QA 探针实测出来的缺陷：超时只是「不等它」，那次推理仍会
    // 跑完，而 `ModelContainer.perform` 串行——每超时一次就往队列里塞一个
    // 必然被丢弃的推理，队列单调增长，校正从此永不可能成功。
    // 修复前的实测（超时 300ms、单次推理 1s、连续 5 次）：
    // 已启动 1→2→3→4→5，6 秒后 5 次推理全部白烧。

    @Test("上一次推理还在跑时，本次直接返回原文")
    func skipsWhileInferenceInFlight() async {
        let corrector = SerialBusyCorrector(inferenceSeconds: 1.0)
        let pipeline = CorrectionPipeline(corrector: corrector, timeout: .milliseconds(200))

        // 第一次：超时放弃，但推理还占着串行队列。
        #expect(await pipeline.correct("小米耀空气") == "小米耀空气")

        let start = ContinuousClock.now
        let result = await pipeline.correct("小米耀空气")
        let elapsed = ContinuousClock.now - start

        #expect(result == "小米耀空气")
        #expect(
            elapsed < .milliseconds(50),
            "第二次应立刻跳过而不是排队等推理，实际耗时 \(elapsed)"
        )
        let started = await corrector.counter.started
        #expect(started == 1, "跳过就不该再发起推理，实际发起了 \(started) 次")
    }

    @Test("连续超时不会让被放弃的推理堆积")
    func abandonedInferencesDoNotPileUp() async {
        let corrector = SerialBusyCorrector(inferenceSeconds: 1.0)
        let pipeline = CorrectionPipeline(corrector: corrector, timeout: .milliseconds(200))

        for _ in 0..<5 {
            #expect(await pipeline.correct("小米耀空气") == "小米耀空气")
        }
        let started = await corrector.counter.started
        #expect(started == 1, "5 次调用只该白烧一次推理，实际 \(started) 次")
    }

    /// 跳过必须是暂时的：推理落地后，下一句得能正常校正，否则等于永久关掉校正。
    @Test("在途推理落地后恢复正常校正")
    func recoversAfterInferenceLands() async throws {
        // 第一次推理慢到必然超时，之后的快到能进预算——否则第三次只是又
        // 超时一遍，测不出「闸门开回来了」。
        let corrector = SerialBusyCorrector(inferenceSeconds: 0.5, laterInferenceSeconds: 0.02)
        let pipeline = CorrectionPipeline(corrector: corrector, timeout: .milliseconds(100))

        #expect(await pipeline.correct("小米耀空气") == "小米耀空气")
        #expect(await pipeline.correct("小米耀空气") == "小米耀空气")

        // 等那次被放弃的推理跑完，闸门应自己开回来。
        try await Task.sleep(for: .milliseconds(900))
        #expect(await corrector.counter.finished == 1)

        #expect(await pipeline.correct("小米耀空气") == "小米遥控器")
        #expect(await corrector.counter.started == 2)
    }

    /// 加闸门最容易误伤的就是最常见的那条路：一句接一句地说，每句都该校正。
    @Test("串行调用不受闸门影响")
    func serialCallsAreUnaffected() async {
        let corrector = SerialBusyCorrector(inferenceSeconds: 0.05)
        let pipeline = CorrectionPipeline(corrector: corrector, timeout: .seconds(3))

        #expect(await pipeline.correct("小米耀空气") == "小米遥控器")
        #expect(await pipeline.correct("小米耀空气") == "小米遥控器")
        #expect(await corrector.counter.started == 2)
    }

    /// 最刁的一种：消费侧响应取消、生产侧不响应——真实 `MLXCorrector` 正是如此。
    ///
    /// 若超时后顺手把推理任务取消掉，`edits(for:)` 会提前抛错返回，闸门以为
    /// 「落地了」而提前开——可 GPU 上那次生成还在跑，还占着 `ModelContainer`
    /// 的串行队列，堆积照旧。这条测试守着「刻意不取消」这个决定。
    @Test("消费侧提前退出不会让闸门提前开")
    func gateWaitsForProducerNotConsumer() async throws {
        let corrector = CancelAwareCorrector(inferenceSeconds: 1.0)
        let pipeline = CorrectionPipeline(corrector: corrector, timeout: .milliseconds(200))

        #expect(await pipeline.correct("小米耀空气") == "小米耀空气")
        // 隔一会儿再问第二次：若流水线取消了推理任务，消费侧要几毫秒才
        // 察觉并退出，紧挨着问会侥幸通过。这里等到它一定退干净，
        // 而生产方（1 秒）还牢牢占着队列。
        try await Task.sleep(for: .milliseconds(100))
        #expect(await pipeline.correct("小米耀空气") == "小米耀空气")
        let started = await corrector.counter.started
        #expect(started == 1, "生产方还占着队列就放行了第二次推理，实际发起 \(started) 次")
    }
}

/// 推理串行且不响应取消的假校正器——与真实 `MLXCorrector` 同构。
///
/// 串行来自 `ModelContainer.perform`，不响应取消来自 MLX 的同步推理循环
/// （`Evaluate.swift:597-646`）。用 `Thread.sleep` 而非 `Task.sleep`：
/// 后者可取消，模拟的是另一种东西。
private final class SerialBusyCorrector: Corrector, @unchecked Sendable {
    let counter = InferenceCounter()

    private let queue = DispatchQueue(label: "test.serial-corrector")
    private let inferenceSeconds: Double
    /// 第二次起的推理耗时。默认与首次相同。
    private let laterInferenceSeconds: Double

    init(inferenceSeconds: Double, laterInferenceSeconds: Double? = nil) {
        self.inferenceSeconds = inferenceSeconds
        self.laterInferenceSeconds = laterInferenceSeconds ?? inferenceSeconds
    }

    func prepare() async throws {}

    func edits(for text: String) async throws -> [CorrectionEdit] {
        let index = await counter.noteStart()
        let seconds = index == 1 ? inferenceSeconds : laterInferenceSeconds
        let counter = self.counter
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                Thread.sleep(forTimeInterval: seconds)
                Task { await counter.noteFinish() }
                continuation.resume()
            }
        }
        return [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
    }
}

/// 消费侧响应取消、生产侧不响应的假校正器。
///
/// 对应真实情形：`edits(for:)` 里的 `try Task.checkCancellation()` 一被取消
/// 就抛错返回，可 `ChatSession.stream()` 内部那个非结构化 Task 照样把
/// `ModelContainer` 的串行队列占到跑完。
private final class CancelAwareCorrector: Corrector, @unchecked Sendable {
    let counter = InferenceCounter()

    private let queue = DispatchQueue(label: "test.cancel-aware-corrector")
    private let inferenceSeconds: Double

    init(inferenceSeconds: Double) {
        self.inferenceSeconds = inferenceSeconds
    }

    func prepare() async throws {}

    func edits(for text: String) async throws -> [CorrectionEdit] {
        await counter.noteStart()
        let done = DoneFlag()
        let seconds = inferenceSeconds
        let counter = self.counter
        queue.async {
            // 生产方：取消与它无关，占满队列跑完为止。
            Thread.sleep(forTimeInterval: seconds)
            Task { await counter.noteFinish() }
            done.set()
        }
        // 消费方：一被取消就撂挑子。
        while !done.value {
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
    }
}

/// 记录推理被发起、完成了多少次。
private actor InferenceCounter {
    private(set) var started = 0
    private(set) var finished = 0

    /// 返回这是第几次推理，供替身按次改变行为。
    @discardableResult
    func noteStart() -> Int {
        started += 1
        return started
    }

    func noteFinish() { finished += 1 }
}

/// 跨线程读写的完成标志。
private final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// 推理不响应取消的假校正器。
///
/// 用忙等而非 `Task.sleep`：`Task.sleep` 响应取消，而真实的 MLX 同步推理
/// 循环不响应。要测「超时是否真的能中断等待」，替身必须模仿后者。
private final class UncancellableCorrector: Corrector, @unchecked Sendable {
    private let inferenceSeconds: Double

    init(inferenceSeconds: Double) {
        self.inferenceSeconds = inferenceSeconds
    }

    func prepare() async throws {}

    func edits(for text: String) async throws -> [CorrectionEdit] {
        let deadline = Date().addingTimeInterval(inferenceSeconds)
        while Date() < deadline {
            // 刻意不检查 Task.isCancelled——模仿真实 MLX 同步推理循环
        }
        return [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
    }
}
