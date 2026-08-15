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
    /// 引导标点用的 prompt token，模型加载后编码一次并缓存。
    private var promptTokens: [Int]?

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

    /// tokenizer 等辅助文件的存放目录。
    ///
    /// **必须显式指定。** WhisperKit 的默认值是 `~/Documents/huggingface`
    /// （见其 `HubApi.swift:109`），而 `~/Documents` 是 macOS 的 TCC 保护
    /// 目录。本应用是 LSUIElement（纯菜单栏、无主窗口），访问受保护目录
    /// 触发的授权弹窗无处呈现，`open()` 会无限期阻塞——真机实测卡住 5 分钟
    /// 仍未返回，堆栈停在 `HubApi.configuration(fileURL:)` 的 `open()` 上。
    ///
    /// 换到应用支持目录后不受 TCC 约束。这本来也更合适：模型缓存不该写进
    /// 用户的「文稿」文件夹。
    nonisolated static func defaultDownloadBase() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vInput/huggingface", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func prepare() async throws {
        guard pipe == nil else { return }
        do {
            let downloadBase = Self.defaultDownloadBase()
            let config = if let modelFolder {
                WhisperKitConfig(downloadBase: downloadBase, modelFolder: modelFolder)
            } else {
                WhisperKitConfig(model: modelName, downloadBase: downloadBase)
            }
            let loaded = try await WhisperKit(config)
            pipe = loaded
            promptTokens = loaded.tokenizer.map { Self.encodePrompt(Self.punctuationPrompt, with: $0) }
        } catch {
            throw TranscribeError.engineFailed(error.localizedDescription)
        }
    }

    /// 引导长句输出标点用的示例文本（Whisper 的 initial prompt 机制）。
    ///
    /// 模型会沿用这段前缀的风格，包括标点密度。真机反馈「长句几乎不带标点」，
    /// 实测（large-v3-turbo + 本仓库 bench 音频）确实如此：24 秒的 long.wav
    /// 基线输出 103 字零标点，挂上这段 prompt 后稳定给出 7 个标点。
    ///
    /// 选这段文字的三条理由，每条都是实测踩出来的：
    ///
    /// 1. **用半角逗号，不用全角。** 全角「，」是 UTF-8 三字节
    ///    （EF BC 8C），字节级 BPE 会把它拆成多个 token；一旦采样只对了
    ///    前两个字节，就解码出 `Ｂ`（EF BC A2）、`４`（EF BC 94）、`�`
    ///    这类同前缀乱码——用全角逗号的候选 prompt 在 long.wav 上稳定复现，
    ///    换成半角后 90 次转写零乱码。Whisper 中文本来就输出半角逗号，
    ///    prompt 跟着用半角反而更贴近它自己的习惯。
    /// 2. **短。** 50 字以上的候选（哪怕内容中性）会把解码推进温度退火，
    ///    输出重复串与乱码。
    /// 3. **词汇日常且不指向任何具体事物。** prompt 的用词会被模型抄进结果
    ///    ——含「明天再发给你」的候选就在静音输入上吐出过「明天再发」。
    ///
    /// 后半段那句技术示例是后加的，起因是真机把「我们用 Claude Code 写代码，
    /// 然后用 GitHub Actions 做持续集成，最后部署到 AWS 上面」听成
    /// 「我们用 collodecode 写代码…最后部署到 aws 上面」。这不是同音错误，
    /// 校正层的拼音闸门从设计上就修不了，只能在转写层给模型这几个词的写法。
    ///
    /// 加它之前担心的是上面第 2、3 条，实测（bench 音频，large-v3-turbo）
    /// 两条都没有兑现，反而顺带修好了一个既有问题：
    ///
    /// - **技术词**：新增的 techen.wav 上，只带前半段时输出
    ///   「Cloud Code…GitHub Actions…Auth」，加上术语句后 4 次转写稳定给出
    ///   「Claude Code…GitHub Actions…AWS」。
    /// - **标点**：13 段语音素材逐条比对，标点数与只带前半段时**完全一致**
    ///   （long 7、nopunct1 3、nopunct2 4、chat 2 …）。加长到 35 token
    ///   没有触发退火。
    /// - **泄漏与幻觉**：静音/底噪 48 次转写，最终输出 0 次非空；退火吐出的
    ///   22 次全是「谢谢」类套话，被 `segmentsDroppingFallbackFiller` 拦下。
    ///   **术语一次都没有漏进结果。**
    ///
    /// 反过来，只带前半段的旧 prompt 在同一组素材上 48 次里漏出 9 次，其中
    /// 8 次是 30 秒底噪上把自己的原话续写出来：「时间上没问题,你放心。」
    /// 「时间上没问题,我们就先这样吧,回头再说。」——第 3 条约束一直在被违反，
    /// 只是此前没测过 30 秒长度的底噪。
    ///
    /// 所以第 3 条要改写成：**危险的不是「具体」，是「像一句能被续写下去的
    /// 日常闲话」。** 无语音时模型要挑一个最可能的续写，日常口语句永远是
    /// 高概率候选，技术句不是。相应地，**术语必须写在完整句子里，不能写成
    /// 词表**——同批实测的两个词表候选是本轮最糟的：
    /// 「Claude Code,Cursor,GitHub,AWS,prompt,token。」在 1.5 秒静音上吐出
    /// 「Claude Code,Claude Code,Claude Code Code,…」连着 13 遍；
    /// 纯英文词表则在静音上吐「Thank you.」——套话表只收了中文，拦不住。
    static let punctuationPrompt =
        "对,这个我知道,那我们就先这样吧,回头再说。用 Claude Code 和 GitHub Actions,最后部署到 AWS。"

    /// 把 prompt 文本编成 token，并剔除特殊标记。
    ///
    /// `WhisperTokenizer` 协议只暴露 `encode(text:)`，**没有** swift-transformers
    /// 那个带 `addSpecialTokens` 的重载（底层的 `TokenizerWrapper` 不是 public）。
    /// 而 `encode(text:)` 默认会包上 `<|startoftranscript|>`、`<|endoftext|>`，
    /// 混进条件前缀会打乱解码器的 prefill 结构，必须自己滤掉。
    ///
    /// WhisperKit 的 `TextDecoder` 里也有一道同样的过滤，这里不依赖它：
    /// 上游改了我们不该跟着炸。
    nonisolated static func encodePrompt(
        _ text: String, with tokenizer: any WhisperTokenizer
    ) -> [Int] {
        tokenizer.encode(text: text)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
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

    /// 退火解码时才会冒出来的纯套话。整段只有这么一句才算数。
    static let fallbackFillers: Set<String> = [
        "谢谢", "谢谢你", "谢谢大家", "谢谢观看", "感谢观看", "谢谢收看",
    ]

    /// 丢弃「靠温度退火才解出来的、整段只有一句客套话」的分段。
    ///
    /// **这一条是为 initial prompt 配套加的。** 实测：静音/底噪输入下，
    /// 不挂 prompt 时 35 次里 2 次吐出幻觉，挂上 prompt 后升到 11 次，
    /// 且形态高度一致——全是「谢谢。」。prompt 提高了模型「必须说点什么」
    /// 的倾向，这是它的固有代价，得在事后补一刀。
    ///
    /// 判据用两个条件相与，而不是简单地把「谢谢」加进短语表：
    ///
    /// - **温度大于 0** 意味着贪心解码没通过 logProb / 压缩率阈值、走了退火。
    ///   实测里所有静音幻觉都带退火，而所有真实语音都在温度 0 解出。
    /// - **整段去掉标点后恰好等于某句套话**，句中出现一律不管。
    ///
    /// 单独任一条都太松：用户真说一句「谢谢」应当照常输出，那句会在温度 0
    /// 解出，不满足第一条，不会被吞。
    nonisolated static func segmentsDroppingFallbackFiller(
        _ segments: [TranscriptionSegment]
    ) -> [TranscriptionSegment] {
        segments.filter { segment in
            guard segment.temperature > 0 else { return true }
            let bare = segment.text.filter { !"，。！？；：、,.!?;: \t\n\u{3000}".contains($0) }
            return !fallbackFillers.contains(TranscriptCleaner.stripSpecialTokens(bare))
        }
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
                // segment.text 是原始文本，不开这个会带 <|zh|>、<|0.00|>
                // 这类标记。TranscriptionResult.text 是处理过的，但我们
                // 为了做分段级过滤直接读 segments，必须自己关掉。
                skipSpecialTokens: true,
                // 条件前缀。见 punctuationPrompt——这是让长句带上标点的
                // 唯一手段，Whisper 本身没有「加标点」的开关。
                promptTokens: promptTokens,
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
            let segments = Self.segmentsDroppingFallbackFiller(results.flatMap(\.segments))
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
            //
            // **预览刻意不挂 punctuationPrompt。** 三条理由：
            // 预览是边说边刷的中间结果，最终注入的是全量转写的输出，
            // 这里的标点无人受用；prompt 会给每个解码窗口多压几十个 token，
            // 直接吃预览的延迟预算；而预览面对的正是「很短、常常还没开口」
            // 的音频片段，实测该条件下挂 prompt 最容易触发温度退火与幻觉。
            decodingOptions: DecodingOptions(
                language: language,
                skipSpecialTokens: true,
                suppressBlank: true
            )
        )
    }
}
