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
}
