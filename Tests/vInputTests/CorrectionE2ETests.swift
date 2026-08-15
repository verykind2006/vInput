import Foundation
import Testing

@testable import vInput

/// 校正端到端体检。需要真实模型，默认跳过。
///
/// **必须用 `xcodebuild` 跑，不能用 `swift build` / `swift test`。**
/// SwiftPM 命令行无法编译 mlx-swift 的 Metal 着色器（见其 README 与
/// `docs/dev-dependencies.md`），MLX 会在运行时报
/// `Failed to load the default metallib` 而整个测试进程中止。
///
/// ```bash
/// touch Testing/.e2e-enabled
/// xcodebuild test -scheme vInput -destination "platform=OS X" \
///     -only-testing:vInputTests/CorrectionE2ETests
/// ```
///
/// **门控用标记文件而非环境变量。** `xcodebuild test` 不把父进程的环境
/// 变量传给测试运行器（`TEST_RUNNER_` 前缀对 SwiftPM 包也无效），实测
/// 结果是整个套件被静默跳过、而 xcodebuild 照样报 `TEST SUCCEEDED`、
/// 退出码 0——一个几乎无法察觉的假绿灯。标记文件不经过任何进程间传递，
/// 两种构建方式下行为一致。
///
/// 存在的理由是 M4 本身的理由——真机案例：说「小米遥控器」，Whisper
/// 输出「小米耀空气」。单元测试用假 Corrector 只能验证管线的接线是否正确
/// （超时、闸门、失败退回原文），验证不了模型本身是否真的能修对、
/// 会不会误伤本就正确的句子。这两件事只能拿真模型测。
/// **必须串行。** Swift Testing 默认并行跑用例，而多条用例同时向同一个
/// MLX 模型发起推理会让 Metal 崩掉：
/// `-[_MTLCommandBuffer commit]: failed assertion 'commit an already
/// committed command buffer'`。`ModelContainer.perform` 只保证模型访问
/// 串行，保证不了 Metal 命令缓冲区层面的并发安全。
///
/// 崩溃后 xcodebuild 会重跑一次、跑 0 条用例、报 "passed"——只有退出码
/// 65 能看出不对，是个很容易骗过人的假绿灯。
@Suite("校正端到端", .enabled(if: E2EGate.isEnabled), .serialized)
struct CorrectionE2ETests {
    /// 用 `static let` 而不是每条用例各自 new 一个：三条用例共享同一个
    /// corrector 实例，`MLXCorrector` 内部靠 `OneShotLoader` 判重，
    /// 只有第一次 `prepare()` 真的触发加载，后两次立即返回——不然三条
    /// 用例各花几十秒重复加载同一份 2GB 模型。
    ///
    /// 环境变量缺失时置 nil，交给 `makePipeline()` 里的 `#require`
    /// 给出清晰提示，而不是在这里让整个 suite 崩掉。
    private static let corrector: MLXCorrector? = {
        guard let directory = E2EGate.modelDirectory else { return nil }
        return MLXCorrector(modelDirectory: directory)
    }()

    /// 先等模型真正就绪，再返回可用的管线。
    ///
    /// Task 9.5 之后 `CorrectionPipeline.correct` 在模型未就绪时会立即
    /// 退回原文、转去后台补加载——如果这里不先 `await prepare()`，
    /// 三条用例的第一次调用必然只测出「原样返回」，测不出模型的任何行为。
    private func makePipeline() async throws -> CorrectionPipeline {
        let corrector = try #require(
            Self.corrector,
            "模型不在默认位置，见 E2EGate.defaultModelDirectory"
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

    /// 同一条管线连说两句，两句都要被校正。
    ///
    /// 守着「在途闸门」（`InFlightGate`）在真实模型上确实会开回来：闸门在
    /// 推理任务结束时开，而真实的 `MLXCorrector` 是读完 `ChatSession` 的
    /// 流才返回——假替身模仿得再像，也不如拿真流跑一遍。若闸门开不回来，
    /// 第二句会被直接跳过、原样返回，等于校正只对每台机器的第一句生效。
    ///
    /// 上面几条都各自新建管线（各自一个新闸门），漏得掉这个问题。
    @Test("同一条管线连续两次校正都生效")
    func consecutiveCorrectionsOnSamePipeline() async throws {
        let pipeline = try await makePipeline()
        let input = "小米耀空气很好用"

        let first = await pipeline.correct(input)
        #expect(first != input, "第一次就没校正。实际输出：\(first)")

        let second = await pipeline.correct(input)
        #expect(second != input, "第二次被跳过了——闸门没开回来。实际输出：\(second)")
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
            "模型不在默认位置，见 E2EGate.defaultModelDirectory"
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

/// 端到端体检的开关与模型位置。
///
/// 刻意不走环境变量：`xcodebuild test` 不把父进程环境传给测试运行器，
/// 实测会让整个套件被静默跳过而仍报 `TEST SUCCEEDED`。标记文件不经过
/// 任何进程间传递，`swift test` 与 `xcodebuild test` 下行为一致。
enum E2EGate {
    /// 仓库根目录下的标记文件。已在 .gitignore 中排除——它是本机开关，
    /// 不该跟着提交跑到别人机器上。
    static let markerPath = "Testing/.e2e-enabled"

    /// 默认模型位置：仓库内的 `Models/`。
    ///
    /// 与标记文件一样用 `#filePath` 回溯仓库根，不依赖进程的当前工作目录
    /// ——`swift test` 与 `xcodebuild test` 下的 cwd 并不相同。
    static var defaultModelDirectory: URL {
        repositoryRoot
            .appendingPathComponent("Models/qwen3-4b-instruct-2507-4bit", isDirectory: true)
    }

    /// 仓库根目录。
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // vInputTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
    }

    /// 从测试文件位置回溯仓库根，再拼标记文件路径。
    ///
    /// 用 `#filePath` 而非当前工作目录：测试进程的 cwd 在 `swift test`
    /// 与 `xcodebuild test` 下并不相同。
    static var isEnabled: Bool {
        FileManager.default.fileExists(
            atPath: repositoryRoot.appendingPathComponent(markerPath).path
        )
    }

    /// 模型目录。不存在时返回 nil，由用例的 `#require` 给出清晰提示。
    static var modelDirectory: URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: defaultModelDirectory.path, isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return defaultModelDirectory
    }
}
