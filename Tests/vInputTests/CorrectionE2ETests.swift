import Foundation
import Testing

@testable import vInput

/// 校正端到端体检。需要真实模型，默认跳过。开启方式：
///
/// ```bash
/// VINPUT_E2E=1 VINPUT_CORRECTION_MODEL=/path/to/model ./scripts/test.sh
/// ```
///
/// 与 `PipelineE2ETests` 同一门控方式：真实模型加载耗时且占内存，
/// 不该拖慢每次改动都要跑的单元测试。
///
/// 存在的理由是 M4 本身的理由——真机案例：说「小米遥控器」，Whisper
/// 输出「小米耀空气」。单元测试用假 Corrector 只能验证管线的接线是否正确
/// （超时、闸门、失败退回原文），验证不了模型本身是否真的能修对、
/// 会不会误伤本就正确的句子。这两件事只能拿真模型测。
@Suite(
    "校正端到端",
    .enabled(if: ProcessInfo.processInfo.environment["VINPUT_E2E"] == "1")
)
struct CorrectionE2ETests {
    /// 用 `static let` 而不是每条用例各自 new 一个：三条用例共享同一个
    /// corrector 实例，`MLXCorrector` 内部靠 `OneShotLoader` 判重，
    /// 只有第一次 `prepare()` 真的触发加载，后两次立即返回——不然三条
    /// 用例各花几十秒重复加载同一份 2GB 模型。
    ///
    /// 环境变量缺失时置 nil，交给 `makePipeline()` 里的 `#require`
    /// 给出清晰提示，而不是在这里让整个 suite 崩掉。
    private static let corrector: MLXCorrector? = {
        guard let path = ProcessInfo.processInfo.environment["VINPUT_CORRECTION_MODEL"] else {
            return nil
        }
        return MLXCorrector(modelDirectory: URL(fileURLWithPath: path))
    }()

    /// 先等模型真正就绪，再返回可用的管线。
    ///
    /// Task 9.5 之后 `CorrectionPipeline.correct` 在模型未就绪时会立即
    /// 退回原文、转去后台补加载——如果这里不先 `await prepare()`，
    /// 三条用例的第一次调用必然只测出「原样返回」，测不出模型的任何行为。
    private func makePipeline() async throws -> CorrectionPipeline {
        let corrector = try #require(
            Self.corrector,
            "需设置 VINPUT_CORRECTION_MODEL 指向本地模型目录"
        )
        try await corrector.prepare()

        // 超时给够 120 秒：这里只约束单次推理，模型加载已经在上一行的
        // prepare() 里做完、不受此超时约束（Task 9.5 的修复）。真给
        // 一次推理 120 秒仍不够，说明的是模型或提示词有问题，而不是
        // 超时设短了。
        return CorrectionPipeline(corrector: corrector, timeout: .seconds(120))
    }

    @Test("修正真机出现过的同音错误")
    func fixesKnownMishearing() async throws {
        let pipeline = try await makePipeline()
        // 这就是 M4 存在的理由：真机上 Whisper 把「遥控器」听成「耀空气」。
        let result = await pipeline.correct("小米耀空气很好用")
        #expect(result.contains("遥控器"), "实际输出：\(result)")
    }

    @Test("不翻译英文术语")
    func preservesEnglishTerms() async throws {
        let pipeline = try await makePipeline()
        // 验证拼音闸门在真实模型上同样生效：模型可能想把 useEffect
        // 「修正」成别的东西，闸门必须拦住这种非同音替换。
        let result = await pipeline.correct("把这个变量改成 useEffect")
        #expect(result.contains("useEffect"), "实际输出：\(result)")
    }

    @Test("正确的句子不被改动")
    func leavesCorrectSentenceUnchanged() async throws {
        let pipeline = try await makePipeline()
        // 比「能改对」更重要：改坏原本正确的内容，比漏改一个错字严重得多。
        let input = "今天天气不错，我们出去走走吧"
        let result = await pipeline.correct(input)
        #expect(result == input, "实际输出：\(result)")
    }

    /// 直接对照：同一句话，经过校正与不经过校正，结果必须不同。
    ///
    /// 这条是 M4 验收标准「同一句话开关校正能看出差别」的直接翻译。
    /// 上面几条在「校正压根没跑」时也会通过——「不翻译英文术语」与
    /// 「正确的句子不被改动」，管线原样返回时同样成立。只有这一条
    /// 能证伪「校正实际上从未生效」。
    @Test("开与关的结果必须不同")
    func correctionMakesADifference() async throws {
        let pipeline = try await makePipeline()
        let input = "小米耀空气很好用"
        let corrected = await pipeline.correct(input)

        // 关闭校正时管线直接返回原文，因此原文本身就代表「关」那条
        // 路径的结果，不需要另外跑一条不经校正的路径。
        #expect(
            corrected != input,
            "开关校正结果相同，说明校正实际未生效。实际输出：\(corrected)"
        )
    }

    /// 确有替换被闸门放行并应用了。
    ///
    /// 与上一条互补：上一条证明「文本变了」，这一条证明「是校正层改的」，
    /// 排除文本因其他原因发生变化的可能。失败信息里带上模型给出的建议与
    /// 被闸门拦下的部分，方便直接判断是模型没给建议、还是闸门太严。
    @Test("确有替换被采纳")
    func atLeastOneEditApplied() async throws {
        let corrector = try #require(
            Self.corrector,
            "需设置 VINPUT_CORRECTION_MODEL 指向本地模型目录"
        )
        try await corrector.prepare()

        let input = "小米耀空气很好用"
        let edits = try await corrector.edits(for: input)
        #expect(!edits.isEmpty, "模型未给出任何替换建议")

        let outcome = CorrectionGate.apply(edits, to: input)
        #expect(
            !outcome.applied.isEmpty,
            "全部建议都被闸门拦下。建议=\(edits) 拦下=\(outcome.rejected)"
        )
    }
}
