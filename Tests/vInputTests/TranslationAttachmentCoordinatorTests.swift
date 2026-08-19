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
/// | 变异 | 搬家前（长在 `AppModel` 里） | 搬家后 |
/// |---|---|---|
/// | 删掉「把流水线挂到会话上」那一句 | **899/899 全绿** | 本文件 4 条红 |
/// | 丢掉「会话忙时记下待补挂」 | **899/899 全绿** | 本文件 2 条红 |
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

    /// | 外语 | 云端开 | 云端（Task 13 才实现） |
    ///
    /// 关键在于**不能退回本地**：那样用户以为走的是云端，实际跑的是本机模型。
    @Test("外语 + 云端开：不造本地翻译器，本轮注入中文原文")
    func foreignCloudDoesNotFallBackToLocal() async throws {
        let harness = Harness(target: .english, cloud: true)
        harness.coordinator.apply()
        try await harness.runSession()

        #expect(harness.sink.received == [Harness.transcript])
        #expect(harness.translatorDirectories.isEmpty, "选了云端却造出了本地翻译器")
        #expect(harness.warmUpCount == 0)
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

    /// 挂上去的目录必须来自判断结果，不是随手拿一个。
    ///
    /// 两个目录都配时翻译自己的优先（`TranslationAttachmentTests` 钉的是判断，
    /// 这里钉的是「判断出来的那个真的被送进了翻译器」）。
    @Test("翻译器拿到的是判断挑出来的那个目录")
    func translatorReceivesChosenDirectory() async throws {
        let translationDirectory = URL(fileURLWithPath: "/models/translate")
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
    static let correctionDirectory = URL(fileURLWithPath: "/models/correct")
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

    /// 构造完立刻赋值，不会是 nil；用隐式解包是因为闭包要捕获 self。
    var coordinator: TranslationAttachmentCoordinator!

    init(
        target: TranslationTarget,
        cloud: Bool = false,
        translationDirectory: URL? = nil,
        correctionDirectory: URL? = Harness.correctionDirectory
    ) {
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
            warmUp: { [unowned self] _ in self.warmUpCount += 1 },
            log: { [unowned self] message in self.logs.append(message) }
        )
    }

    func runSession() async throws {
        try await session.start()
        source.emit(Self.samples)
        await session.finish()
    }
}
