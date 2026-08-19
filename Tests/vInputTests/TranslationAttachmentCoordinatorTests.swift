import Foundation
import Testing

@testable import vInput

/// 翻译层挂载状态机的行为覆盖——**这一段此前是零覆盖**。
///
/// # 变异表（2026-08-19 实测，全部在 `./scripts/test.sh` 下跑）
///
/// 「搬家前」那两行是把新文件挪走、`AppModel.swift` 回到 HEAD 之后**重新
/// 跑出来的**，不是转述上一个任务的结论。
///
/// 头两行的「搬家后」是**合并前 QA 之后重新跑的**（990 tests 基线）。此前写的
/// 是 4 条 / 2 条，那是云端那套用例（`CloudEgressTests`，同在本文件）加进来
/// **之前**量的——数字变大是覆盖变厚，不是当时量错。**这一轮把变异数字当
/// 证据用，数字本身就该对得上。**
///
/// | 变异 | 搬家前（长在 `AppModel` 里） | 搬家后 |
/// |---|---|---|
/// | 删掉「把流水线挂到会话上」那一句 | **899/899 全绿** | **本文件 7 条红 / 9 处断言**（全局也是 7 条，一条都没落到别的文件） |
/// | 丢掉「会话忙时记下待补挂」（`session.state != .idle` 那道 guard 里的 `isPending = true`） | **899/899 全绿** | **本文件 1 条红 / 2 处断言**（`sessionIsBusy…` 那条；「会话还不存在」走的是另一道 guard，没被这条变异碰到） |
/// | `.detach` 分支不摘（保留上一条流水线） | — | `switchingBackToChineseDetaches` 红 |
/// | 镜像更新挪到「会话必须 idle」那道 guard 之后 | — | `mirrorsUpdateEvenWhenAttachRefused` 红 |
/// | `sessionDidBecomeIdle` 去掉 `isPending` 判断 | — | `idleWithoutPendingDoesNotRebuild` 红 |
/// | `AppModel` 不再调 `coordinator.apply()` | — | `AppModelWiringTests` 1 条红 |
/// | `AppModel` 不再调 `sessionDidBecomeIdle()` | — | `AppModelWiringTests` 1 条红 |
///
/// **`.detach` 那条最初是漏网的**：只断言「注入的是中文」时它照样绿——
/// `attachTranslation` 同时带着 target，陈旧的流水线根本轮不到被调。
/// 补上的断言与它真正的代价写在 `switchingBackToChineseDetaches` 里。
///
/// # 为什么这些用例证明的是「实际跑的那条路径」
///
/// 三件事一起保证：
///
/// 1. **协调器是唯一的实现**——`AppModel` 里已经没有 `translationPipeline`
///    字段，也没有任何一处 `attachTranslation` 调用；
/// 2. `AppModelWiringTests` 扫源码钉住 `AppModel` 确实在调它，且**不许**
///    自己再长出第二条路径；
/// 3. **本文件用的是真的 `DictationSession`，不是假会话**。要守的
///    「只在 idle 时接受挂载」就长在真会话上；假会话只会把这条语义复刻一遍，
///    而复刻件与真件是否一致没有任何东西守着——本仓库栽过七次的正是这类。
///
/// 断言也一律落在**注入到 sink 的那串字**上，而不是「协调器的某个字段等于
/// 某个值」：后者在「挂载那句被删掉」时照样全绿。
@MainActor
@Suite("翻译层挂载协调器")
struct TranslationAttachmentCoordinatorTests {
    // MARK: - 2×2 那张表的下游：每一格都跑到注入为止

    /// | 中文 | 云端关 | 翻译层完全不参与 | 零出站 |
    @Test("中文 + 云端关：翻译器一次都没被造出来")
    func chineseLocalNeverBuildsTranslator() async throws {
        let harness = Harness(target: .chinese)
        harness.coordinator.apply()
        try await harness.runSession()

        #expect(harness.sink.received == [Harness.transcript])
        #expect(harness.translatorDirectories.isEmpty, "中文不该造出任何翻译器")
        #expect(harness.warmUpCount == 0, "中文不该预热任何模型")
    }

    /// | 中文 | **云端开** | **同上——一个字节都不出站** |
    ///
    /// **这一格是整张表里最容易漏的。** 用户可能为某次需要打开过云端、
    /// 之后忘了关。`TranslationAttachmentTests` 已经钉住了判断本身返回
    /// `.detach`，这里钉的是它的下游：走到注入为止，翻译器一次都没被构造，
    /// 也没有任何一条与云端有关的日志（那会让用户以为有东西出站了）。
    @Test("中文 + 云端开：仍然一个字节都不出站，也不提云端")
    func chineseWithCloudStillDetaches() async throws {
        let harness = Harness(target: .chinese, cloud: true)
        harness.coordinator.apply()
        try await harness.runSession()

        #expect(harness.sink.received == [Harness.transcript])
        #expect(harness.translatorDirectories.isEmpty)
        #expect(harness.cloudTranslatorCount == 0, "中文不该造出云端翻译器")
        #expect(
            harness.logs.allSatisfy { !$0.contains("云端") },
            "输出语言是中文时不该出现任何与云端有关的日志。实际：\(harness.logs)"
        )
    }

    /// | 外语 | 云端关 | 本地 MLXTranslator | 零出站 |
    ///
    /// 这条同时是「挂载那一句」最直接的守卫：删掉它，注入的就是中文原文。
    @Test("外语 + 云端关：挂上本地翻译，注入的是译文")
    func foreignLocalTranslates() async throws {
        let harness = Harness(target: .english)
        harness.coordinator.apply()
        try await harness.runSession()

        #expect(harness.sink.received == [Harness.translated])
        #expect(harness.translatorDirectories == [Harness.correctionDirectory])
        #expect(harness.warmUpCount == 1, "挂上之后必须排一次后台预热")
    }

    /// | 外语 | 云端开 | 云端 `GeminiTranslator` |
    ///
    /// 关键在于**不能退回本地**：那样用户以为走的是云端，实际跑的是本机模型。
    /// 这一格走到真的发出请求为止，见下面的 `CloudEgressTests`。
    @Test("外语 + 云端开：不造本地翻译器")
    func foreignCloudDoesNotFallBackToLocal() async throws {
        let harness = Harness(target: .english, cloud: true)
        harness.coordinator.apply()
        try await harness.runSession()

        #expect(harness.translatorDirectories.isEmpty, "选了云端却造出了本地翻译器")
        #expect(harness.cloudTranslatorCount == 1, "选了云端却没造云端翻译器")
        // **云端也要预热，理由和本地完全不同。** 云端没有权重要加载，这一次
        // 预热买到的是「在用户开口之前就把缺 key 捅出来」——`prepare()` 会抛
        // `.missingAPIKey`，`prepareTranslator` 记一条日志。
        //
        // 2026-08-19 QA 实测：把 `.cloud` 那格的 `warmUp(built)` 删掉，
        // 981 tests 一条不红；而同一个 switch 里 `.local` 那格删掉是 3 条红。
        // 同一个 switch 的两格，一格有守卫一格没有。
        #expect(harness.warmUpCount == 1, "云端那格漏了预热：缺 key 要在用户开口之前就说")
    }

    /// 选了外语但一个模型目录都没有：**不许静默**。
    @Test("外语 + 无模型目录：点亮缺目录标志，注入中文原文")
    func unconfiguredIsVisibleAndFallsBackToChinese() async throws {
        let harness = Harness(target: .english, correctionDirectory: nil)
        harness.coordinator.apply()
        try await harness.runSession()

        #expect(harness.coordinator.modelMissing, "缺目录必须点亮，菜单后缀与 HUD 都靠它")
        #expect(harness.sink.received == [Harness.transcript])
        #expect(harness.translatorDirectories.isEmpty)
    }

    /// **缺目录那条日志是唯一说清「去哪儿配」的话，它自己也要有守卫。**
    ///
    /// 2026-08-19 QA 实测：把这条日志整句删掉，981 tests 一条不红。菜单上
    /// 那个「（缺模型目录）」后缀只说了「缺」，说不了「查过哪两个位置」，
    /// 更说不了「去「校正」菜单里配」——那正是用户唯一需要知道的事。
    ///
    /// 钉三件事，缺一件用户就得靠猜：查过的两个位置、目录可能是**失效**
    /// 而非未配（挪走/改名之后校正只关开关、不清目录，此时用户是「配过」的，
    /// 一句「未指定」会让他去找一个不存在的配置项）、以及去哪儿配。
    @Test("缺目录时那条日志说清查过哪两个位置、也说清去哪儿配")
    func unconfiguredLogSaysWhereToConfigure() {
        let harness = Harness(target: .english, correctionDirectory: nil)
        harness.coordinator.apply()

        let joined = harness.logs.joined(separator: "\n")
        #expect(joined.contains("translation.modelDirectory"), "实际日志：\(joined)")
        #expect(joined.contains("校正模型目录"), "实际日志：\(joined)")
        #expect(joined.contains("失效"), "实际日志：\(joined)")
        #expect(joined.contains("「校正」菜单"), "实际日志：\(joined)")
    }

    /// **曾经配过、如今失效的目录：不许照挂。**
    ///
    /// 这是「借了校正层的目录，却没借它的校验」留下的洞。走一遍用户真实的
    /// 遭遇：他把模型文件夹挪走或改了名 →
    /// `CorrectionActivation.revalidateAtLaunch()` 只把校正开关落回「关」、
    /// **不清 `modelDirectory`** → 翻译层拿到一条死路径。
    ///
    /// 挂上去的后果不是「少翻译一次」：`OneShotLoader` 失败不缓存值、
    /// `detachedWarmUp` 用 `try?` 吞掉异常且只调一次，于是每次听写都撞
    /// `guard await translator.isReady`，HUD 每句话都打「翻译模型还在加载，
    /// 本次注入中文原文」——**用户会等一个永远不会完成的加载**，而输出语言
    /// 菜单一个字警告都没有。那行字在这里是错的：不是「慢」，是「没有」。
    ///
    /// 所以这一格必须与「一个目录都没配」收敛到同一处：`.unconfigured`
    /// 那一格已经有现成的三处告知（日志 + 菜单后缀 + 换语言时的 HUD）。
    @Test("外语 + 校正目录已失效：不挂本地，落回缺目录那一格")
    func staleCorrectionDirectoryDoesNotAttach() async throws {
        let harness = Harness(target: .english, correctionDirectory: Harness.staleDirectory)
        harness.coordinator.apply()
        try await harness.runSession()

        #expect(harness.coordinator.attachment == .unconfigured)
        #expect(harness.coordinator.modelMissing, "菜单后缀与那条 HUD 都靠它，不点亮就是静默")
        #expect(harness.translatorDirectories.isEmpty, "目录已失效却照样造了个翻译器")
        #expect(harness.warmUpCount == 0, "对一条死路径排了一次注定失败的预热")
        #expect(harness.sink.received == [Harness.transcript], "规则二：不许丢字")
        // **这一条是这次修复真正买到的东西。** 挂上去的话每句话都是
        // `.modelLoading`（「翻译模型还在加载」），而它永远不会变。
        // 实测值是空数组，不是 `[nil]`：流水线为 nil 时会话根本不走翻译那一环，
        // `onTranslation` 一次都不触发。挂上去的话这里是 `[.modelLoading]`。
        #expect(
            harness.annotations.isEmpty,
            "翻译那一环还在跑，八成又在说「翻译模型还在加载」。实际：\(harness.annotations)"
        )
    }

    /// 挂上去的目录必须来自判断结果，不是随手拿一个。
    ///
    /// 两个目录都配时翻译自己的优先（`TranslationAttachmentTests` 钉的是判断，
    /// 这里钉的是「判断出来的那个真的被送进了翻译器」）。
    @Test("翻译器拿到的是判断挑出来的那个目录")
    func translatorReceivesChosenDirectory() async throws {
        // 同样是真目录：`.local` 挂上去之前要过一次真的目录校验。
        let translationDirectory = Harness.makeFakeModelDirectory()
        let harness = Harness(target: .english, translationDirectory: translationDirectory)
        harness.coordinator.apply()
        try await harness.runSession()

        #expect(harness.translatorDirectories == [translationDirectory])
    }

    // MARK: - 摘掉也是一次挂载

    /// **切回中文必须把流水线摘掉。**
    ///
    /// 漏掉 `.detach` 的表现是「用户切回中文却还在出英文」——一句话被翻译过
    /// 之后再也退不回来，用户只能重启。上面那条「中文不造翻译器」抓不到它：
    /// 那条从头到尾就没挂过东西。
    @Test("从外语切回中文时把流水线摘掉")
    func switchingBackToChineseDetaches() async throws {
        let harness = Harness(target: .english)
        harness.coordinator.apply()
        try await harness.runSession()
        #expect(harness.sink.received == [Harness.translated])

        harness.inputs.target = .chinese
        harness.coordinator.apply()
        try await harness.runSession()

        #expect(
            harness.sink.received == [Harness.translated, Harness.transcript],
            "切回中文之后还在出译文，说明流水线没被摘掉"
        )
        // **注入结果看不见「摘没摘」，所以这一条必须单独断。**
        //
        // 实测（变异③）：把 `.detach` 分支的 `pipeline = nil` 换成 `break`，
        // 上面那条断言照样绿——`attachTranslation` 同时带着 target，而
        // `DictationSession.process` 在调流水线之前先查
        // `translationTarget.requiresTranslation`，陈旧的流水线根本轮不到被调。
        //
        // 那还有什么可守的：**那条陈旧的流水线会一直被会话强引用**，
        // 而它握着 `MLXTranslator`，`MLXTranslator` 握着 `ModelContainer`
        // ——用户切回中文之后那 2 GB 权重不会被放掉。这才是 `.detach` 要摘掉
        // 而不是「反正也不会被调到」的理由，也是这条断言的全部内容。
        #expect(harness.coordinator.pipeline == nil, "切回中文后陈旧的流水线仍被握着")
    }

    // MARK: - 待补挂

    /// 会话忙时换语言：这次挂载会被会话拒绝，必须记着，回到 idle 再补一次。
    ///
    /// **丢掉 pending 的表现是「用户在录音途中换的语言永远不生效」**，
    /// 而菜单已经写着新语言——等于在骗人。本轮不生效是有意的
    /// （见 `DictationSession.attachTranslation` 的两条理由），**下一轮**
    /// 必须生效。
    @Test("会话进行中换语言：本轮不生效，回到 idle 后补挂")
    func midSessionChangeResumesOnIdle() async throws {
        let harness = Harness(target: .chinese)

        // 会话已经开始，此时改语言。
        try await harness.session.start()
        harness.inputs.target = .english
        harness.coordinator.apply()
        #expect(harness.coordinator.isPending, "被会话拒绝的挂载必须被记下来")

        harness.source.emit(Harness.samples)
        await harness.session.finish()
        #expect(harness.sink.received == [Harness.transcript], "本轮不该被翻译")

        // 会话回到 idle，`AppModel.onStateChange` 会调这一句。
        harness.coordinator.sessionDidBecomeIdle()
        #expect(!harness.coordinator.isPending)
        try await harness.runSession()

        #expect(
            harness.sink.received == [Harness.transcript, Harness.translated],
            "补挂之后下一轮必须生效"
        )
    }

    /// 会话还没建好时就 apply（`bootstrap` 之外的任何早到调用）：同样要记着。
    @Test("会话还不存在时记下待补挂，会话就绪后补上")
    func missingSessionIsPending() async throws {
        let harness = Harness(target: .english)
        harness.sessionAvailable = false

        harness.coordinator.apply()
        #expect(harness.coordinator.isPending)
        #expect(harness.translatorDirectories.isEmpty, "没有会话时不该先把流水线造出来")

        harness.sessionAvailable = true
        harness.coordinator.sessionDidBecomeIdle()
        try await harness.runSession()

        #expect(harness.sink.received == [Harness.translated])
    }

    /// 没有待补挂时，会话结束**不该**重新挂一遍。
    ///
    /// 每次会话结束都重挂的话，每说一句话就新建一条流水线并再排一次预热任务
    /// ——`MLXTranslator` 换了新实例就要重走一遍 `OneShotLoader` 的判重路径。
    /// 这条是 `guard isPending else { return }` 的守卫。
    @Test("没有待补挂时会话结束不重建流水线")
    func idleWithoutPendingDoesNotRebuild() async throws {
        let harness = Harness(target: .english)
        harness.coordinator.apply()
        #expect(harness.translatorDirectories.count == 1)
        #expect(harness.warmUpCount == 1)

        harness.coordinator.sessionDidBecomeIdle()
        harness.coordinator.sessionDidBecomeIdle()

        #expect(harness.translatorDirectories.count == 1, "没有待补挂却重建了翻译器")
        #expect(harness.warmUpCount == 1, "没有待补挂却又预热了一次")
    }

    // MARK: - 菜单要的两个状态：挂载结论、Keychain 里有没有 key

    /// **只有真要走云端的那几格才去碰 Keychain，且一次 `apply()` 只碰一次。**
    ///
    /// 读 Keychain 可能弹系统授权对话框。中文（＝不翻译）那一格本来就零出站，
    /// key 在不在与它无关；为了「菜单状态更准」去弹一个框是纯赔本。
    ///
    /// 把那句读取从 `if attachment == .cloud` 里挪出来（改成每次 apply 都读），
    /// 头两条当场红。
    @Test("只有真要走云端时才读 Keychain，且只读一次")
    func keychainIsReadOnlyWhenCloudActuallyRuns() {
        let chineseWithCloud = Harness(target: .chinese, cloud: true)
        chineseWithCloud.coordinator.apply()
        #expect(
            chineseWithCloud.cloudKeyReads == 0,
            "输出中文却去读了 Keychain：那一格零出站，读它只会白弹一个系统授权框")

        let foreignLocal = Harness(target: .english, cloud: false)
        foreignLocal.coordinator.apply()
        #expect(foreignLocal.cloudKeyReads == 0, "走本地却去读了云端的 key")

        let foreignCloud = Harness(target: .english, cloud: true)
        foreignCloud.coordinator.apply()
        #expect(foreignCloud.cloudKeyReads == 1, "云端那格读了 \(foreignCloud.cloudKeyReads) 次，应当正好一次")
        #expect(
            foreignCloud.coordinator.cloudKeyPresent, "读到了 key 却没记下来，菜单会写成「缺 API key」")
    }

    /// 缺 key 时镜像也要如实。菜单靠它显示「缺 API key，未生效」。
    @Test("缺 key 时镜像记着缺")
    func missingKeyIsMirrored() {
        let harness = Harness(target: .english, cloud: true, cloudKey: nil)
        harness.coordinator.apply()

        #expect(harness.coordinator.cloudKeyPresent == false)
        #expect(harness.coordinator.attachment == .cloud, "缺 key 不许退回本地")
    }

    /// **菜单要的状态排在会话 guard 之前算好。**
    ///
    /// 用户在录音途中开云端：这一轮挂不上（会话不在 idle），但菜单必须当场
    /// 就对——与 `mirrorsUpdateEvenWhenAttachRefused` 同一条理由。把那两句
    /// 挪到 guard 之后，本条红。
    @Test("挂载被会话拒绝时，菜单要的挂载结论与 key 状态照样算好")
    func backendMirrorsUpdateEvenWhenAttachRefused() async throws {
        let harness = Harness(target: .english, cloud: false)
        try await harness.session.start()

        harness.inputs.usesCloudBackend = true
        harness.coordinator.apply()

        #expect(harness.coordinator.attachment == .cloud, "菜单会停在「本机」，而用户刚开了云端")
        #expect(harness.cloudKeyReads == 1, "这一格的 key 状态没查，菜单只能瞎写")

        harness.source.emit(Harness.samples)
        await harness.session.finish()
    }

    // MARK: - 镜像

    /// **镜像的更新排在会话状态 guard 之前。**
    ///
    /// 用户点完菜单，菜单标题与那条「没有可用的翻译模型目录」的 HUD 提示必须
    /// 当场就对——哪怕这次挂载要等这一轮会话结束。放到 guard 之后的话，
    /// 录音途中换语言会出现「菜单还写着旧语言」，而那正是这个镜像存在的理由。
    @Test("挂载被会话拒绝时镜像照样更新")
    func mirrorsUpdateEvenWhenAttachRefused() async throws {
        let harness = Harness(target: .chinese, correctionDirectory: nil)
        try await harness.session.start()

        harness.inputs.target = .english
        harness.coordinator.apply()

        #expect(harness.coordinator.target == .english, "菜单标题会停在旧语言")
        #expect(harness.coordinator.modelMissing, "缺目录的提示会等到会话结束才出现")

        harness.source.emit(Harness.samples)
        await harness.session.finish()
    }
}

/// 「云端开着 + 输出语言是中文 ＝ 零出站」——**观测出来的，不是推理出来的**。
///
/// # 这条为什么必须有独立证据
///
/// 用户 2026-08-19 专门强调：他可能为某次需要打开云端、之后忘了关。只要
/// 输出语言是中文，就不该有任何东西出站。产品大原则是**一切不出本机**
/// （2026-08-17 确立，理由是这工具会用在含机密的场合，包括**报价**）。
///
/// 在此之前这条只由「`translationAttachment` 返回 `.detach`」间接保证——
/// 那是在推理返回值，不是在观测出站。
///
/// # 怎么保证不是自证
///
/// 一个从没被调用的翻译器当然不会发请求，断言它没发等于什么都没断言。
/// 这里三件事一起才构成证据：
///
/// 1. **翻译器是真的 `GeminiTranslator`**，由协调器的云端工厂造出来，
///    工厂里塞的是记录型 `URLSession`（`RequestRecorder`）；
/// 2. **正对照**：同一个 `Harness`、只把输出语言换成英文，就确实记到 1 条
///    发往 `generativelanguage.googleapis.com` 的 POST，请求体里装着
///    `TranslationPrompt.user` 那段。这条证明这套装置真的接在生产路径上；
/// 3. **`sourceHasSingleCloudEgressPath`** 扫源码钉住 `Sources/` 里只有那
///    一个工厂能造出 `GeminiTranslator`，也只有 `GeminiTranslator.swift`
///    一处碰 `URLSession`——绕开注入另起一条出站路径的写法会在那里红。
///
/// # 它证明不了什么
///
/// 记录器只看得见**经由被注入的那个 `URLSession`** 发出的请求。有人在
/// `Sources` 里另写一句 `URLSession.shared.data(...)` 时，本套用例看不见
/// 它——挡这一手的是第 3 条那个源码扫描，而源码扫描只能证明「那行字不在」，
/// 证明不了语义。两者分工，与 `AppModelWiringTests` 同一个取向。
///
/// 它也不覆盖 app 里翻译层之外的出站（WhisperKit 的模型下载器）。
/// 那不在本任务范围内，但源码扫描的允许清单会在有人新增网络调用时红一次，
/// 逼人回到这段注释前面重新想一遍。
///
/// # 变异表（2026-08-19 实测，全部在 `./scripts/test.sh` 下跑）
///
/// | 变异 | 结果 |
/// |---|---|
/// | `translationAttachment` 里语言判断与后端判断**对调** | **6 条红 / 8 处断言**（本文件 4：`CloudEgressTests` 2 + 「翻译层挂载协调器」2；`TranslationPreferenceTests` 1；`CloudBackendMenuTests` 1）。此前写的「3 条」是 2026-08-19 合并前 QA 复跑时发现的低估，已按当天实测订正。**注意请求数那条没红**——会话自己还有一道 `requiresTranslation`，挂上去也不会被调，抓住它的是「云端翻译器被造了几次」 |
/// | `.detach` 分支里偷偷 `makeCloudTranslator()` 并起一个 `Task` 去译 | 本文件 2 条红（都是构造计数）；请求数那条**没红**，那个 detached 任务没能在断言之前落地 |
/// | 云端开着时把云端流水线挂上去、并谎报 target 为英文 | 本文件 2 条红，**请求数那条这次红了**，日志里印出了完整的出站请求（POST、端点、362 字节请求体） |
/// | 协调器 `.cloud` 分支「没 key 就退回本地」 | `missingKeyIsLoudAndDoesNotFallBackToLocal` 一条里 5 处断言红——注入的成了本地模型的英文译文 |
/// | 在 `AppModel` 里另加一处 `GeminiTranslator()` | `sourceHasSingleCloudEgressPath` 红 |
///
/// **头两行是这套装置的边界，写在这里不是自谦**：构造计数是那条硬的，
/// 请求计数只在「真被调到」时才有话说。两条一起断言，缺一条就有变异漏网。
@MainActor
@Suite("云端出站面")
struct CloudEgressTests {
    /// **整张 2×2 表里最要紧的那一格。**
    @Test("云端开着但输出语言是中文：从偏好走到注入，请求数是 0")
    func chineseWithCloudSendsNothing() async throws {
        let harness = Harness(target: .chinese, cloud: true)

        harness.coordinator.apply()
        try await harness.runSession()

        #expect(harness.recorder.requests.isEmpty, "出站了：\(harness.recorder.requests)")
        // 请求数为 0 有两种原因：翻译器压根没被造出来（正确），
        // 或者造了但没被调用（也行，但那意味着一条云端流水线白挂着）。
        // 分开断言，好让「哪一层拦住的」是明确的。
        #expect(harness.cloudTranslatorCount == 0, "中文却造出了云端翻译器")
        #expect(harness.sink.received == [Harness.transcript])
    }

    /// **正对照：同一套接线，只把语言换成英文，就真的发出去了一条。**
    ///
    /// 没有这一条的话，上面那个「0」可以来自任何原因——工厂根本没接上、
    /// 记录器根本没被 session 用上、`URLProtocol` 没注册进去。
    /// 这条一红，上面那条就退化成空断言。
    @Test("正对照：云端开 + 外语，确实发出一条发往 Gemini 的请求")
    func foreignWithCloudActuallySendsOneRequest() async throws {
        let harness = Harness(target: .english, cloud: true)

        harness.coordinator.apply()
        try await harness.runSession()

        #expect(harness.recorder.requests.count == 1)
        let request = try #require(harness.recorder.requests.first)
        #expect(request.url?.host == GeminiTranslator.host)
        #expect(request.method == "POST")
        // 请求体里装的确实是这次听写的内容——只断言「有一条请求」的话，
        // 一条空请求也算数。
        let parts =
            (request.jsonBody?["contents"] as? [[String: Any]])?
            .first?["parts"] as? [[String: Any]]
        #expect(
            parts?.first?["text"] as? String
                == TranslationPrompt.user(for: Harness.transcript, target: .english))
        // 云端译文一路走到注入。
        #expect(harness.sink.received == [Harness.translated])
        #expect(harness.translatorDirectories.isEmpty, "走云端却顺手造了本地翻译器")
    }

    /// 开了云端却没配 key：**不许静默退回本地，也不许静默什么都不做。**
    ///
    /// M6 ③ 的直接教训是「一个静默不工作的功能，用户看到的只有『没变化』，
    /// 无从判断是哪一种」。这里用户拿到三样东西：中文原文（规则二·永不丢字）、
    /// HUD 上的 `.missingAPIKey`、以及挂载时那条带存 key 命令的日志。
    ///
    /// 把协调器的 `.cloud` 分支改成「缺 key 就退回 `.local`」时，
    /// `translatorDirectories` 那条红。
    @Test("云端开 + 外语但没配 key：注入中文原文 + HUD 说明，且一个字节都不出站")
    func missingKeyIsLoudAndDoesNotFallBackToLocal() async throws {
        let harness = Harness(target: .english, cloud: true, cloudKey: nil)

        harness.coordinator.apply()
        try await harness.runSession()

        #expect(harness.sink.received == [Harness.transcript], "规则二：不许丢字")
        #expect(
            harness.annotations == [.missingAPIKey],
            "用户要看到的是「去配 key」，不是别的任何一种失败")
        #expect(harness.recorder.requests.isEmpty, "缺 key 时把用户说的话发出去了")
        #expect(harness.translatorDirectories.isEmpty, "缺 key 时偷偷退回了本地模型")
        // 日志要能直接照着做，不必去翻文档。
        let joined = harness.logs.joined(separator: "\n")
        #expect(joined.contains("security add-generic-password"), "实际日志：\(joined)")
        #expect(joined.contains(TranslationKey.geminiService), "实际日志：\(joined)")
    }

    /// 配了 key 时那条日志要说清**文字会离开本机**。
    ///
    /// 这是产品大原则里唯一需要用户事后能查证的那件事。
    @Test("挂上云端时日志说清文字会离开本机")
    func attachLogSaysDataLeavesTheMachine() {
        let harness = Harness(target: .english, cloud: true)
        harness.coordinator.apply()

        let joined = harness.logs.joined(separator: "\n")
        #expect(joined.contains("云端"), "实际日志：\(joined)")
        #expect(joined.contains("离开本机"), "实际日志：\(joined)")
    }

    /// **菜单说会出站的那一格，正好是真的发出了请求的那一格。**
    ///
    /// 这是「菜单状态与实际行为脱节」的唯一硬证据。上面那套
    /// `CloudBackendMenuTests` 跑的是纯函数，它证明得了「这张真值表是这么
    /// 定的」，证明不了「表里说会发出的那一格真的发得出、说不发的那一格真的
    /// 一条都没发」。这一条把两头接上：状态从**协调器跑完 `apply()` 之后
    /// 记下来的挂载结论**推出（和菜单读的是同一个东西），出站与否由记录型
    /// `URLSession` 数出来。
    ///
    /// 变异：把 `translationBackendStatus` 改成直接照抄 `usesCloudBackend`，
    /// 「中文 + 云端开」那一格立刻说自己在出站，而记录器数到 0 条——本条红。
    @Test("菜单说会出站的那格，正好是真发了请求的那格")
    func menuClaimMatchesObservedEgress() async throws {
        let cases: [(name: String, harness: Harness)] = [
            ("中文 + 云端关", Harness(target: .chinese)),
            ("中文 + 云端开", Harness(target: .chinese, cloud: true)),
            ("外语 + 云端关", Harness(target: .english)),
            ("外语 + 云端开 + 没配 key", Harness(target: .english, cloud: true, cloudKey: nil)),
            ("外语 + 云端开 + 有 key", Harness(target: .english, cloud: true)),
        ]

        for (name, harness) in cases {
            harness.coordinator.apply()
            try await harness.runSession()

            // 菜单读的就是这两个值（`AppModel.syncTranslationMirrors`）。
            let status = AppModel.translationBackendStatus(
                attachment: harness.coordinator.attachment,
                usesCloudBackend: harness.inputs.usesCloudBackend,
                hasAPIKey: harness.coordinator.cloudKeyPresent
            )
            let actuallySent = !harness.recorder.requests.isEmpty

            #expect(
                status.sendsTextOffDevice == actuallySent,
                """
                【\(name)】菜单说\(status.sendsTextOffDevice ? "会" : "不会")出站，
                实际发出了 \(harness.recorder.requests.count) 条请求。
                状态：\(status)，标题：\(AppModel.translationBackendMenuTitle(status))
                """
            )
        }
    }

    // MARK: - 出站面只有一处，扫源码钉住

    /// **`Sources/` 里只有一个地方能造出 `GeminiTranslator`，也只有一个
    /// 文件碰 `URLSession`。**
    ///
    /// 上面那三条用例只看得见经由被注入的 `URLSession` 发出的请求。有人在
    /// 别处新起一条出站路径（`URLSession.shared.data(...)`、或者在
    /// `.detach` 分支里就地 `GeminiTranslator()` 一个来用），那三条一条都
    /// 不会红——而那正是「云端开 + 中文」这条路径上最危险的一种改动。
    ///
    /// 扫源码只能证明「那行字不在」，证明不了语义；语义由上面三条负责。
    /// 两者分工与 `AppModelWiringTests` 一致。
    ///
    /// 读整份文件做 `contains` 而不是逐行 grep：跨行写法（把参数换行）
    /// 行式匹配看不见——本仓库一天栽过三次这个坑。
    @Test("出站面只有一处：只有协调器的云端工厂能造 GeminiTranslator")
    func sourceHasSingleCloudEgressPath() throws {
        let sources = try Self.sourceFiles()
        #expect(sources.count > 50, "只扫到 \(sources.count) 个源文件，扫描的锚点失效了")

        let constructors = sources.filter { $0.text.contains("GeminiTranslator(") }
        #expect(
            constructors.map(\.name) == ["TranslationAttachmentCoordinator.swift"],
            """
            能造出 GeminiTranslator 的地方不止一处：\(constructors.map(\.name))。
            零出站那套用例是把协调器的云端工厂换成带记录型 URLSession 的翻译器
            才观测得到的；绕开那个工厂新造一个，用例一条都不会红，而请求会
            真的出站。
            """
        )

        // **这条扫描不剥注释。** 剥注释要自己写一个小解析器，而那玩意儿写错
        // 的表现正是「扫描看起来在扫，其实扫不到」——本仓库头号缺陷类型。
        // 代价是注释里提一句就得进清单，所以清单里注明每一处是不是真的发请求。
        let networkUsers = sources.filter { $0.text.contains("URLSession") }
        #expect(
            Set(networkUsers.map(\.name)) == [
                // 唯一真的发请求的地方。
                "GeminiTranslator.swift",
                // 只在注释里提了一句 WhisperKit 内置的下载器，本文件不发请求。
                "WhisperKitTranscriber.swift",
            ],
            """
            出站面变了：\(networkUsers.map(\.name).sorted())。
            这个 app 的产品大原则是一切不出本机（含报价这类内容），
            新增一条网络调用要先回 CloudEgressTests 的类型注释里想一遍
            「用户能不能禁掉它、禁掉之后怎么验证真的禁掉了」。
            """
        )
    }

    private struct SourceFile {
        let name: String
        let text: String
    }

    private static func sourceFiles() throws -> [SourceFile] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // vInputTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
            .appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil))
        var files: [SourceFile] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(
                SourceFile(
                    name: url.lastPathComponent,
                    text: try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }
}

/// 一套全替身的会话 + 一个协调器。
///
/// **会话是真的 `DictationSession`**，只有音频源、转写器、注入口、翻译器
/// 是替身——要守的「只在 idle 时接受挂载」就长在真会话上。
@MainActor
private final class Harness {
    /// 转写出来的中文原文。
    static let transcript = "今天下午上线。"
    /// 一条能过闸门的译文。
    ///
    /// **与 `DictationTranslationTests` 用同一对**，那边是先跑一遍量出来的：
    /// 长度比 3.5（阈值 1.1）、残留汉字 0、中文标点 0、原文与译文都以句末标点
    /// 收尾 → `.pass`。不能随手编一条不带句末标点的（例如 "We go live"），
    /// 那会被判成 `.truncated`，于是「成功路径」这条用例测的其实是闸门拦截。
    static let translated = "We go live this afternoon."
    /// 校正层的模型目录。翻译没配自己的时退回它。
    ///
    /// **这是一个真的临时目录，里面摆着真的 MLX 模型目录布局**（两个必需的
    /// json + 一个 `.safetensors`），不是 `/models/correct` 那种假路径。
    ///
    /// 理由：协调器挂 `.local` 之前会用
    /// `CorrectionModelCatalog.validate` 校一次目录（见
    /// `AppModel.translationAttachment` 上「借目录也要借校验」那一段）。
    /// 在这套装置里把那个判据 stub 成「永远放行」的话，**生产接的是哪个判据
    /// 就没有任何东西守着**——而本文件其余每一条用例都要走过它，
    /// 于是「接错了判据」会当场变成一整片红。空文件不行：真判据要求
    /// `.safetensors` 后缀与那两个 json 都在。
    static let correctionDirectory: URL = makeFakeModelDirectory()

    /// 摆一个能过 `CorrectionModelCatalog.validate` 的最小目录。
    ///
    /// 必需项**不在这里抄一份**——直接读 `CorrectionModelCatalog` 上那两个
    /// 常量。抄的话，判据加了一项时这里还是绿的，而生产已经开始拒绝
    /// 用户的目录了。
    static func makeFakeModelDirectory() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vInput-translate-attach-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        for name in CorrectionModelCatalog.requiredFiles {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent(name).path, contents: Data())
        }
        FileManager.default.createFile(
            atPath: directory
                .appendingPathComponent("model\(CorrectionModelCatalog.weightsSuffix)").path,
            contents: Data())
        return directory
    }

    /// 一条**曾经配过、如今失效**的目录：用户把模型文件夹挪走或改名了。
    ///
    /// 校正的启动自检（`CorrectionActivation.revalidateAtLaunch`）遇到它只把
    /// 开关落回「关」，**不清 `modelDirectory`**，所以翻译层照旧拿得到它。
    static let staleDirectory = URL(fileURLWithPath: "/nonexistent/moved-away-model")
    static let samples = Array(repeating: Float(0.1), count: 16_000)

    let source = FakeAudioSource()
    let sink = SpySink()
    let session: DictationSession

    /// 协调器每次 `apply()` 都会重新读它——补挂那次必须读**当时**的偏好。
    var inputs: TranslationAttachmentCoordinator.Inputs
    /// 会话是否已经建好，用来验「会话还不存在时也要记 pending」。
    var sessionAvailable = true

    /// 每次构造翻译器时收到的目录，按顺序。**「没构造」只有计数看得见**——
    /// 光看注入结果，一个从没被调用的翻译器与「挂了但目标是中文」分不开。
    var translatorDirectories: [URL] = []
    var warmUpCount = 0
    var logs: [String] = []
    /// 云端翻译器被造出来几次。
    var cloudTranslatorCount = 0
    /// 每次造云端翻译器时被要求的模型标识符。
    var cloudModelsAsked: [String] = []
    /// 云端翻译器发出的每一条请求。**这是「零出站」那条用例的观测点。**
    let recorder: RequestRecorder
    /// 假 API key。放进盒子是因为 `GeminiTranslator.readKey` 是 `@Sendable`，
    /// 捕获 `@MainActor` 的 self 会是数据竞争。真 key 一个字都不会到这里。
    let cloudKey: MutableBox<String?>
    /// 每次听写拿到的翻译标注。缺 key 时用户看到的那句 HUD 就出自这里。
    var annotations: [TranslationAnnotation?] = []
    /// 协调器查过几次「Keychain 里有没有 key」。**「没查」只有计数看得见。**
    ///
    /// 查一次可能弹一次系统授权框（用 `security` 存进去的条目，ACL 里没有
    /// 本 app），所以「哪几格会去查」本身就是要守的行为，见
    /// `keychainIsReadOnlyWhenCloudActuallyRuns`。
    var cloudKeyReads = 0

    /// 构造完立刻赋值，不会是 nil；用隐式解包是因为闭包要捕获 self。
    var coordinator: TranslationAttachmentCoordinator!

    /// - Parameters:
    ///   - cloudKey: 假的云端 API key。nil ＝ 用户开了云端却没配 key。
    ///   - cloudReply: 记录型 `URLSession` 回给云端翻译器的假响应。
    init(
        target: TranslationTarget,
        cloud: Bool = false,
        cloudKey: String? = "not-a-real-key-0000",
        cloudReply: RequestRecorder.Reply = .status(
            200, GeminiTranslatorTests.successBody(Harness.translated)),
        translationDirectory: URL? = nil,
        correctionDirectory: URL? = Harness.correctionDirectory
    ) {
        recorder = RequestRecorder(reply: cloudReply)
        self.cloudKey = MutableBox(cloudKey)
        let transcriber = FakeTranscriber()
        transcriber.result = Self.transcript
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }
        session = DictationSession(
            audioSource: source,
            transcriber: transcriber,
            sink: sink,
            targetGuard: guardian
        )
        inputs = TranslationAttachmentCoordinator.Inputs(
            target: target,
            usesCloudBackend: cloud,
            translationModelDirectory: translationDirectory,
            correctionModelDirectory: correctionDirectory
        )
        coordinator = TranslationAttachmentCoordinator(
            inputs: { [unowned self] in self.inputs },
            session: { [unowned self] in self.sessionAvailable ? self.session : nil },
            makeTranslator: { [unowned self] directory in
                self.translatorDirectories.append(directory)
                return FakeTranslator(.succeed(Self.translated))
            },
            // **这里给的是真的 `GeminiTranslator`，不是替身。**
            //
            // 换成假翻译器的话，「零出站」那条用例就退化成「我没调它，
            // 所以它没发请求」——空断言。真翻译器 + 记录型 `URLSession`，
            // 才使得「本该发出的请求一条都没发」成为一件观测得到的事，
            // 而同一套接线换成外语时确实记到一条（见正对照用例）。
            makeCloudTranslator: { [unowned self] model in
                self.cloudTranslatorCount += 1
                self.cloudModelsAsked.append(model)
                let key = self.cloudKey
                return GeminiTranslator(
                    model: model, session: self.recorder.makeSession(), readKey: { key.value })
            },
            cloudKeyAvailable: { [unowned self] in
                self.cloudKeyReads += 1
                return self.cloudKey.value != nil
            },
            warmUp: { [unowned self] _ in self.warmUpCount += 1 },
            log: { [unowned self] message in self.logs.append(message) }
        )
        session.onTranslation = { [unowned self] annotation in
            self.annotations.append(annotation)
        }
    }

    func runSession() async throws {
        try await session.start()
        source.emit(Self.samples)
        await session.finish()
    }
}
