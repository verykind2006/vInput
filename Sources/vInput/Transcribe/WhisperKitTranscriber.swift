import Foundation
import WhisperKit

/// WhisperKit 适配层。
///
/// 用 actor 而非 class，是因为模型加载与推理都不可重入：
/// 两个会话同时触发时，第二个必须排队而不是并发进入 Core ML。
actor WhisperKitTranscriber: Transcriber, PreviewCapable {
    /// 低于此时长的音频不送去转写。
    ///
    /// **这个门槛不是「能不能解出内容」的分界线，别把它当安全线看。**
    /// 真正的悬崖在 1.00 秒，见 `decodingFloorDuration`。
    ///
    /// 原值是 0.3，注释写的理由是「避免 Whisper 对极短片段产生幻觉文本」。
    /// 加了补白之后这个理由不再成立，实测两头都验了（large-v3-turbo，
    /// 一律先补白到 1.1 秒再送进去）：
    ///
    /// - **0.3 秒以下确实有真话。** 单音节词本来就短：`say -v Tingting`
    ///   的「对」0.260s → 「对。」、「好」0.344s → 「好。」——0.26 秒那句
    ///   完全解得出来，却被旧门槛挡在外面。而 `audioTooShort` 是
    ///   `AppModel.isUserFacing` 里唯一不展示的错误，于是它**也是静默消失**，
    ///   与本轮修的那个问题同一性质，只是更短。
    /// - **挡下来的也不是幻觉源。** 0.10 / 0.20 / 0.30 秒的纯静音与底噪
    ///   各跑 3 次，补白后 18 次全部输出空串，一次幻觉都没有。静音幻觉需要
    ///   更长的窗口（bench 的 1.5 秒静音才开始吐「谢谢大家。」），
    ///   而补白只补到 1.1 秒。
    ///
    /// 所以门槛降到 0.15：它现在的职责只剩「挡掉连一个音节都装不下的误触」，
    /// 省一次没有意义的模型调用，而不是防幻觉——防幻觉由
    /// `segmentsDroppingFallbackFiller` 和 `TranscriptCleaner` 负责。
    static let minimumDuration: TimeInterval = 0.15

    /// WhisperKit 主解码循环真正的下限。
    ///
    /// 其循环条件是 `while seek < seekClipEnd - windowPadding`，而
    /// `windowPadding = windowClipTime(默认 1.0s) × 16000`
    /// （`vendor/WhisperKit/Sources/WhisperKit/Core/TranscribeTask.swift:113-116`）。
    /// 音频不长于 1 秒时循环体**一次都不执行**，返回 0 个分段、空文本——
    /// 不报错、不记日志，用户说的话彻底消失。
    ///
    /// 实测（large-v3-turbo，`say -v Tingting`，样本见 `scripts/bench.sh`
    /// 的 `short_*` 组）：
    ///
    /// ```
    /// 好的 0.41s→空  收到 0.57s→空  谢谢 0.55s→空
    /// 知道了 0.56s→空  不客气 0.70s→空  明天见 0.79s→空
    /// 好的就这样 1.04s→「好的就这样。」
    /// 边界（同一段「谢谢」尾部补静音）：
    /// 0.90s→空  0.99s→空  1.00s→空  1.005s→「谢谢。」  1.10s→「谢谢。」
    /// ```
    ///
    /// 「好的」「谢谢」「收到」正是这个应用最高频的输入，不能不管。
    static let decodingFloorDuration: TimeInterval = 1.0

    /// 短音频补静音后的目标时长。
    ///
    /// 取 1.1 而不是刚好越过 1.00 的最小值，是给上游留余量：
    /// `windowClipTime` 是 WhisperKit 的默认参数，它调一次我们就又踩空。
    ///
    /// 实测补到 1.1 秒后，上面那六段全部在**温度 0** 解出正确文本
    /// （「好的。」「收到。」「谢谢。」「知道了。」「不客气。」「明天见。」，
    /// avgLogprob −0.16…−0.27），没有触发温度退火，也没有引入套话幻觉。
    static let paddedDuration: TimeInterval = 1.1

    /// 把过短的音频尾部补静音到 `paddedDuration`。
    ///
    /// 补在尾部而不是首部：解码窗口本来就从 0 开始，尾部补静音等价于
    /// 「说完之后又静了一会儿」，是模型日常见到的形态。实测该形态不触发退火。
    ///
    /// 补白确实会让「几乎没说话」的片段变成一段静音，而静音是套话幻觉的
    /// 温床。实测这一条没有兑现：0.10–0.30 秒的静音与底噪补白后 18 次
    /// 全部输出空串（见 `minimumDuration`）。真出现时由
    /// `segmentsDroppingFallbackFiller` 兜底。
    nonisolated static func padToDecodingFloor(_ samples: [Float]) -> [Float] {
        let target = Int(paddedDuration * AudioFormat.sampleRate)
        guard samples.count < target else { return samples }
        return samples + [Float](repeating: 0, count: target - samples.count)
    }

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

    /// 实际使用的 initial prompt。默认就是 `punctuationPrompt`。
    ///
    /// **可注入是为了做 A/B**：换 prompt 只能靠实测判优劣（见
    /// `punctuationPrompt` 那一长段注释里的教训），而「改一行静态常量、
    /// 重新编译、跑一轮」的做法每轮都要重新加载模型、也没法把几个候选
    /// 放进同一份报告里对比。生产路径不传这个参数，行为与从前完全一致。
    private let promptText: String

    init(
        modelName: String = "base",
        modelFolder: String? = nil,
        language: String = "zh",
        normalizeToSimplified: Bool = true,
        prompt: String = WhisperKitTranscriber.punctuationPrompt
    ) {
        self.modelName = modelName
        self.modelFolder = modelFolder
        self.language = language
        self.normalizeToSimplified = normalizeToSimplified
        self.promptText = prompt
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
            promptTokens = loaded.tokenizer.map { Self.encodePrompt(promptText, with: $0) }
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
    /// 引导标点与技术专名的条件前缀。
    ///
    /// **每一处都是实测定的，改动前请用基准集复测**
    /// （`./scripts/bench-run.sh openai_whisper-large-v3-v20240930_turbo`）。
    ///
    /// 三条约束：
    ///
    /// 1. **必须半角逗号。** 全角「，」是 3 字节 UTF-8，字节级 BPE 拆开后
    ///    采样只命中前两字节，解码成 `Ｂ`、`４`、`�`。用全角的候选在长音频
    ///    上稳定吐乱码。
    /// 2. **术语必须嵌在正常句子里，不能堆成词表。** 纯词表候选把长句标点
    ///    从 4 个砍到 1–2 个。
    /// 3. **不能像一句能被续写下去的日常闲话。** 更早的版本以「时间上没
    ///    问题,你放心。」结尾，在 30 秒底噪上 8/8 被模型续写出来，且不带
    ///    套话特征、幻觉过滤拦不住；改成技术句结尾后 0/48。
    ///
    /// **短比全好。** 2026-08-17 用 23 条真人基准集扫了 9 个候选：
    ///
    /// | 候选 | 总体 CER | 技术类 | 术语命中 | 泄漏 | 字数 |
    /// |---|---|---|---|---|---|
    /// | 旧版（只点 3 个词） | 0.0317 | 0.0742 | 0.389 | 0 | 63 |
    /// | 全覆盖版 | 0.0212 | 0.0339 | 0.917 | 0 | 161 |
    /// | 单句式加长版 | 0.0199 | 0.0290 | 1.000 | **2** | 172 |
    /// | **本版** | **0.0190** | **0.0254** | **1.000** | 0 | 124 |
    ///
    /// 更长的候选反而更差：附带的句式会渗进转写（全覆盖版把「改 useEffect
    /// **的**依赖数组」的「的」渗进了正文），加长版还漏了 2 次。起作用的是
    /// 「点名」，不是上下文。
    ///
    /// **本版在总体 CER 上超过了 large-v3**（0.0190 vs 0.0207），技术类
    /// 持平（0.0254 vs 0.0251），同音类更好（0.0294 vs 0.0363）——而 turbo
    /// 快 4.5 倍（1.2 秒/条 vs 5.4 秒/条）。
    static let punctuationPrompt =
        "对,这个我知道,那我们就先这样吧,回头再说。用 Claude Code 和 GitHub Actions 部署到 AWS,先跑 npm install 改 useEffect,把 getUserName 里的 token 用 refresh 换掉。"

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
    ///
    /// **实测警告：这一条在 large-v3-turbo 上从来不会触发。** bench 的
    /// 9 段静音/底噪各跑 4 次，产出的幻觉分段 18 条，`noSpeechProb`
    /// **全部是 0.0000**（温度 0.4–0.8）。也就是说该模型在无语音输入上
    /// 照样自信地报「这里有人说话」，这把尺子量不出东西来。真正在干活的是
    /// `segmentsDroppingFallbackFiller`。保留本函数是因为它只删结尾、
    /// 代价为零，且换回 large-v3 等其他模型时仍可能有效。
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

    /// 单个分段是否是「靠温度退火才解出来的纯客套话」。
    ///
    /// 判据是两个条件相与：
    ///
    /// - **温度大于 0** 意味着贪心解码没通过 logProb / 压缩率阈值、走了退火。
    /// - **整段去掉标点后恰好等于某句套话**，句中出现一律不管。
    ///
    /// **这个判据会误伤，而且不是理论风险——已实测。** 此处原先写着
    /// 「所有真实语音都在温度 0 解出」，该前提是错的：把
    /// `say -v Tingting "谢谢大家"` 压到 volume=0.06 再混 a=0.05 白噪
    /// （模拟远场/嘈杂），转写会解出
    ///
    /// ```
    /// temperature=0.4, noSpeechProb=0.0000, avgLogprob=-0.4625, 「谢谢大家。」
    /// ```
    ///
    /// ——文字完全正确，模型自己也认定这里有人说话，却满足上面两条，
    /// 被整段删掉。**嘈杂环境下用户真说一句「谢谢」是会被吞的。**
    ///
    /// 仍然保留这个判据，是因为暂时找不到更好的信号：
    /// **收紧到「与 `noSpeechProb >= 0.6` 相与」是行不通的**——
    /// bench 的 9 段静音/底噪各跑 4 次，18 条幻觉分段的 `noSpeechProb`
    /// 全部是 0.0000，与上面那条真实语音一模一样，两者用这个量分不开。
    ///
    /// 既然分不开，就只能限制这一刀能砍到的范围（见
    /// `segmentsDroppingFallbackFiller`）并把每次开刀都记进日志。
    nonisolated static func isFallbackFiller(_ segment: TranscriptionSegment) -> Bool {
        guard segment.temperature > 0 else { return false }
        let bare = segment.text.filter { !"，。！？；：、,.!?;: \t\n\u{3000}".contains($0) }
        return fallbackFillers.contains(TranscriptCleaner.stripSpecialTokens(bare))
    }

    /// 从结尾往前剥掉「靠温度退火才解出来的、整段只有一句客套话」的分段。
    ///
    /// **这一条是为 initial prompt 配套加的。** 实测：静音/底噪输入下，
    /// 不挂 prompt 时 35 次里 2 次吐出幻觉，挂上 prompt 后升到 11 次，
    /// 且形态高度一致——全是「谢谢。」。prompt 提高了模型「必须说点什么」
    /// 的倾向，这是它的固有代价，得在事后补一刀。
    ///
    /// **只从结尾往前剥，不动中间**——与 `textDroppingTrailingNonSpeech`
    /// 同一条原则。此处原先是对所有分段做 filter，那是错的：VAD 会把
    /// 「谢谢,那我们就先这样吧,回头再说」这类话切成多段，句首的「谢谢」
    /// 独立成段是真实会发生的形态，一旦它落在温度大于 0 的解码里就会被
    /// 从句子中间挖掉。幻觉从来只长在结尾（那是静音所在），限制到结尾
    /// 不损失拦截力，却把「挖掉句中一句真话」这类事故整类消掉。
    ///
    /// 「整段转写只有这一句」是本函数的特例——唯一的分段既是结尾也是开头，
    /// 照样会被剥掉，静音输入的兜底不受影响。
    nonisolated static func segmentsDroppingFallbackFiller(
        _ segments: [TranscriptionSegment]
    ) -> [TranscriptionSegment] {
        var kept = segments[...]
        while let last = kept.last, isFallbackFiller(last) {
            kept = kept.dropLast()
        }
        return Array(kept)
    }

    /// 把被剥掉的分段记进日志。
    ///
    /// **这一刀删的是用户的原话，不记就等于没发生过。** 校正层的取舍还能从
    /// 「采纳=[…] 拦下=[…]」的日志判断松紧，而转写层此前一个字都不记——
    /// 上面 `isFallbackFiller` 那条已证实会误伤的判据，真机上砍错一次也
    /// 无从发现。判据暂时改不动，那至少要留下痕迹。
    ///
    /// 内容走 `logTranscript`，因此默认只记「几个字」，`VINPUT_LOG_TRANSCRIPTS=1`
    /// 时才记原文——与 spec 的隐私要求一致。温度与 noSpeechProb 不是用户
    /// 内容，无条件记录：判断误删与否靠的就是它们。
    nonisolated static func logDroppedSegments(
        _ dropped: some Collection<TranscriptionSegment>
    ) {
        for segment in dropped {
            AppLogger.shared.log(
                "转写层剥掉结尾套话分段：temperature=\(segment.temperature) "
                + "noSpeechProb=\(String(format: "%.4f", segment.noSpeechProb)) "
                + "avgLogprob=\(String(format: "%.4f", segment.avgLogprob))"
            )
            AppLogger.shared.logTranscript(segment.text, context: "  剥掉的原文")
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let duration = Double(samples.count) / AudioFormat.sampleRate
        guard duration >= Self.minimumDuration else {
            throw TranscribeError.audioTooShort
        }

        try await prepare()
        guard let pipe else { throw TranscribeError.modelNotReady }

        // 不长于 1 秒的音频在 WhisperKit 里连解码循环都进不去，见
        // decodingFloorDuration。补白必须在这里做，不能挪到调用方——
        // 这是上游解码器的性质，谁调用都一样。
        let audio = Self.padToDecodingFloor(samples)
        if audio.count != samples.count {
            AppLogger.shared.log(
                "短音频补静音：\(String(format: "%.2f", duration))s → "
                + "\(String(format: "%.2f", Self.paddedDuration))s"
            )
        }

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
                audioArray: audio,
                decodeOptions: options
            )
            // 按分段过滤，而不是把所有文本拼起来再猜词。
            // 模型自己给出了每段「其实没人说话」的概率，用它比维护
            // 一张幻觉短语表可靠得多——短语表打不完，且每加一个词
            // 就多一分误删真话的风险。
            let decoded = results.flatMap(\.segments)
            let segments = Self.segmentsDroppingFallbackFiller(decoded)
            Self.logDroppedSegments(decoded.dropFirst(segments.count))
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
