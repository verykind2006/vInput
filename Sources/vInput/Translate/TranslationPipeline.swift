import Foundation

/// 这次翻译发生了什么。**只在非正常路径上有值**——
/// 正常译出时是 nil，HUD 什么都不显示。
///
/// 与 `CorrectionAnnotation` 只有两格的取向不同：那边把「故障」全部收进
/// `unchanged`，因为校正失败时用户拿到的仍是他说的那句话，成因对他没有
/// 可做的动作。**翻译不一样**——失败时注入的是中文，而用户选了英文，
/// 屏幕上多出来的是一段他并不想要的中文。他必须知道为什么，
/// 才知道是「等一下再说」还是「去配 API key」还是「重说一遍」。
enum TranslationAnnotation: Equatable, Sendable {
    /// 模型还在加载，本次没翻译。用户可以等一等再说下一句。
    case modelLoading
    /// 推理超时。
    case timedOut
    /// 引擎报错。**关联的消息只进日志，不进 HUD**：那是引擎的内部字符串
    /// （MLX 的错误描述），对用户没有意义，还会把 HUD 撑到几行。
    case failed(String)
    /// 选了云端但没配 API key。**单列而不是并进 failed**：
    /// 这一条用户有明确的动作可做（去配 key），其余没有。
    case missingAPIKey
    /// 云端按地理位置拒绝了。
    ///
    /// **不能并进 `failed`**：那格的措辞是「翻译失败」，会让用户去重说一遍
    /// ——而重说一百遍也没用。这一条他有明确的动作可做（换网络位置、开 VPN、
    /// 或者切回本机）。
    case locationNotSupported
    /// 选了外语，但一个本地翻译模型目录都没有，翻译层根本没挂上。
    ///
    /// **不能用 `failed` 顶替**：什么都没试过，谈不上失败，而「翻译失败」
    /// 会让用户去重说一遍——重说一百遍也没用。也不能用 `missingAPIKey`：
    /// 那是云端那条路，要做的动作完全不同（配 key vs 指定本地目录）。
    ///
    /// **产生者是 `AppModel.applyTranslationPreference`，不是流水线**：
    /// 这种情形下流水线压根不会被构造出来（见 `TranslationAttachment`）。
    /// 文案仍放在这里，是为了让「翻译没生效时 HUD 说什么」只有一处措辞。
    case missingLocalModel
    /// 闸门拦下。
    case rejected(TranslationRejection)

    /// HUD 上显示的一行字。
    ///
    /// **每种都必须有文案**，否则会出现「有标注但界面空白」——
    /// 那正是 M6 ③ 修掉的那类「用户只看到没变化，无从判断是哪种」。
    /// 这个 switch **刻意不写 `default`**：加一格标注时它编译不过，
    /// 「忘了配文案」因此是编译错误而不是运行期的空白 HUD。
    /// （`TranslationAnnotationLabelTests` 的样本表同样靠一个穷尽 switch
    /// 守着，加一格时那边也编译不过，逼人把新格子放进覆盖列表。）
    ///
    /// **每一种文案都说了「原文」**：这些失败路径注入的是**原文**——
    /// 用户怎么说的就注入什么，而他选了别的语言，屏幕上出现原话本身就是
    /// 要解释的那件事。不说清楚的话他只会以为翻译开关没生效。
    /// （源不再恒为中文，所以不说「中文原文」——英文输入下那是错话。）
    var hudLabel: String {
        switch self {
        case .modelLoading: "翻译模型还在加载，本次注入原文"
        case .timedOut: "翻译超时，已注入原文"
        case .failed: "翻译失败，已注入原文"
        case .missingAPIKey: "云端翻译未配置 API key，已注入原文"
        // 说清「不是翻译坏了，是这个网络位置用不了云端」，并给出两条出路。
        case .locationNotSupported: "当前网络位置无法使用云端翻译，已注入原文"
        // 用「将」不用「已」：这一条在用户点菜单选语言的那一刻就说出来，
        // 那时还没有哪一次听写发生过。
        case .missingLocalModel: "没有可用的翻译模型目录，将注入原文"
        // **委托给 `TranslationRejection.hudLabel`，不另写一套。**
        // 闸门那边已经按四种成因各写了一句（「译文里还有中文」「译文没说完」
        // …），这里再写一套的话，改一处忘另一处是迟早的事，而表现是
        // 「HUD 说的和日志说的不一样」——日志记的是 rejection 本身。
        case .rejected(let reason): reason.hudLabel
        }
    }
}

/// 一次翻译的结果。
///
/// 与 `CorrectionResult` 同一个形状：标注与文本一起返回，而不是回调出去。
/// 调用方本来就在等这次翻译的结果，多一个回调只会多一条时序要对齐。
struct TranslationResult: Equatable, Sendable {
    let text: String
    let annotation: TranslationAnnotation?
}

/// 编排翻译：超时、闸门、失败退回。
///
/// **一切失败路径都收敛为「返回中文原文 + 标注」，本类型不抛错。**
/// 与 `CorrectionPipeline` 同一条铁律，也与 M6 的结论一致：用户宁可自己
/// 删掉重说，也不该发现话没了（规则二·永不丢字）。
struct TranslationPipeline: Sendable {
    /// 单次推理的时间上限。**只约束推理，不约束模型加载。**
    ///
    /// ### 这个数是量出来的
    ///
    /// M8 第 0 步实测：默认后端 `qwen3-4b-instruct-2507-4bit`，单条翻译
    /// **最长 4.9 秒**（德语，10 条）；英语 / 西班牙语各 26 条上最长
    /// 2.9 / 4.3 秒。8 秒对最慢的那条留约 1.6 倍余量。
    ///
    /// ### 超时在这里买不到什么——别指望它省 GPU
    ///
    /// Task 8 写 probe 跑了 8/8 次：取消传不进 MLX 的生产方，
    /// `AsyncThrowingStream` 外层没设 `onTermination`，GPU 照跑到 EOS。
    /// **超时只是「注入路径上不干等」**，那次推理仍会跑完。
    ///
    /// ### 而它有实实在在的成本，所以不能定长
    ///
    /// `ModelContainer.perform` 是串行的——**跑飞的那次会挡住下一次推理**。
    /// 超时定得越长，用户下一句话被挡得越久。这是上界的来源，
    /// 不是「怕用户等」这么一句软话。
    ///
    /// 换更大的模型（菜单里明摆着邀请）需要重新实测这个值。
    /// **这是下限不是定值。** 实际预算随文本长度放大，见 `TranslationBudget`
    /// ——2026-08-19 分档实测：约 0.042 秒/字，190 字左右就撞穿 8 秒，
    /// 而基准集最长才 64 字，所以这个数在长段口述上一直是错的。
    static let defaultTimeout: Duration = TranslationBudget.floor

    private let translator: any Translator
    private let gate: TranslationGate
    /// 源语言与目标语言在挂载那一刻定死——一次会话内规则不变
    /// （`DictationSession.attachTranslation` 的既有语义），中途换设置
    /// 走协调器重建管线，不改这两个值。
    /// 非 private：`TranslationAttachmentCoordinatorTests.builtPipelineCarriesInputAndTarget`
    /// 要断言协调器建出的管线带的确实是当时的 (输入, 目标)。「值对了」和
    /// 「接上了」必须分开验——建管线处硬写一个 `.chinese`，纯函数那组用例
    /// 一条都不会红。
    let source: Language
    let target: Language
    /// 非 private：`TranslationPipelineTests` 要断言默认值真的被接到了构造器上。
    /// 只声明一个常量、构造器里却填别的数，是没有测试能从行为上分辨的
    /// （默认 8 秒与 30 秒在任何一条用例上都不会红）。
    let timeout: Duration

    init(
        translator: any Translator,
        source: Language,
        target: Language,
        gate: TranslationGate = TranslationGate(),
        timeout: Duration = TranslationPipeline.defaultTimeout
    ) {
        self.translator = translator
        self.source = source
        self.target = target
        self.gate = gate
        self.timeout = timeout
    }

    /// 后台预热。**只在挂载时调用，不要放在注入路径上**——
    /// 加载一次本地模型要几十秒。
    func prepareTranslator() async throws {
        // 耗时的理由与 `CorrectionPipeline.warmUp` 那条一字不差：翻译层与
        // 校正层共用同一个 `ModelContainer`，而「共用命中」与「又加载了一遍」
        // 在日志里长得一模一样，只有耗时分得开——实测冷加载 14.1 秒、
        // 有页缓存 3.7–8.0 秒（M8 第 0 步），命中时应当接近 0。
        //
        // 失败也要记：只在成功那条记的话，两次都失败时看不出第二次有没有
        // 真的重试过。**本函数照旧抛错**，调用方的降级路径不变。
        let started = ContinuousClock.now
        do {
            try await translator.prepare()
            AppLogger.shared.log("翻译模型预热完成 耗时 \(ContinuousClock.now - started)")
        } catch {
            AppLogger.shared.log("翻译模型预热失败 耗时 \(ContinuousClock.now - started)：\(error)")
            throw error
        }
    }

    /// 返回译文（或退回的中文原文）与给 HUD 的标注。**本函数不抛错。**
    func translate(_ text: String) async -> TranslationResult {
        // 目标==源就是「不翻译」，连翻译器都不该碰——它可能还要加载模型。
        // 协调器保证 source != target；万一建错，恒等是唯一无害的行为。
        guard target != source else { return TranslationResult(text: text, annotation: nil) }
        // 用户没说话，没什么可译的，也没什么可提示的。
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TranslationResult(text: text, annotation: nil)
        }

        // **先做确定性改写：中文数词 → 阿拉伯数字（四百六十万 → 4600000）。**
        //
        // 这是数量级错的修法本体。2026-08-20 实测（qwen3-4b × 六语 × 20 条
        // 数词语料）：模型自己换算错 33/192 ≈ 17%（两万三→230,000、96万8
        // 六语全错），给提示词加换算定义毫无效果（33→40）；而「照抄阿拉伯
        // 数字」它可靠（digits 语料 12/12）。所以换算不交给模型。
        //
        // 三条边界：
        // - **给翻译器与闸门的是改写后的**（那才是模型真实的输入）；
        //   **所有失败路径退回的仍是 `text` 原文**——用户要看到的是他说的话。
        // - 解析不出的形态（一个亿）原样进模型，行为与从前相同。
        // - 源不是中文时改写不会发生。
        //
        // 中文数词改写只属于中文源——判据、实测、语料全是中文的。
        let rewritten = source == .chinese ? ChineseNumerals.rewriteAsDigits(text) : text
        if rewritten != text {
            AppLogger.shared.log("翻译前数词改写：\(text.count) 字 → \(rewritten.count) 字")
        }

        // **不在这里等加载。** 加载要几十秒，而调用方带着注入预算，
        // 等下去只会把注入一起拖住（M4 同款处理，见 `CorrectionPipeline.correct`）。
        // 这里连 `prepare()` 都不能顺手 await 一下：那正是「等加载」本身。
        guard await translator.isReady else {
            AppLogger.shared.log("翻译跳过：模型尚未就绪")
            return TranslationResult(text: text, annotation: .modelLoading)
        }

        // **按这一段的长度算预算，不用构造时那个固定值。**
        // `timeout` 现在的语义是「下限」：短句照旧 8 秒，长段按
        // 0.05 秒/字放大到最多 30 秒（上限的理由见 `TranslationBudget`）。
        //
        // 算在 do 外面，因为超时那条 catch 要把它写进日志——只写「超时」
        // 而不写预算和字数，事后无从判断该把系数调到多少。
        // 预算按改写后的字数算——那才是模型要处理的长度。
        let budget = max(timeout, TranslationBudget.scaled(forCharacters: rewritten.count))
        let started = ContinuousClock.now
        let output: String
        do {
            output = try await withTimeout(budget) {
                try await translator.translate(rewritten, from: source, to: target)
            }
        } catch is TimedOut {
            // 记耗时：只写「超时」看不出实际要多久，也就无从判断预算该调到多少。
            AppLogger.shared.log(
                "翻译超时：源=\(source.rawValue) 目标=\(target.rawValue) 字数=\(rewritten.count) 预算=\(budget) 耗时 \(ContinuousClock.now - started)")
            return TranslationResult(text: text, annotation: .timedOut)
        } catch let error as TranslatorError {
            switch error {
            case .missingAPIKey:
                AppLogger.shared.log("翻译失败：云端未配置 API key")
                return TranslationResult(text: text, annotation: .missingAPIKey)
            case .locationNotSupported:
                AppLogger.shared.log("翻译失败：云端不支持当前网络所在的地理位置")
                return TranslationResult(text: text, annotation: .locationNotSupported)
            case .modelNotReady:
                // 上面的 isReady 查过了还能撞上这一条：加载在两次检查之间被卸掉，
                // 或者实现自己判断得更严。对用户是同一件事——等一下再说。
                AppLogger.shared.log("翻译跳过：引擎报模型尚未就绪")
                return TranslationResult(text: text, annotation: .modelLoading)
            case .timedOut:
                // 引擎自己判的超时（云端请求超时）。与我们的预算判的是同一件事。
                AppLogger.shared.log("翻译超时：引擎自报 源=\(source.rawValue) 目标=\(target.rawValue)")
                return TranslationResult(text: text, annotation: .timedOut)
            case .engineFailed(let message):
                AppLogger.shared.log("翻译失败：\(message)")
                return TranslationResult(text: text, annotation: .failed(message))
            }
        } catch {
            // 不是 TranslatorError 的都落这里（云端实现会漏出 URLError 之类）。
            // **不能只 catch 已知的错误类型**：漏掉的那个会顺着 async 往上抛，
            // 而本类型对调用方的承诺是「不抛错」。
            AppLogger.shared.log("翻译失败：\(error)")
            return TranslationResult(text: text, annotation: .failed(String(describing: error)))
        }

        // 闸门的 source 用改写后的：长度比比的是「模型的输入对输出」，
        // 拿改写前的原文去比会把改写本身的长度变化算到译文头上。
        switch gate.check(source: rewritten, translation: output, from: source, to: target) {
        case .pass:
            AppLogger.shared.log(
                "翻译完成：源=\(source.rawValue) 目标=\(target.rawValue) 耗时 \(ContinuousClock.now - started)")
            return TranslationResult(text: output, annotation: nil)
        case .reject(let reason):
            // **记明是哪一条不过**——只说「被拦下」的话，
            // 调参时无从判断是模型的问题还是阈值的问题。
            AppLogger.shared.log("翻译被闸门拦下：\(reason) 源=\(source.rawValue) 目标=\(target.rawValue)")
            return TranslationResult(text: text, annotation: .rejected(reason))
        }
    }
}

/// 超时哨兵。
private struct TimedOut: Error {}

/// 给一段异步工作加超时。
///
/// **用两个非结构化 Task 赛跑，不用 `withThrowingTaskGroup`**——后者会
/// 等所有子任务结束，而推理任务不响应取消（`Evaluate.swift:597-646` 全程
/// 无取消检查，M4 期间读过源码确认），等于超时形同虚设。
/// `CorrectionPipeline.editsWithTimeout` 是同一个写法。
private func withTimeout<T: Sendable>(
    _ duration: Duration,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    let box = ResultBox<T>()
    let worker = Task {
        do { await box.finish(.success(try await work())) } catch { await box.finish(.failure(error)) }
    }
    let timer = Task {
        try? await Task.sleep(for: duration)
        await box.finish(.failure(TimedOut()))
    }
    // 计时器要收掉：推理先到时它还挂在那儿睡着，白占一个任务。
    defer { timer.cancel() }
    // **不取消 worker**：取消省不下 GPU（推理不响应取消，生产方是
    // `ChatSession.stream()` 内部的非结构化 Task），却会让「推理已落地」
    // 这个唯一可观测的信号提前发出。M4 的同款结论，见 `editsWithTimeout`。
    _ = worker
    return try await box.value().get()
}

/// 只保留第一个送达的结果，之后的一律丢弃。
///
/// 存在的理由：超时与推理是两个非结构化任务的竞速，谁先到谁作数，
/// 而调用方**不等**落后者——这正是 TaskGroup 做不到的事。
private actor ResultBox<T: Sendable> {
    private var stored: Result<T, Error>?
    private var waiters: [CheckedContinuation<Result<T, Error>, Never>] = []

    func finish(_ result: Result<T, Error>) {
        guard stored == nil else { return }
        stored = result
        for waiter in waiters { waiter.resume(returning: result) }
        waiters.removeAll()
    }

    func value() async -> Result<T, Error> {
        if let stored { return stored }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
