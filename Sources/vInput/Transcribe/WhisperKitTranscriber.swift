import Foundation
import WhisperKit

/// WhisperKit 适配层。
///
/// 用 actor 而非 class，是因为模型加载与推理都不可重入：
/// 两个会话同时触发时，第二个必须排队而不是并发进入 Core ML。
actor WhisperKitTranscriber: Transcriber, PreviewCapable {
    /// 低于此时长的音频不送去转写，避免 Whisper 对极短片段产生幻觉文本。
    static let minimumDuration: TimeInterval = 0.3

    private let modelName: String
    /// 本地模型目录。设置后优先于 `modelName`，跳过网络下载。
    ///
    /// 存在这个参数是因为 WhisperKit 内置的 URLSession 下载器在丢包
    /// 网络下会整体超时放弃（见计划「风险 0」）。模型由
    /// `scripts/fetch-model.sh` 用 curl 预先拉取。
    private let modelFolder: String?
    private let language: String
    /// 把输出统一转成简体。Whisper 即便指定 language="zh" 也常输出繁体。
    /// 面向繁体用户时可关闭。
    private let normalizeToSimplified: Bool
    private var pipe: WhisperKit?

    init(
        modelName: String = "base",
        modelFolder: String? = nil,
        language: String = "zh",
        normalizeToSimplified: Bool = true
    ) {
        self.modelName = modelName
        self.modelFolder = modelFolder
        self.language = language
        self.normalizeToSimplified = normalizeToSimplified
    }

    func prepare() async throws {
        guard pipe == nil else { return }
        do {
            let config = if let modelFolder {
                WhisperKitConfig(modelFolder: modelFolder)
            } else {
                WhisperKitConfig(model: modelName)
            }
            pipe = try await WhisperKit(config)
        } catch {
            throw TranscribeError.engineFailed(error.localizedDescription)
        }
    }

    /// 判定一段是幻觉所用的「无语音概率」下限。
    ///
    /// 与 `DecodingOptions.noSpeechThreshold` 的默认值一致。该阈值在解码
    /// 过程中用于决定是否跳过整个窗口，这里用同一把尺子做事后过滤。
    static let nonSpeechProbability: Float = 0.6

    /// 丢弃结尾处「其实没人说话」的分段，再把剩下的拼成文本。
    ///
    /// Whisper 的中文训练数据含大量带字幕视频，音频结尾的静音段极易让它
    /// 凭空生成「谢谢观看」「谢谢大家」这类套话。真机反复出现过。
    ///
    /// **只从结尾往前剥，不动中间。** 句子中间某段被判为无语音多半是模型
    /// 判断失误，删掉就是真的丢字了——那正是规则二要防的事。
    nonisolated static func textDroppingTrailingNonSpeech(
        _ segments: [TranscriptionSegment]
    ) -> String {
        var kept = segments[...]
        while let last = kept.last, last.noSpeechProb >= nonSpeechProbability {
            kept = kept.dropLast()
        }
        return kept
            .map(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let duration = Double(samples.count) / AudioFormat.sampleRate
        guard duration >= Self.minimumDuration else {
            throw TranscribeError.audioTooShort
        }

        try await prepare()
        guard let pipe else { throw TranscribeError.modelNotReady }

        do {
            let options = DecodingOptions(
                language: language,
                // WhisperKit 默认 false。开启后抑制空白 token，
                // 减少静音段凭空生成内容。
                suppressBlank: true,
                // 用能量 VAD 切掉静音段。静音是字幕署名类幻觉
                // （「( 字幕:XXX )」）的主要触发源。
                chunkingStrategy: .vad
            )
            let results = try await pipe.transcribe(
                audioArray: samples,
                decodeOptions: options
            )
            // 按分段过滤，而不是把所有文本拼起来再猜词。
            // 模型自己给出了每段「其实没人说话」的概率，用它比维护
            // 一张幻觉短语表可靠得多——短语表打不完，且每加一个词
            // 就多一分误删真话的风险。
            let segments = results.flatMap(\.segments)
            let raw = Self.textDroppingTrailingNonSpeech(segments)

            // 分段过滤只能拿掉「整段都是幻觉」的情形。若幻觉与真实语音
            // 混在同一段里（模型对该段整体判为有语音），仍需短语兜底。
            let cleaned = TranscriptCleaner.clean(raw)
            return normalizeToSimplified ? ChineseScript.toSimplified(cleaned) : cleaned
        } catch {
            throw TranscribeError.engineFailed(error.localizedDescription)
        }
    }

    /// 基于当前已加载的模型构造预览引擎。
    ///
    /// **重要：返回的引擎与本转写器共享同一套解码器实例。**
    /// 两者并发执行会在解码器状态上产生数据竞争，调用方
    /// （`DictationSession`）必须保证预览停止后才发起全量转写。
    func makePreviewEngine(processor: SourceBackedAudioProcessor) async -> PreviewEngine? {
        guard let pipe else { return nil }
        guard let tokenizer = pipe.tokenizer else { return nil }

        return StreamingPreviewEngine(
            audioEncoder: pipe.audioEncoder,
            featureExtractor: pipe.featureExtractor,
            segmentSeeker: pipe.segmentSeeker,
            textDecoder: pipe.textDecoder,
            tokenizer: tokenizer,
            processor: processor,
            // skipSpecialTokens 默认为 false，此时 segment.text 里会带
            // <|zh|>、<|0.00|> 这类原始标记。最终注入读的是
            // TranscriptionResult.text（已处理过）所以看不出来，而预览直接
            // 读 segments[].text——真机反馈「一堆尖角符」就是这个。
            decodingOptions: DecodingOptions(
                language: language,
                skipSpecialTokens: true,
                suppressBlank: true
            )
        )
    }
}
