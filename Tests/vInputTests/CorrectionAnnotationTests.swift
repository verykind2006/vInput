import Foundation
import Testing

@testable import vInput

/// 可编程的假校正器。
private final class StubCorrector: Corrector, @unchecked Sendable {
    var stubEdits: [CorrectionEdit] = []
    var thrownError: Error?
    var ready = true
    var delay: Duration = .zero

    var isReady: Bool { get async { ready } }

    func prepare() async throws {}

    func edits(for text: String) async throws -> [CorrectionEdit] {
        if delay > .zero { try? await Task.sleep(for: delay) }
        if let thrownError { throw thrownError }
        return stubEdits
    }
}

/// M6 ③：HUD 要能区分「模型还在加载」与「已运行但没改动」。
///
/// **只有这两种**（2026-08-17 用户决定）。此前三种情况（加载中、解析不出
/// 替换、被闸门全拦）用户都只看到「没变化」，无从判断是哪一种；而前两者
/// 的区别对用户是实的——一个能等，一个是正常工作。
@Suite("校正结果的 HUD 标注")
struct CorrectionAnnotationTests {
    @Test("模型未就绪时标注为「还在加载」")
    func annotatesModelLoading() async {
        let corrector = StubCorrector()
        corrector.ready = false
        let pipeline = CorrectionPipeline(corrector: corrector)

        let result = await pipeline.correct("小米耀空气")

        #expect(result.text == "小米耀空气")
        #expect(result.annotation == .modelLoading)
    }

    @Test("模型说无需修改时标注为「已运行未改动」")
    func annotatesNoChange() async {
        let pipeline = CorrectionPipeline(corrector: StubCorrector())

        let result = await pipeline.correct("没有错字")

        #expect(result.annotation == .unchanged)
    }

    @Test("替换全被闸门拦下时同样标注为「已运行未改动」")
    func annotatesWhenGateRejectsEverything() async {
        let corrector = StubCorrector()
        // 单字替换缺上下文，闸门必拦。
        corrector.stubEdits = [CorrectionEdit(original: "的", replacement: "得")]
        let pipeline = CorrectionPipeline(corrector: corrector)

        let result = await pipeline.correct("我的书写得很好")

        #expect(result.text == "我的书写得很好")
        #expect(result.annotation == .unchanged)
    }

    @Test("真的改了字就不标注——正常工作不该有提示")
    func noAnnotationWhenApplied() async {
        let corrector = StubCorrector()
        corrector.stubEdits = [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
        let pipeline = CorrectionPipeline(corrector: corrector)

        let result = await pipeline.correct("小米耀空气")

        #expect(result.text == "小米遥控器")
        #expect(result.annotation == nil)
    }

    @Test("推理出错时标注为「已运行未改动」，具体原因只进日志")
    func annotatesEngineFailure() async {
        let corrector = StubCorrector()
        corrector.thrownError = CorrectorError.engineFailed("boom")
        let pipeline = CorrectionPipeline(corrector: corrector)

        let result = await pipeline.correct("小米耀空气")

        // 故障对用户没有任何可做的动作，不给它单独的标注（2026-08-17 决定）；
        // 但也不能什么都不显示——那就退回「静默不工作」，正是本条在修的事。
        #expect(result.annotation == .unchanged)
    }

    @Test("超时同样落在「已运行未改动」")
    func annotatesTimeout() async {
        let corrector = StubCorrector()
        corrector.delay = .milliseconds(200)
        let pipeline = CorrectionPipeline(corrector: corrector, timeout: .milliseconds(20))

        let result = await pipeline.correct("小米耀空气")

        #expect(result.text == "小米耀空气")
        #expect(result.annotation == .unchanged)
    }

    @Test("空白输入不标注：用户没说话，没什么可提示的")
    func noAnnotationForBlankInput() async {
        let pipeline = CorrectionPipeline(corrector: StubCorrector())

        #expect(await pipeline.correct("   ").annotation == nil)
    }

    @Test("两种标注的文案都能一眼看出「校正这次没起作用」")
    func labelsAreDistinct() {
        #expect(CorrectionAnnotation.modelLoading.hudLabel
                != CorrectionAnnotation.unchanged.hudLabel)
        // 「能等」这一层信息必须出现在加载那条里，否则两条没有区别。
        #expect(CorrectionAnnotation.modelLoading.hudLabel.contains("加载"))
        #expect(CorrectionAnnotation.unchanged.hudLabel.contains("未校正")
                || CorrectionAnnotation.unchanged.hudLabel.contains("无改动"))
    }
}

@Suite("会话把校正标注报出来")
@MainActor
struct DictationSessionAnnotationTests {
    private func makeSession(
        transcript: String, corrector: Corrector?
    ) -> (DictationSession, FakeAudioSource) {
        let source = FakeAudioSource()
        let transcriber = FakeTranscriber()
        transcriber.result = transcript
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }

        let session = DictationSession(
            audioSource: source,
            transcriber: transcriber,
            sink: SpySink(),
            targetGuard: guardian,
            correctionPipeline: corrector.map { CorrectionPipeline(corrector: $0) }
        )
        return (session, source)
    }

    @Test("模型加载中时把标注报给 UI")
    func reportsModelLoading() async throws {
        let corrector = StubCorrector()
        corrector.ready = false
        let (session, source) = makeSession(transcript: "今天天气不错", corrector: corrector)
        var reported: [CorrectionAnnotation?] = []
        session.onCorrection = { reported.append($0) }

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(reported == [.modelLoading])
    }

    @Test("改了字就报 nil，HUD 不显示任何标注")
    func reportsNilWhenApplied() async throws {
        let corrector = StubCorrector()
        corrector.stubEdits = [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
        let (session, source) = makeSession(transcript: "小米耀空气", corrector: corrector)
        var reported: [CorrectionAnnotation?] = []
        session.onCorrection = { reported.append($0) }

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(reported == [nil])
    }

    @Test("校正关闭时一次都不报——没开的东西不该提示「未校正」")
    func silentWhenCorrectionDisabled() async throws {
        let (session, source) = makeSession(transcript: "今天天气不错", corrector: nil)
        var reported: [CorrectionAnnotation?] = []
        session.onCorrection = { reported.append($0) }

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(reported.isEmpty)
    }

    @Test("转写失败时走不到校正，也不报标注")
    func silentWhenTranscribeFails() async throws {
        let source = FakeAudioSource()
        let transcriber = FakeTranscriber()
        transcriber.transcribeError = TranscribeError.engineFailed("boom")
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }
        let session = DictationSession(
            audioSource: source,
            transcriber: transcriber,
            sink: SpySink(),
            targetGuard: guardian,
            correctionPipeline: CorrectionPipeline(corrector: StubCorrector())
        )
        var reported: [CorrectionAnnotation?] = []
        session.onCorrection = { reported.append($0) }

        try await session.start()
        source.emitSilence(seconds: 1)
        await session.finish()

        #expect(reported.isEmpty)
    }
}
