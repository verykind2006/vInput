import WhisperKit
import Testing
@testable import vInput

@Suite("WhisperKitTranscriber")
struct WhisperKitTranscriberTests {
    // MARK: - 生产默认的解码任务

    /// **生产永远是 `.transcribe`。**
    ///
    /// 提交信息与验收文档都写着「生产默认 `.transcribe` 不变」，而
    /// 2026-08-19 QA 实测：把 `WhisperKitTranscriber.init` 里那个默认值改成
    /// `.translate`，981 tests 一条不红。
    ///
    /// 改错了的表现不是崩溃也不是空输出，是**每一句中文都变成语义错误的
    /// 英文**：M8 第 0 步实测「权限也需要重新梳理」→ "the whole line needs
    /// to be reorganized"，零残留汉字、术语保留高、长度比正常——
    /// **全部现有指标都看不出来**，用户把输出语言选回中文也救不回来
    /// （那时翻译层根本不参与，注入的就是 Whisper 直接吐出的英文）。
    ///
    /// 这个参数存在的唯一理由是 `scripts/whisper-translate.sh` 那条对照，
    /// 而它恰好长在最容易被人顺手接到「输出语言」偏好上的地方。
    @Test("生产默认的解码任务是 .transcribe，不是 .translate")
    func productionTaskIsTranscribe() async {
        await #expect(
            WhisperKitTranscriber().task == .transcribe,
            """
            WhisperKitTranscriber 的默认 task 不再是 .transcribe。
            Whisper 的 .translate 只能译成英文，而且是**语义错误**的英文，
            现有全部指标都看不出来。要做对照请显式传参（见
            scripts/whisper-translate.sh），不要改默认值。
            """
        )
    }

    /// 上面那条如果单独存在，把 `task` 写成写死 `.transcribe` 的常量也全绿。
    /// 这一条让「构造器参数真的被用上」成为观测得到的事——对照脚本正是靠它。
    @Test("显式传入的解码任务被记住")
    func explicitTaskIsHonoured() async {
        await #expect(WhisperKitTranscriber(task: .translate).task == .translate)
    }

    @Test("过短的音频直接拒绝，不加载模型")
    func rejectsShortAudio() async {
        let transcriber = WhisperKitTranscriber()
        // 0.05 秒 = 800 个样本，低于 0.15 秒门槛
        let samples = [Float](repeating: 0, count: 800)

        await #expect(throws: TranscribeError.audioTooShort) {
            try await transcriber.transcribe(samples)
        }
    }

    @Test("0.26 秒的单音节词不再被门槛挡掉")
    func acceptsSingleSyllableWord() async {
        // say -v Tingting 的「对」是 0.260s、「嗯」0.261s，都在旧的 0.3
        // 门槛之下。而 audioTooShort 不展示给用户，被挡等于静默消失。
        // 实测补白后「对」能解出「对。」，这类话必须放进来。
        let transcriber = WhisperKitTranscriber(modelFolder: "/nonexistent")
        let samples = [Float](repeating: 0, count: 4_160)  // 0.26 秒

        do {
            _ = try await transcriber.transcribe(samples)
        } catch let error as TranscribeError {
            #expect(error != .audioTooShort)
        } catch {
            Issue.record("预期 TranscribeError，实际 \(error)")
        }
    }

    @Test("不到 1 秒的音频被补静音到 1.1 秒")
    func padsBelowDecodingFloor() {
        // WhisperKit 的主解码循环是 while seek < seekClipEnd - windowPadding，
        // windowPadding 默认 1.0 秒，不长于 1 秒的音频循环体一次都不执行。
        // 实测「好的」0.41s、「谢谢」0.55s 全部返回空文本。
        let halfSecond = [Float](repeating: 0.1, count: 8_000)
        let padded = WhisperKitTranscriber.padToDecodingFloor(halfSecond)

        #expect(padded.count == 17_600)
        // 原样本必须原封不动地留在头部，补的是尾巴
        #expect(Array(padded.prefix(8_000)) == halfSecond)
        #expect(padded.suffix(9_600).allSatisfy { $0 == 0 })
    }

    @Test("恰好 1.00 秒也要补——悬崖是「不长于」而非「短于」")
    func padsAtExactlyOneSecond() {
        // 实测边界：1.00s 空，1.005s 出「谢谢。」。循环条件是严格小于，
        // 正好 16000 个样本时 0 < 16000 - 16000 不成立。
        let oneSecond = [Float](repeating: 0.1, count: 16_000)
        #expect(WhisperKitTranscriber.padToDecodingFloor(oneSecond).count == 17_600)
    }

    @Test("已经够长的音频原样返回，不做任何改动")
    func leavesLongAudioUntouched() {
        let twoSeconds = [Float](repeating: 0.1, count: 32_000)
        #expect(WhisperKitTranscriber.padToDecodingFloor(twoSeconds) == twoSeconds)
    }

    @Test("恰好达到门槛的音频会越过时长检查")
    func acceptsAudioAtThreshold() async {
        // 0.3 秒 = 4800 个样本。这里不断言转写结果——那需要真实模型；
        // 只断言它不再因时长被拒，即错误类型不是 audioTooShort。
        let transcriber = WhisperKitTranscriber(modelFolder: "/nonexistent")
        let samples = [Float](repeating: 0, count: 4_800)

        do {
            _ = try await transcriber.transcribe(samples)
        } catch let error as TranscribeError {
            #expect(error != .audioTooShort)
        } catch {
            Issue.record("预期 TranscribeError，实际 \(error)")
        }
    }

    // MARK: - 按输入语言构造

    /// 三个中文专属构造参数（解码语言、繁→简、标点 prompt）必须按输入
    /// 语言分流：英文等语种带着中文标点 prompt 与繁→简只有坏处。
    @Test func transcriberIsBuiltPerInputLanguage() async {
        let zh = AppModel.makeTranscriber(
            ModelDescriptor(name: "m", folder: "/tmp/m"), language: .chinese)
        let en = AppModel.makeTranscriber(
            ModelDescriptor(name: "m", folder: "/tmp/m"), language: .english)
        guard let zh = zh as? WhisperKitTranscriber, let en = en as? WhisperKitTranscriber else {
            Issue.record("非空目录应当构造 WhisperKitTranscriber"); return
        }
        await #expect(zh.language == "zh")
        await #expect(zh.normalizeToSimplified)
        await #expect(zh.promptText == WhisperKitTranscriber.punctuationPrompt)
        await #expect(en.language == "en")
        // 繁→简与中文标点 prompt 都是中文专属，英文解码带着它们只有坏处。
        await #expect(!en.normalizeToSimplified)
        await #expect(en.promptText.isEmpty)
    }

    /// 与 `MissingModelTranscriberTests.emptyFolderYieldsTheNonDownloadingTranscriber`
    /// 分工：那边守「返回的是不联网的类型」，这边守「加 language 参数后守卫不丢」。
    @Test func emptyModelFolderStillMeansMissingModel() {
        // 原守卫不因加参数而丢：空目录绝不联网。
        let transcriber = AppModel.makeTranscriber(
            ModelDescriptor(name: "m", folder: ""), language: .english)
        #expect(transcriber is MissingModelTranscriber)
    }

    /// 七语种全查语言码，防止将来某语种被硬编码遮住。
    @Test func everyLanguageMapsToItsWhisperCode() async {
        for language in Language.allCases {
            guard let transcriber = AppModel.makeTranscriber(
                ModelDescriptor(name: "m", folder: "/tmp/m"), language: language) as? WhisperKitTranscriber else {
                Issue.record("\(language) 未构造出 WhisperKitTranscriber"); return
            }
            await #expect(transcriber.language == language.rawValue)
            await #expect(transcriber.normalizeToSimplified == (language == .chinese))
            await #expect(transcriber.promptText.isEmpty == (language != .chinese))
        }
    }
}

@Suite("WhisperKitTranscriber 预览能力")
struct WhisperKitTranscriberPreviewTests {
    @Test("模型未加载时不产出预览引擎")
    func noPreviewBeforeModelLoads() async {
        // 指向不存在的目录，prepare 必然失败，pipe 保持 nil
        let transcriber = WhisperKitTranscriber(modelFolder: "/nonexistent/model")
        let processor = SourceBackedAudioProcessor()

        let engine = await transcriber.makePreviewEngine(processor: processor)

        #expect(engine == nil)
    }
}

@Suite("退火套话分段过滤")
struct FallbackFillerFilterTests {
    private func segment(_ text: String, temperature: Float) -> TranscriptionSegment {
        TranscriptionSegment(
            id: 0, seek: 0, start: 0, end: 1, text: text,
            tokens: [], tokenLogProbs: [], temperature: temperature,
            avgLogprob: 0, compressionRatio: 1, noSpeechProb: 0
        )
    }

    private func texts(_ segments: [TranscriptionSegment]) -> [String] {
        WhisperKitTranscriber.segmentsDroppingFallbackFiller(segments).map(\.text)
    }

    @Test("退火解出的纯套话被丢掉")
    func dropsFillerFromFallback() {
        // 挂上 initial prompt 后，静音输入最常见的幻觉形态就是这一句
        #expect(texts([segment("谢谢。", temperature: 0.6)]).isEmpty)
        #expect(texts([segment(" 谢谢 ", temperature: 1.0)]).isEmpty)
    }

    @Test("温度 0 解出的谢谢是用户真说的，必须留下")
    func keepsFillerDecodedGreedily() {
        // 判据的关键一半：真实语音都在温度 0 解出，不该被这条规则波及
        #expect(texts([segment("谢谢。", temperature: 0)]) == ["谢谢。"])
    }

    @Test("套话只是句子的一部分时不动")
    func keepsFillerInsideSentence() {
        let text = "谢谢你帮我看这个问题"
        #expect(texts([segment(text, temperature: 0.8)]) == [text])
    }

    @Test("只丢套话段，正文段照留")
    func keepsRealSegmentsAlongside() {
        let segments = [
            segment("今天下午三点开会", temperature: 0.6),
            segment("谢谢", temperature: 0.6),
        ]
        #expect(texts(segments) == ["今天下午三点开会"])
    }

    @Test("句首的套话分段不被删——那是句子的一部分")
    func keepsLeadingFillerSegment() {
        // VAD 实测会把「谢谢,那我们就先这样吧,回头再说」切成多段，
        // 句首的「谢谢」独立成段是真实会发生的形态。此前的实现对所有分段
        // 做 filter，会把它从句子中间挖掉——那就是真的丢字。
        let segments = [
            segment("谢谢", temperature: 0.6),
            segment("那我们就先这样吧", temperature: 0.6),
            segment("回头再说", temperature: 0.6),
        ]
        #expect(texts(segments) == ["谢谢", "那我们就先这样吧", "回头再说"])
    }

    @Test("夹在中间的套话分段同样不被删")
    func keepsMiddleFillerSegment() {
        let segments = [
            segment("今天下午三点开会", temperature: 0.6),
            segment("谢谢", temperature: 0.6),
            segment("记得带上电脑", temperature: 0.6),
        ]
        #expect(texts(segments) == ["今天下午三点开会", "谢谢", "记得带上电脑"])
    }

    @Test("结尾连续多段套话一并剥掉")
    func dropsMultipleTrailingFillers() {
        let segments = [
            segment("今天下午三点开会", temperature: 0),
            segment("谢谢", temperature: 0.6),
            segment("谢谢大家", temperature: 0.8),
        ]
        #expect(texts(segments) == ["今天下午三点开会"])
    }

    @Test("剥到温度 0 的套话就停手")
    func stopsAtGreedyFiller() {
        // 温度 0 解出的「谢谢」是用户真说的，它挡住后面的剥离
        let segments = [
            segment("正文", temperature: 0),
            segment("谢谢", temperature: 0),
            segment("谢谢大家", temperature: 0.8),
        ]
        #expect(texts(segments) == ["正文", "谢谢"])
    }

    @Test("空分段安全")
    func emptyIsSafe() {
        #expect(WhisperKitTranscriber.segmentsDroppingFallbackFiller([]).isEmpty)
    }
}

@Suite("结尾无语音分段过滤")
struct TrailingNonSpeechFilterTests {
    private func segment(_ text: String, noSpeech: Float, id: Int = 0) -> TranscriptionSegment {
        TranscriptionSegment(
            id: id, seek: 0, start: 0, end: 1, text: text,
            tokens: [], tokenLogProbs: [], temperature: 0,
            avgLogprob: 0, compressionRatio: 1, noSpeechProb: noSpeech
        )
    }

    @Test("剥掉结尾判为无语音的分段")
    func dropsTrailingHallucination() {
        let segments = [
            segment("今天下午三点开会", noSpeech: 0.05),
            segment("谢谢大家", noSpeech: 0.92),
        ]
        #expect(WhisperKitTranscriber.textDroppingTrailingNonSpeech(segments) == "今天下午三点开会")
    }

    @Test("连续多段无语音一并剥掉")
    func dropsMultipleTrailing() {
        let segments = [
            segment("正文", noSpeech: 0.1),
            segment("谢谢观看", noSpeech: 0.8),
            segment("请点赞订阅", noSpeech: 0.95),
        ]
        #expect(WhisperKitTranscriber.textDroppingTrailingNonSpeech(segments) == "正文")
    }

    @Test("句子中间被判无语音的分段不动")
    func keepsMidSentenceSegments() {
        // 中间某段被判无语音多半是模型判断失误，删掉就是真的丢字
        let segments = [
            segment("前半句", noSpeech: 0.1),
            segment("中间这段", noSpeech: 0.9),
            segment("后半句", noSpeech: 0.1),
        ]
        #expect(WhisperKitTranscriber.textDroppingTrailingNonSpeech(segments) == "前半句中间这段后半句")
    }

    @Test("全部是语音时一段不少")
    func keepsAllWhenAllSpeech() {
        let segments = [
            segment("第一段", noSpeech: 0.1),
            segment("第二段", noSpeech: 0.2),
        ]
        #expect(WhisperKitTranscriber.textDroppingTrailingNonSpeech(segments) == "第一段第二段")
    }

    @Test("恰好等于阈值的分段被剥掉")
    func atThresholdIsDropped() {
        let segments = [
            segment("正文", noSpeech: 0.1),
            segment("套话", noSpeech: WhisperKitTranscriber.nonSpeechProbability),
        ]
        #expect(WhisperKitTranscriber.textDroppingTrailingNonSpeech(segments) == "正文")
    }

    @Test("全部被判无语音时返回空串而非崩溃")
    func allNonSpeechYieldsEmpty() {
        let segments = [segment("谢谢观看", noSpeech: 0.99)]
        #expect(WhisperKitTranscriber.textDroppingTrailingNonSpeech(segments).isEmpty)
    }

    @Test("空分段安全")
    func emptySegmentsAreSafe() {
        #expect(WhisperKitTranscriber.textDroppingTrailingNonSpeech([]).isEmpty)
    }
}
