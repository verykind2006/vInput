import Foundation

/// 会话那一侧「挂翻译」需要的全部东西——只有两件：当前状态、挂载入口。
///
/// 抽成 protocol 不是为了给测试塞一个假会话（下面那套测试用的是**真的**
/// `DictationSession`），而是为了让协调器不必知道 `DictationSession` 的
/// 其余三十个成员。真替身在这里没有价值：要守的恰恰是
/// `attachTranslation` 那条「只在 idle 时接受挂载」的语义，
/// 假会话只会把它复刻一遍，而复刻出来的那一份和实际跑的那一份是否一致，
/// 没有任何东西守着——本仓库栽过七次的正是这类。
@MainActor
protocol TranslationAttachTarget: AnyObject {
    var state: DictationSession.State { get }
    func attachTranslation(_ pipeline: TranslationPipeline?)
}

extension DictationSession: TranslationAttachTarget {}

/// 翻译层的挂载状态机：按偏好决定挂什么、挂不上时记着、回到 idle 时补挂。
///
/// # 为什么它必须从 `AppModel` 里搬出来
///
/// 这段逻辑原来长在 `AppModel.applyTranslationPreference` 里，而
/// `AppModel` 在测试进程里**起不来**——`init` 就要真快捷键、真 CGEvent tap、
/// 真麦克风。后果不是「覆盖率低一点」，是**零覆盖**：Task 11 的实施者做过
/// 两次变异，都在全量 899 条测试下全绿：
///
/// 1. 把 `session.attachTranslation(...)` 那一句整个删掉——翻译层永远挂不上，
///    用户选了英文却一直出中文；
/// 2. 把「会话忙时记下待补挂」丢掉——用户在录音途中换语言，这次改动永远丢失，
///    而菜单已经写着新语言，等于在骗人。
///
/// 搬出来之后这两条各自有用例红，见
/// `TranslationAttachmentCoordinatorTests` 顶部的变异表。
///
/// # 「抽出来的那个」就是「实际跑的那个」，靠三件事保证
///
/// 1. **搬走，不是复制。** `AppModel` 里不再有 `translationPipeline` 字段，
///    也不再有任何一处 `attachTranslation` 调用——本类型是唯一的实现。
/// 2. **`AppModelWiringTests` 扫源码钉住调用点**：`AppModel` 必须调
///    `translationCoordinator.apply()` 与 `sessionDidBecomeIdle()`，
///    且**不许**自己再出现 `attachTranslation`（那意味着又长出了第二条路径）。
/// 3. **测试用真的 `DictationSession`**，不用假会话。要守的「只在 idle 时
///    接受挂载」就长在真会话上，假会话只会把它复刻一遍。
///
/// # 行为与搬家前一字不差
///
/// 搬家的目的是可测，不是改行为。逐条对照：镜像（`target` / `modelMissing`）
/// 在会话 guard **之前**更新（菜单标题当场就对）；会话不在 idle 时记 pending
/// 并写日志；四种挂载各自的日志；`attachTranslation` 写在 switch **外面**
/// 四格共用；预热用 detached 任务不占主线程。
@MainActor
final class TranslationAttachmentCoordinator {
    /// 做判断要读的四个值。做成一个结构体而不是四个参数，是为了让
    /// 「每次 apply 都重新读一遍偏好」这件事有个明确的形状——补挂那次必须
    /// 读**当时**的偏好，而不是第一次被拒时的那份快照。
    struct Inputs: Equatable {
        var target: Language
        var usesCloudBackend: Bool
        var translationModelDirectory: URL?
        var correctionModelDirectory: URL?
        /// 云端用哪个模型的标识符。
        ///
        /// **走 `Inputs` 而不是让 `AppModel` 自己造翻译器**：出站面那条
        /// 源码扫描守卫钉住「全仓库只有一处能造出云端翻译器」，而零出站
        /// 那套用例正是靠替换那一处才观测得到的。绕开它新造一个，用例
        /// 一条都不会红，而请求会真的出站。
        var cloudModel: String = CloudTranslationModel.default.identifier
    }

    /// 生产用的预热：detached 而非 `Task {}`。
    ///
    /// 后者继承 MainActor，加载的同步段会卡住主线程上的 UI。加载一次本地
    /// 模型要几十秒（M8 第 0 步实测冷加载 14.1 秒），共用登记处命中时
    /// 这一次几乎是白捡的。
    /// 写成 `nonisolated func` 而不是 `static let` 闭包：后者是 MainActor
    /// 隔离的存储属性，被当作构造器默认值（默认值求值在 nonisolated 上下文）
    /// 引用时 Swift 6 语言模式下是错误。
    nonisolated static func detachedWarmUp(_ pipeline: TranslationPipeline) {
        Task.detached(priority: .utility) { try? await pipeline.prepareTranslator() }
    }

    private let inputs: @MainActor () -> Inputs
    private let session: @MainActor () -> (any TranslationAttachTarget)?
    private let makeTranslator: @MainActor (URL) -> any Translator
    private let makeCloudTranslator: @MainActor (String) -> any Translator
    private let cloudKeyAvailable: @MainActor () -> Bool
    private let isUsableModelDirectory: @MainActor (URL) -> Bool
    private let warmUp: @MainActor (TranslationPipeline) -> Void
    private let log: @MainActor (String) -> Void

    /// 当前生效的翻译流水线。目标是中文（不翻译）时为 nil。
    ///
    /// **摘掉而不是挂一个空转的**：不摘的话每次听写都要多走一次
    /// `requiresTranslation` 判断和一次 actor 跳转，而那是白付的。
    private(set) var pipeline: TranslationPipeline?

    /// 最近一次 `apply()` 读到的输出语言。`AppModel` 的可观察镜像从这里取。
    private(set) var target: Language = .chinese

    /// 选了外语却一个可用的模型目录都没有。同上，供菜单后缀与 HUD 用。
    private(set) var modelMissing = false

    /// 最近一次 `apply()` 算出来的挂载结论。菜单的「翻译后端：…」由它推出。
    ///
    /// **菜单必须读这个，不能读偏好里的那个布尔值。** 「云端开关开着」与
    /// 「这次真的会走云端」是两回事——输出语言是中文时结论是 `.detach`，
    /// 一个字节都不出站，而菜单若直接印开关状态就会说成正在往外发。
    private(set) var attachment: AppModel.TranslationAttachment = .detach

    /// 最近一次「确实要走云端」时，Keychain 里有没有 key。
    ///
    /// **只在 `attachment == .cloud` 时才查，一次 `apply()` 至多一次。**
    /// 用 `security add-generic-password` 存进去的条目，ACL 里没有本 app，
    /// 头一次读会弹系统授权对话框。于是：
    ///
    /// - 菜单**不去读 Keychain**，只读这个镜像——否则每打开一次菜单就可能
    ///   弹一次框，而菜单是用户每天点很多次的东西；
    /// - 中文（＝不翻译）那一格一次都不读：那一格本来就零出站，
    ///   key 在不在与它无关，为了「状态更准」去弹一个框是纯赔本。
    ///
    /// 代价是：用户在挂载之后才把 key 存进 Keychain 时，菜单会继续写着
    /// 「缺 API key」直到下一次 `apply()`。**只是显示旧了，行为是对的**——
    /// `GeminiTranslator` 每次请求都现读 Keychain，下一句话就生效。
    /// 菜单里另有一个「重新检查 API key」让用户自己刷新
    /// （`AppModel.recheckCloudAPIKey`）。
    private(set) var cloudKeyPresent = false

    /// 上一次挂载被会话拒绝（当时不在 idle），或者会话还不存在。
    ///
    /// 用户在录音中或转写那几秒里从菜单换语言是很自然的动作，而
    /// `DictationSession` 只在 idle 时接受挂载。不记住这件事的话，那次改动
    /// 就永远丢失了——而菜单已经写着新语言，等于在骗人。
    private(set) var isPending = false

    /// - Parameters:
    ///   - makeCloudTranslator: 造云端翻译器。**这是本 app 唯一能造出
    ///     `GeminiTranslator` 的地方**，也是唯一一条出站路径——`Sources/`
    ///     里除了这个默认值再没有第二处 `GeminiTranslator(`，由
    ///     `CloudEgressTests` 扫源码钉住（那条扫描不剥注释，所以这里刻意
    ///     不写出那个网络类型的名字，免得把自己扫进允许清单）。零出站那条
    ///     用例正是把这个工厂换成「带记录型会话的真 `GeminiTranslator`」，
    ///     从而观测得到「本该发出的请求一条都没发」。
    ///   - cloudKeyAvailable: Keychain 里有没有 key。**只用来立刻告诉用户
    ///     一声**，不参与「挂什么」的判断——缺 key 时照样挂云端，绝不退回
    ///     本地（那会让用户以为走的是云端，实际跑的是本机模型）。
    ///     真正读 key 的是 `GeminiTranslator` 自己，且是在**每次请求时**读：
    ///     用户中途把 key 存进 Keychain 之后，下一句话就生效，不必回菜单
    ///     重选一次语言。
    ///   - isUsableModelDirectory: 这个目录今天还是个能用的 MLX 模型目录吗。
    ///     **默认值就是校正层开启时用的那一个判据**
    ///     （`CorrectionModelCatalog.validate`），不另写一套——两份判据迟早
    ///     松紧不一，而表现是「校正说这目录不行、翻译照挂」。
    ///
    ///     借目录也要借校验的理由写在 `AppModel.translationAttachment` 上：
    ///     校正的启动自检把失效目录判掉时**只关开关、不清目录**，翻译层
    ///     照挂的话每次听写 HUD 都说「翻译模型还在加载」，而那个加载永远
    ///     不会完成。
    init(
        inputs: @escaping @MainActor () -> Inputs,
        session: @escaping @MainActor () -> (any TranslationAttachTarget)?,
        makeTranslator: @escaping @MainActor (URL) -> any Translator,
        makeCloudTranslator: @escaping @MainActor (String) -> any Translator = {
            GeminiTranslator(model: $0)
        },
        cloudKeyAvailable: @escaping @MainActor () -> Bool = {
            TranslationKey.read(service: TranslationKey.geminiService) != nil
        },
        isUsableModelDirectory: @escaping @MainActor (URL) -> Bool = { directory in
            if case .success = CorrectionModelCatalog.validate(directory: directory) { return true }
            return false
        },
        warmUp: @escaping @MainActor (TranslationPipeline) -> Void
            = TranslationAttachmentCoordinator.detachedWarmUp,
        log: @escaping @MainActor (String) -> Void = { AppLogger.shared.log($0) }
    ) {
        self.inputs = inputs
        self.session = session
        self.makeTranslator = makeTranslator
        self.makeCloudTranslator = makeCloudTranslator
        self.cloudKeyAvailable = cloudKeyAvailable
        self.isUsableModelDirectory = isUsableModelDirectory
        self.warmUp = warmUp
        self.log = log
    }

    /// 按当前偏好挂（或摘掉）翻译流水线。
    func apply() {
        let current = inputs()
        // **镜像与「缺目录」的判断排在会话状态 guard 之前。** 用户点完菜单，
        // 菜单标题与那条 HUD 提示必须当场就对——哪怕这次挂载要等这一轮会话
        // 结束。放到 guard 之后的话，录音途中换语言会出现「菜单还写着旧语言」，
        // 而那正是这个镜像存在的理由。
        target = current.target

        let attachment = AppModel.translationAttachment(
            target: current.target,
            usesCloudBackend: current.usesCloudBackend,
            translationModelDirectory: current.translationModelDirectory,
            correctionModelDirectory: current.correctionModelDirectory,
            isUsableModelDirectory: isUsableModelDirectory
        )
        self.attachment = attachment
        modelMissing = attachment == .unconfigured
        // **Keychain 只在真要走云端时读。** 读它可能弹系统授权框，理由与
        // 「一次 apply 至多读一次」都写在 `cloudKeyPresent` 上。
        // 这一句必须留在 `attachment == .cloud` 的条件里、也必须留在会话
        // guard 之前：前者保证中文那一格一次都不读，后者保证录音途中开云端
        // 时菜单当场就对（与镜像同一条理由）。
        if attachment == .cloud { cloudKeyPresent = cloudKeyAvailable() }

        guard let session = session() else {
            isPending = true
            return
        }
        guard session.state == .idle else {
            isPending = true
            log("输出语言本次会话不生效（当前 \(session.state)），会话结束后补挂")
            return
        }

        switch attachment {
        case .detach:
            pipeline = nil
        case .local(let directory):
            let built = TranslationPipeline(
                // **闸门与超时都用默认值。** 两个数各自有实测支撑
                // （闸门 1.1、超时 8 秒）且各自有测试守着，在调用点硬写一个
                // 数等于绕过那两条守卫，而且不会有人发现。
                translator: makeTranslator(directory),
                // TEMP(Task 7 重写)：协调器还没带输入语言
                source: .chinese,
                target: current.target
            )
            pipeline = built
            log("翻译已启用：目标=\(current.target.rawValue) 模型目录=\(directory.path)")
            // 与校正同一个道理：加载一次要几十秒，注入路径上一秒都不能等。
            warmUp(built)
        case .cloud:
            // **云端的超时下限比本机高得多**，理由见
            // `TranslationBudget.cloudFloor`：实测均 7.2 秒、最长 12.7 秒，
            // 而本机那个 8 秒会把成功返回的云端译文也掐掉。
            let built = TranslationPipeline(
                translator: makeCloudTranslator(current.cloudModel),
                // TEMP(Task 7 重写)：协调器还没带输入语言
                source: .chinese,
                target: current.target,
                timeout: TranslationBudget.cloudFloor
            )
            pipeline = built
            // 用上面那次读的结果，不再读第二次——见 `cloudKeyPresent`。
            if cloudKeyPresent {
                // **明说「文字会离开本机」。** 产品大原则是一切不出本机，
                // 出站是唯一需要用户事后能在日志里查证的那件事。
                log("翻译已启用：云端 Gemini，目标=\(current.target.rawValue)（文字会离开本机）")
            } else {
                // **缺 key 绝不静默、也绝不退回本地。**
                //
                // M6 ③ 的直接教训：一个静默不工作的功能，用户看到的只有
                // 「没变化」，无从判断是哪一种。这里给两处提示——这条日志
                // 当场就有（含存 key 的命令，用户不必去翻文档），
                // 以及每次听写时 HUD 上的
                // `TranslationAnnotation.missingAPIKey`（云端翻译器在
                // `translate` 里抛 `.missingAPIKey`，一个字节都不出站）。
                log(
                    "翻译已启用但云端缺 API key：目标=\(current.target.rawValue)，"
                        + "每次听写都会退回中文原文并在 HUD 上说明。"
                        + "存 key：security add-generic-password -a vInput -s "
                        + "\(TranslationKey.geminiService) -w"
                )
            }
            // 云端没有权重要加载，预热在这里买到的是**在用户开口之前**就把
            // 缺 key 这件事捅出来（`GeminiTranslator.prepare` 会抛
            // `.missingAPIKey`，`TranslationPipeline.prepareTranslator` 记日志）。
            warmUp(built)
        case .unconfigured:
            pipeline = nil
            // **说清楚查过哪两个位置**，只说「没配」的话用户不知道去哪儿配。
            //
            // 措辞是「未指定或已失效」而不是「未指定」：目录被移动/改名之后
            // 校正的启动自检只把开关落回「关」、**不清目录**，此时用户是
            // 「配过了」的，一句「未指定」会让他去找一个根本不存在的配置项。
            log(
                "翻译未启用：目标=\(current.target.rawValue)，但没有可用的模型目录"
                + "（translation.modelDirectory 与校正模型目录都未指定，"
                + "或指定的目录已失效——被移动、改名，或不是 MLX 模型目录），"
                + "请在「校正」菜单里指定本地模型目录"
            )
        }

        // **挂载写在 switch 外面，四条分支共用这一句。** 写进 switch 的话，
        // 四格里漏掉一格是迟早的事，而漏掉 `.detach` 的表现是「用户切回中文
        // 却还在出英文」——一句话被翻译过之后再也退不回来，用户只能重启。
        // 摘掉也是一次挂载：`pipeline` 在上面四格里已经各自置好，
        // 这里只负责把它送进会话。
        session.attachTranslation(pipeline)
        isPending = false
    }

    /// 会话回到 idle 时调一次，把此前被拒绝的挂载补上。
    ///
    /// **判 `isPending` 而不是每次都 `apply()`**：每次会话结束都重挂一遍的话，
    /// 每说一句话就会新建一条流水线、并再排一次预热任务；而
    /// `MLXTranslator` 换了新实例就要重新走一遍 `OneShotLoader` 的判重路径，
    /// 共用登记处虽然兜得住权重，白付的 actor 与任务却是每句一次。
    func sessionDidBecomeIdle() {
        guard isPending else { return }
        apply()
    }
}
