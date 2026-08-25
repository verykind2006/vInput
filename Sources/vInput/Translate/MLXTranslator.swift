import Foundation
import MLXLLM
import MLXLMCommon

/// 基于 MLX 的本地翻译器。
///
/// 用 actor 而非 struct：模型加载与推理都不可重入，两次会话同时触发时
/// 第二个必须排队。与 `MLXCorrector` 同一考量。
actor MLXTranslator: Translator {
    /// 模型加载走 `OneShotLoader`，而不是 `guard container == nil`。
    ///
    /// 直接在本 actor 里加载有两个坑：加载会随调用方的取消一起被掐断
    /// （超时一到就前功尽弃，模型永远等不到就绪），且两次并发调用会各自
    /// 启动一次加载（判重的 await 之间有空隙）。两条都由 `OneShotLoader`
    /// 解决，它的注释里记着 M4 那次「校正永不生效」的实测。
    ///
    /// **加载器不再由本类型独占，而是向 `ModelContainerRegistry` 领。**
    /// 翻译的默认后端就是校正层在用的那个模型（M8 第 0 步实测定的
    /// `qwen3-4b-instruct-2507-4bit`），各自加载会常驻两份 2 GB 权重。
    private let loader: OneShotLoader<ModelContainer>

    /// 提示词变体。生产路径不传，永远是 `.englishLanguageName`；
    /// 只有 Task 3 的对照装置会换它，理由见 `TranslationPrompt.Variant`。
    private let promptVariant: TranslationPrompt.Variant

    /// 单次推理的 token 上限。
    private let maxTokens: Int

    /// `maxTokens` 的默认值。**仍是暂定值，等 Task 4 的实测回填。**
    ///
    /// 512 没有任何实测支撑——它既不是测出来的译文长度，也不是测出来的
    /// 耗时上限，就是个先让代码跑起来的数。校正层那个 96 不能照抄：它限的
    /// 是极短的替换清单，而译文可能比原文长不少。往大了拍的代价是超时——
    /// maxTokens 只限单次推理长度，限不住耗时，真正的时间闸门在流水线那一侧。
    ///
    /// 暴露成 `static` 是为了让扫描装置的默认值跟着它走：两处各写一个 512，
    /// 有一天会对不上，而对不上的表现是「扫描测出来的截断率和线上不一样」，
    /// 看不出根因。
    static let defaultMaxTokens = 512

    /// - Parameters:
    ///   - modelDirectory: 本地模型目录。
    ///   - promptVariant: 提示词变体，生产路径不要传。
    ///   - maxTokens: 单次推理的 token 上限。
    ///
    /// **`maxTokens` 可调是为了让「撞上限」这件事测得出来。** 撞上限的表现
    /// 是「静默返回半截译文、成功返回不报错」，和取消半途而废的表现一模一样
    /// （见下面 `translate` 里记的实测），事后分不开。把它调小到必然撞上限、
    /// 看截断判据是不是全都亮起来，是唯一能证明那条判据不是空判据的办法。
    ///
    /// **刻意不提供「按 Hugging Face 标识符下载」的重载**，与
    /// `MLXCorrector` 在这一点上不同（它的 `modelDirectory` 可为 nil）。
    /// 理由是 `WhisperKitTranscriber.init` 那个 `modelName: String = "base"`
    /// 默认值：调用方没给本地目录时它会静默联网拉 base 跑完整个基准集，
    /// 而应用默认用 turbo，报告头只写「模型：默认」，事后无从发现跑的是
    /// 什么（见 `scripts/default-model.sh` 开头记的 2026-08-17 F1）。
    /// 一个「不给就联网」的默认值在这里同样无法在日志里暴露自己，
    /// 所以从一开始就要求显式给目录。
    init(
        modelDirectory: URL,
        promptVariant: TranslationPrompt.Variant = .englishLanguageName,
        maxTokens: Int = MLXTranslator.defaultMaxTokens,
        registry: ModelContainerRegistry<ModelContainer> = SharedModelContainers.registry
    ) {
        self.promptVariant = promptVariant
        self.maxTokens = maxTokens
        // **错误包装留在 `prepare()`，不写进这个闭包。** 闭包只在「本层
        // 第一个到」时才会被用到，包在里面的话，校正层先启动时翻译层会拿到
        // `CorrectorError`，反之亦然——错误类型取决于谁先开机。
        loader = registry.loader(for: .local(modelDirectory)) {
            try await loadModelContainer(directory: modelDirectory)
        }
    }

    var isReady: Bool {
        get async { await loader.ready != nil }
    }

    /// 本实例拿到的加载器身份。理由见 `MLXCorrector.loaderIdentity`。
    var loaderIdentity: ObjectIdentifier { ObjectIdentifier(loader) }

    func prepare() async throws {
        do {
            _ = try await loader.value()
        } catch {
            throw TranslatorError.engineFailed(error.localizedDescription)
        }
    }

    func translate(_ text: String, from source: Language, to target: Language) async throws -> String {
        // **不在这里等加载。** 加载要几十秒，而调用方带着秒级推理预算，
        // 等下去只会把注入一起拖住。未就绪就直说，由流水线退回中文原文
        // 并另行预热。
        guard let container = await loader.ready else { throw TranslatorError.modelNotReady }

        // 逐字段赋值而非带标签的构造器：GenerateParameters 的字段在版本间
        // 增删过，逐字段赋值不受参数顺序与标签变化影响（M4 的做法）。
        var parameters = GenerateParameters()
        // 翻译要的是确定性，不是创造力。同一句话每次该得到同样的结果，
        // 否则 Task 3 的对照装置测出来的差异分不清是模型差异还是采样噪声。
        parameters.temperature = 0
        // 上限的取值与理由见 `defaultMaxTokens`。计划原文写的「由第 0 步的
        // 实测长度定」在任务重排后失效了：第 0 步（Task 3/4 的对照装置）要用
        // 本文件才跑得起来，现在排在本任务**之后**。
        // **按这一段的长度算上限，不用构造时那个固定值。**
        // 构造参数现在的语义是「下限」：短句照旧 512，长段按 2 token/字
        // 放大（实测反推约 0.8–0.95，取 2 是刻意给足余量——见
        // `TranslationBudget.tokensPerCharacter`）。
        //
        // 2026-08-19 实测：589 字的输入产出约 470–560 token，**贴着 512**。
        // 再长一点就会被静默截断，而截断出来的是完全合法的目标语言文本，
        // 事后与超时半途而废分不开。
        parameters.maxTokens = max(maxTokens, TranslationBudget.maxTokens(forCharacters: text.count))

        // **每次新建 ChatSession。** 它内部持有对话历史（`Generator.messages`），
        // 复用会让上一句转写污染下一句的翻译。
        // 不传 instructions：`ChatSession.streamResponse` 进去先做
        // `generator.messages = [.user(...)]`——赋值而非追加，系统消息被静默
        // 丢弃（见 `TranslationPrompt` 的注释，规则已并进用户提示）。
        let session = ChatSession(container, generateParameters: parameters)

        // 用流式而非 `respond(to:)`：后者走 `Evaluate.swift` 里那个同步的
        // `generate(input:context:iterator:didGenerate:)`，整个 token 循环里
        // 没有任何一处读 `Task.isCancelled`，取消对它毫无作用。流式那条路走
        // `generate(input:context:iterator:)`，循环第一行就是
        // `if Task.isCancelled { break }`。
        //
        // **但那个 break 我们够不着，取消也不会变成异常。** 实测过两条分支
        // （probe：复刻 `Generator.stream()` 的结构跑 8 次）：
        //
        // 1. 消费方在 `next()` 上挂起时被取消 —— `AsyncThrowingStream` 的
        //    取消处理直接 `finish()`，`next()` 返回 nil，`for try await`
        //    **正常结束不抛异常**，循环体不再进入，下面的 `checkCancellation`
        //    根本没机会跑。函数于是**返回半截译文并且是成功返回**。
        //    这是真实占比接近 100% 的那条：消费方几乎全部时间都在等下一个 token。
        // 2. 缓冲区里还有 chunk 时被取消 —— `next()` 不挂起，循环体照常进入，
        //    `checkCancellation` 抛 `CancellationError`，转成 `.timedOut`。
        //
        // 半截译文**不在这里拦**：判断「这段输出能不能用」是 `TranslationGate`
        // 的职责（见 `Translator` 协议的注释），在这里加一道就成了两处判断。
        // 闸门必须知道自己要防这个——半截译文往往是合法的目标语言文本，
        // 光看「像不像英文」拦不住。
        //
        // 另外，生产方不会因为我们取消而停：`Generator.stream()` 的外层
        // `AsyncThrowingStream` 没有设 `onTermination`，里面那个非结构化
        // `Task` 收不到取消信号，GPU 照跑到 maxTokens 或 EOS。取消只买到
        // 「注入路径上不干等」，买不到省算力。
        var output = ""
        do {
            for try await chunk in session.streamResponse(
                to: TranslationPrompt.user(for: text, from: source, to: target, variant: promptVariant)
            ) {
                try Task.checkCancellation()
                output += chunk
            }
        } catch is CancellationError {
            throw TranslatorError.timedOut
        } catch {
            throw TranslatorError.engineFailed(error.localizedDescription)
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
