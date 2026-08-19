import Foundation
import WhisperKit

/// 送进 `DecodingOptions` 的几个可调旋钮。
///
/// **为什么把它们单拎出来做成可注入的**：M6 ⓪ 那个「超过 30 秒的语音被静默
/// 截断」的成因链条落在这几个参数上（见 `docs/Roadmap.md`），而它们两两之间
/// 有代价交换——放宽 `firstTokenLogProbThreshold` 是在拿防幻觉换不丢字，
/// 关掉 VAD 分块是在拿静音幻觉换不丢字。**只报一个维度的数没有意义**，
/// 必须在同一轮里既量「长语音丢不丢字」又量「静音会不会冒话」，所以要能
/// 在一次进程、一次模型加载里把几个变体全跑一遍。做法与 `prompt` 完全一样。
///
/// 对照脚本：`./scripts/decode-sweep.sh`，结论写在 `Bench/decode-sweep.txt`。
///
/// **`production` 是唯一的生产取值，改它等于改产品行为。** 变体只在实验里用。
struct DecodeTuning: Sendable, Equatable {
    /// 是否启用 `chunkingStrategy: .vad`。
    ///
    /// WhisperKit 只在音频长度大于 `windowSamples`（30 秒）时才真正分块
    /// （`vendor/WhisperKit/Sources/WhisperKit/Core/WhisperKit.swift:1021`），
    /// 所以这个开关对 30 秒以内的录音没有任何影响。
    ///
    /// 开：静音被切掉，字幕署名类幻觉的触发源少一个；代价是连续语音里
    /// 找不到干净的静音时，切点落在句子中间，那一块开头模型接不上前文。
    /// 关：走 Whisper 原生滑窗，窗口解到句子边界、下一窗从那里续上，
    /// 永远不会在句中冷启动；代价是静音不再被预先切掉。
    ///
    /// **2026-08-17 改为默认关闭**，理由见 `production` 那段的对照表。
    var vadChunking: Bool

    /// 首个采样 token 的 logProb 下限，低于它整窗作废。
    ///
    /// `nil` 表示不做这道检查。WhisperKit 默认 −1.5
    /// （`Configurations.swift:215`），它是 `needsFallback` 的第一优先判据
    /// （`Models.swift:367`）。M6 ⓪ 实测被 VAD 切中句中的那一块首 token
    /// logProb ≈ −1.86，稳定地卡在这条线外侧一点点。
    var firstTokenLogProbThreshold: Float?

    /// 整窗平均 logProb 下限，低于它触发退火。`nil` 表示不做这道检查。
    var logProbThreshold: Float?

    /// 温度退火的档数。WhisperKit 默认 5，即 0.0/0.2/…/1.0 六档。
    ///
    /// **调小它不是在省时间，是在改「失败时返回哪一次」。**
    /// `decodeWithFallback`（`TranscribeTask.swift:367`）每轮直接覆盖
    /// `decodingResult`，全部不达标时返回的是**最后一次**而不是最好的一次；
    /// 实测最后一次（温度 1.0）恰好又是「首 token 太低、零个 token」，
    /// 于是整块变成空字符串。档数取 0 时只跑温度 0 那一次，返回的就是它。
    var temperatureFallbackCount: Int

    /// 自己做 VAD 分块，并对「明明有人声却解出空文本」的那一块放宽阈值重来一次。
    ///
    /// **这是「在 `decodeWithFallback` 里保留最好的一次」的不碰 vendor 等效做法。**
    /// 那个最对症的修法要改 `vendor/WhisperKit`，而 vendor 在 `.gitignore` 里、
    /// 改了不进版本库；但它要达到的效果——「别把一整块真话丢成空字符串」——
    /// 可以在我们这一层用公开 API 达到：
    ///
    /// `VADAudioChunker`、`EnergyVAD`、`AudioChunk`、
    /// `transcribe(audioArray:audioArrayOffset:decodeOptions:)` 全是 public，
    /// 于是我们可以用**与 WhisperKit 完全相同的分块器、相同的参数**自己切一遍，
    /// 逐块解码，再在块级别做判断。
    ///
    /// **它比「放宽阈值」这类全局改动强在范围**：防幻觉机制在默认路径上一个
    /// 都没动，只有同时满足两个条件才放宽——
    ///
    /// 1. 这一块解出来是空的（否则用户什么都拿不到，已经是最坏结果，无可失去）；
    /// 2. 这一块里确实有人声（`EnergyVAD` 的活跃帧占比高于
    ///    `rescueVoiceFraction`）。纯静音块解出空是**正确答案**，不重试，
    ///    所以静音幻觉那一维不会因此变差。
    ///
    /// 代价有两个，都记在这里：分块从并发变成串行（WhisperKit 原本用
    /// `concurrentWorkerCount` 并发跑各块），长录音的延迟会涨；失败那一块要
    /// 多解一次，那一块的耗时翻倍。
    var rescueEmptyChunks: Bool = false

    /// 触发重试所需的最低人声帧占比。
    ///
    /// 取 0.10：真机日志里一段正常说话的能量统计是「304 个块超阈值 145 个
    /// (47%)」，而纯静音是 0%。两者之间隔着整整一个数量级，阈值放在这个
    /// 区间里哪里都不改变结论；取靠下的一端是为了不漏掉「一块里只有末尾
    /// 一句话」的情形。
    static let rescueVoiceFraction = 0.10

    /// 生产取值。全部是 WhisperKit 的默认值——包括不挂 `chunkingStrategy`。
    ///
    /// ## `vadChunking` 为什么从 true 改成 false（2026-08-17）
    ///
    /// M6 ⓪ 那个「超 30 秒的语音整块变空」的 bug，成因在 vendor 里改不得
    /// （`decodeWithFallback` 返回最后一次而非最好的一次，而 `vendor/` 在
    /// `.gitignore` 里）。能从我们这一层设的只剩 `DecodingOptions` 上这几个
    /// 旋钮，于是拿 `./scripts/decode-sweep.sh` 做了三维对照。**每个变体相对
    /// 现状只动一处**，dense-31 每档重复 12 次（该 bug 是间歇性的，失败率
    /// 四到七成，单次结果没有意义），静音/底噪每档 24 次：
    ///
    /// | 变体 | dense-31 失败 | 静音非空 | 基准集 CER |
    /// |---|---|---|---|
    /// | 现状（vad on, 首 token −1.5） | 4/12、6/12（两轮） | 0/24 | 0.0190 |
    /// | **关 VAD 分块（本版）** | **0/12、0/12（两轮）** | **1/24、0/24** | 0.0190 |
    /// | 关首 token 阈值 | 0/12 | **12/24** | 0.0190 |
    /// | 首 token 阈值放宽到 −3.0 | 0/12 | **10/24** | 0.0190 |
    /// | 关分块 + 关首 token 阈值 | 0/12 | **16/24** | 0.0190 |
    /// | 关首 token 阈值 + 不退火 | 0/12 | **12/24** | 0.0190 |
    ///
    /// **四个候选都能治丢字，区别全在代价。** 动 `firstTokenLogProbThreshold`
    /// 的三档把静音幻觉从 0 拉到 10–16 次，漏出来的正是这个产品一直在防的
    /// 那一类——「谢谢大家。」「好,谢谢。」，还有
    /// 「请不吝点赞 讨订阅 转发 打赏支持明镜与点点栏目」。**那是拿一种丢字
    /// 换另一种丢字**，不能要。关分块两轮只漏 1 次「谢谢。」，是唯一便宜的。
    ///
    /// 另外实测掉的两个顾虑（`./scripts/decode-sweep.sh --scaling`，
    /// 3/6/10 分钟连续语音，分块 on/off 各一次）：
    ///
    /// ```
    /// 3min  176.8s   on 27.6s (6.4x)   off 25.2s (7.0x)
    /// 6min  353.6s   on 57.3s (6.2x)   off 59.1s (6.0x)
    /// 10min 618.8s   on 111.1s (5.6x)  off 109.8s (5.6x)   峰值内存 48MB
    /// ```
    ///
    /// **耗时没有差别，内存也没有。** 这一条反直觉：分块那条路把各块丢进
    /// `TaskGroup` 并发解码（`WhisperKit.swift:803-870`，macOS 上 16 个
    /// worker），不分块走的是串行滑窗，看代码会以为长录音要变慢。实际不会——
    /// ANE 是**一块硬件**，并发的 worker 照样在它上面排队，并行度买不到吞吐。
    ///
    /// **静音那一维不能只看 M5 那套素材。** `silence30` 恰好是 30.0 秒，而
    /// 分块的触发条件是「严格大于 30 秒」（`WhisperKit.swift:1021`），拿它比
    /// 分块 on/off 两边跑的是同一条代码路径。本轮补了 45 秒的静音与底噪，
    /// 以及「真人说 14.7 秒 + 尾部 20 秒静音」这个生产上最常见的形态。
    static let production = DecodeTuning(
        vadChunking: false,
        firstTokenLogProbThreshold: -1.5,
        logProbThreshold: -1.0,
        temperatureFallbackCount: 5,
        rescueEmptyChunks: false
    )
}

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

    /// 实际使用的解码参数。默认与 `DecodeTuning.production` 一致。
    ///
    /// **可注入的理由与 `promptText` 同一条**：这几个旋钮之间是有代价交换的
    /// （放宽防幻觉换回丢字、关掉分块换回静音幻觉），只能靠同一轮实测里的
    /// 对照表来选，而不能靠改一行常量重编译。生产路径不传，行为不变。
    private let tuning: DecodeTuning

    /// 解码任务。**生产永远是 `.transcribe`。**
    ///
    /// Whisper 自带 `.translate`，直接从语音解出**英文**——如果它够用，
    /// 翻译层可以一个额外模型都不加载、一次额外推理都不做。这个参数是
    /// 为了把这条最便宜的路测出来（Task 4 ⑤），可注入的理由与 `promptText`、
    /// `tuning` 同一条：不能靠改一行常量重编译来做对照。
    ///
    /// **它只能译成英文**，这是 Whisper 模型的固有限制而不是配置问题
    /// （解码器只有 `<|translate|>` 一个方向的训练目标，目标语言恒为英文），
    /// 所以它最多解决六种目标语言里的一种。
    ///
    /// 注意 `.translate` 与 `language` 的关系：`language` 仍是**源语言**，
    /// 保持 "zh" 不变。
    ///
    /// **非 private 是为了让「生产默认是 `.transcribe`」这句话有测试守着。**
    /// 2026-08-19 QA 实测：把下面那个默认值改成 `.translate`，981 tests
    /// 一条不红——一个只靠注释维持的生产默认值，而且恰好长在最容易被人
    /// 顺手接到「输出语言」偏好上的地方。接错了每一句中文都会变成**语义
    /// 错误**的英文（M8 第 0 步实测：「权限也需要重新梳理」→ "the whole
    /// line needs to be reorganized"），而全部现有指标都看不出来。
    /// 守卫见 `WhisperKitTranscriberTests.productionTaskIsTranscribe`。
    let task: DecodingTask

    init(
        modelName: String = "base",
        modelFolder: String? = nil,
        language: String = "zh",
        normalizeToSimplified: Bool = true,
        prompt: String = WhisperKitTranscriber.punctuationPrompt,
        tuning: DecodeTuning = .production,
        task: DecodingTask = .transcribe
    ) {
        self.modelName = modelName
        self.modelFolder = modelFolder
        self.language = language
        self.normalizeToSimplified = normalizeToSimplified
        self.promptText = prompt
        self.tuning = tuning
        self.task = task
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

    /// 引导标点与技术专名的条件前缀（Whisper 的 initial prompt 机制）。
    ///
    /// 模型会沿用这段前缀的风格，包括标点密度与专名写法。Whisper 本身没有
    /// 「加标点」的开关，这是唯一的手段；而技术专名听错（`Claude Code` →
    /// `collodecode`）不是同音错误，校正层的拼音闸门从设计上就修不了，也只能
    /// 在这里给模型这几个词的写法。
    ///
    /// **每一处都是实测定的，改动前请用基准集复测**
    /// （`./scripts/bench-run.sh openai_whisper-large-v3-v20240930_turbo`）。
    ///
    /// ## 三条约束
    ///
    /// 1. **必须用半角逗号。** 全角「，」是 UTF-8 三字节（EF BC 8C），字节级
    ///    BPE 会把它拆成多个 token；一旦采样只对了前两个字节，就解码出
    ///    `Ｂ`（EF BC A2）、`４`（EF BC 94）、`�` 这类同前缀乱码——用全角的
    ///    候选在 24 秒的 long.wav 上稳定复现，换成半角后 90 次转写零乱码。
    ///    Whisper 中文本来就输出半角逗号，跟着它的习惯走。
    /// 2. **术语必须嵌在完整句子里，不能堆成词表。** 词表候选
    ///    「Claude Code,Cursor,GitHub,AWS,prompt,token。」在 1.5 秒静音上吐出
    ///    「Claude Code,Claude Code,Claude Code Code,…」连着 13 遍；纯英文
    ///    词表在静音上吐「Thank you.」（套话表只收中文，拦不住）。后来用真人
    ///    基准集复测，词表候选还把长句标点从 4 个砍到 1–2 个。
    /// 3. **不能像一句能被续写下去的日常闲话。** 危险的不是「具体」，是
    ///    「像一句能被续写下去的话」——无语音时模型要挑一个最可能的续写，
    ///    日常口语句永远是高概率候选，技术句不是。只有日常句、没有技术句的
    ///    那一版在 30 秒底噪上 8/8 被模型续写出原话（「时间上没问题,你放心。」
    ///    「时间上没问题,我们就先这样吧,回头再说。」），且不带套话特征、
    ///    `segmentsDroppingFallbackFiller` 拦不住；补上技术句结尾后同一组
    ///    素材 0/48。
    ///
    /// ## 两版的实测数字，别混着读
    ///
    /// **63 字旧版**（下称 P0，只点名 Claude Code / GitHub Actions / AWS
    /// 三个词，M4 期间用 bench 的 TTS 素材定的。以下数字**只属于它**）：
    /// 长句标点从 0 提到 7（24 秒的 long.wav，基线 103 字零标点）；13 段素材
    /// 逐条比对，加技术句前后标点数完全一致；**加长到 35 token 没有触发温度
    /// 退火**；静音/底噪 48 次转写最终输出 0 次非空（退火吐出的 22 次全是
    /// 「谢谢」类套话，被 `segmentsDroppingFallbackFiller` 拦下），
    /// **术语一次都没漏进结果**。
    ///
    /// **124 字本版**（下称 P6，2026-08-17 用 23 条真人基准集扫 9 个候选选出。
    /// 上面那些数字不描述本版，本版的数字是这张表）：
    ///
    /// | 候选 | 总体 CER | 技术类 | 术语命中 | 泄漏 | 字数 |
    /// |---|---|---|---|---|---|
    /// | P0 旧版（点名 3 词） | 0.0317 | 0.0742 | 0.389 | 0 | 63 |
    /// | 全覆盖版 | 0.0212 | 0.0339 | 0.917 | 0 | 161 |
    /// | 单句式加长版 | 0.0199 | 0.0290 | 1.000 | **2** | 172 |
    /// | **本版 P6** | **0.0190** | **0.0254** | **1.000** | 0 | 124 |
    ///
    /// **短比全好**，这推翻了「词表越全越好」的直觉：更长的候选反而更差，
    /// 附带的句式会渗进转写（全覆盖版把「改 useEffect **的**依赖数组」的
    /// 「的」渗进了正文），加长版还漏了 2 次。**起作用的是「点名」，不是
    /// 上下文。**
    ///
    /// ## 「技术类追平 large-v3」只对点名过的 8 个术语成立
    ///
    /// 本版在总体 CER 上超过 large-v3（0.0190 vs 0.0207），同音类更好
    /// （0.0294 vs 0.0363），技术类看着持平（0.0254 vs 0.0251）——**但技术类
    /// 那一格不能这么读**。基准集的技术术语被逐字写进了本版 prompt，而
    /// `BenchMetrics.technicalTerms` 又是从参考文本抽词，于是「术语命中率」
    /// 量的是「prompt 里有没有这个词」。留出实验（2026-08-17 独立验收 B1，
    /// turbo；H1 与本版同为 124 字、同结构同风格，只把术语换成基准集里一个
    /// 都没有的 Azure / useMemo / fetchProfile 等）：
    ///
    /// | prompt（turbo） | 总体 CER | 技术类 | 术语命中 |
    /// |---|---|---|---|
    /// | P0 旧版（点名 3 词） | 0.0317 | 0.0742 | 0.389 |
    /// | H1 留出版（术语一个都没点名） | 0.0276 | 0.0584 | 0.500 |
    /// | 本版 P6（点名 8 词） | 0.0190 | 0.0254 | 1.000 |
    ///
    /// 技术类 0.0742 → 0.0254 的改善里只有约 21% 是可迁移的风格效应
    /// （→0.0584），**79% 来自把答案写进了 prompt**。H1 的失败形态正是 M4 的
    /// 原病（`Use Effect`、`Cloud Code`、`Token` 大写），而 H1 自己 prompt 里
    /// 的术语一次都没漏进输出——是干净的「未点名」基线。
    ///
    /// **所以：prompt 里没写的术语上，turbo 0.0584 对 large-v3 0.0251，仍差
    /// 2.3 倍。留在 turbo 的理由是 4.5 倍延迟（1.2 秒/条 vs 5.4 秒/条）与
    /// 用户实测反馈，不是「技术类持平」。**
    ///
    /// 另一个已验证的事实：**large-v3 对 prompt 不敏感**——large-v3 + P6 与
    /// large-v3 + P0 的三层指标完全相同到小数点后四位（0.0207 / 技术 0.0251 /
    /// 同音 0.0363）。改 prompt 不必重跑 large-v3。
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
                // 生产恒为 .transcribe，见 `task` 那段注释。
                task: task,
                language: language,
                // 退火档数。见 DecodeTuning.temperatureFallbackCount。
                temperatureFallbackCount: tuning.temperatureFallbackCount,
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
                logProbThreshold: tuning.logProbThreshold,
                firstTokenLogProbThreshold: tuning.firstTokenLogProbThreshold,
                // **默认不分块**（2026-08-17 起）。VAD 分块本来是用来切掉
                // 静音、少一个字幕署名类幻觉的触发源的，但它在连续语音上
                // 把切点落在句子中间，被切中的那块整块作废——实测 31 秒的
                // dense 语料 12 次里丢 4–6 次。见 DecodeTuning.production。
                chunkingStrategy: tuning.vadChunking ? .vad : nil
            )
            let results = tuning.rescueEmptyChunks
                ? try await transcribeRescuingEmptyChunks(audio, options: options, pipe: pipe)
                : try await pipe.transcribe(audioArray: audio, decodeOptions: options)
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

    /// 一块音频里 `EnergyVAD` 判为有人声的帧占比。
    ///
    /// 用它区分「这一块是静音，解出空是对的」与「这一块有人在说话，解出空
    /// 是丢字」。用的是 WhisperKit 自己那个 VAD 的默认参数（帧长 0.1 秒、
    /// 能量阈值 0.02），与分块器看到的是同一把尺子。
    nonisolated static func voiceFraction(of samples: [Float], vad: EnergyVAD) -> Double {
        let activity = vad.voiceActivity(in: samples)
        guard !activity.isEmpty else { return 0 }
        return Double(activity.filter { $0 }.count) / Double(activity.count)
    }

    /// 自己分块解码，并救回「有人声却解成空」的那一块。见
    /// `DecodeTuning.rescueEmptyChunks` 的注释——那里写了为什么要这么绕。
    ///
    /// **分块参数必须与 WhisperKit 内部完全一致**，否则救回来的那一块与
    /// 原本会被解码的那一块不是同一段音频，对照就没有意义：
    /// `maxChunkLength` 取 `featureExtractor.windowSamples`、`VADAudioChunker`
    /// 用默认的 `windowPadding` 与 `EnergyVAD`——照抄
    /// `vendor/WhisperKit/Sources/WhisperKit/Core/WhisperKit.swift:1021-1046`。
    ///
    /// 30 秒以内的音频 WhisperKit 本来就不分块，这里也原样直传，免得多绕一层。
    private func transcribeRescuingEmptyChunks(
        _ audio: [Float], options: DecodingOptions, pipe: WhisperKit
    ) async throws -> [TranscriptionResult] {
        let maxChunkLength = pipe.featureExtractor.windowSamples ?? Constants.defaultWindowSamples
        guard audio.count > maxChunkLength else {
            return try await pipe.transcribe(audioArray: audio, decodeOptions: options)
        }

        let vad = EnergyVAD()
        let chunks = try await VADAudioChunker(vad: vad).chunkAll(
            audioArray: audio, maxChunkLength: maxChunkLength, decodeOptions: options
        )

        // 逐块解码。块本身不超过 maxChunkLength，所以这里必须关掉分块策略，
        // 否则等于让 WhisperKit 再判一次（结论相同，但多绕一层）。
        var perChunk = options
        perChunk.chunkingStrategy = nil
        // 救援档：只松开首 token 那道闸，其余不动。松它是因为实测那一块死在
        // 它手上（首 token logProb −1.86 对阈值 −1.5，见 docs/Roadmap.md）。
        var rescue = perChunk
        rescue.firstTokenLogProbThreshold = nil

        var all: [TranscriptionResult] = []
        for (index, chunk) in chunks.enumerated() {
            var results = try await pipe.transcribe(
                audioArray: chunk.audioSamples,
                audioArrayOffset: chunk.seekOffsetIndex,
                decodeOptions: perChunk
            )
            let text = results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                let voice = Self.voiceFraction(of: chunk.audioSamples, vad: vad)
                let seconds = Double(chunk.audioSamples.count) / AudioFormat.sampleRate
                if voice >= DecodeTuning.rescueVoiceFraction {
                    // **这条日志是这套机制唯一的可观测点。** 原本的失败形态是
                    // 「不报错、不记日志、整块话消失」，那正是它难查的原因。
                    AppLogger.shared.log(
                        "第 \(index + 1)/\(chunks.count) 块（\(String(format: "%.1f", seconds))s，"
                        + "人声帧占比 \(String(format: "%.0f%%", voice * 100))）解出空文本，"
                        + "放宽 firstTokenLogProbThreshold 重试"
                    )
                    results = try await pipe.transcribe(
                        audioArray: chunk.audioSamples,
                        audioArrayOffset: chunk.seekOffsetIndex,
                        decodeOptions: rescue
                    )
                    let retried = results.map(\.text).joined()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    AppLogger.shared.log(
                        retried.isEmpty ? "  重试后仍是空" : "  重试救回 \(retried.count) 字"
                    )
                }
            }
            all += results
        }
        return all
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
