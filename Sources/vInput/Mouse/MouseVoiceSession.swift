import Foundation

/// 鼠标语音会话的状态机——**这一层就是 `0x31` 的保护本体**。
///
/// # 为什么必须有它
///
/// 2026-08-18 实测：`0x31`（长按开麦）触发后鼠标**持续送流 11 分钟**，
/// 把用户不知情的房间环境音送了过来。用户是靠菜单栏麦克风图标才发现的。
/// `0x31` 没有配对的结束码，所以「等设备说停」这条路根本不存在——
/// 停不停只能由我们自己决定。
///
/// # 两档上限，为什么不是一档
///
/// 两类会话的代价完全不对称：
///
/// - **听写会话**（`0x21` 开始、`0x22` 结束）是用户按着键在说话。撞上限
///   意味着截断一段有意的录音，代价是「少了后半句」，而且用户知道自己在录。
/// - **无配对结束码的会话**（`0x31`，以及任何我们不认识的奇数开始码）
///   没有人在等它结束。它多开一秒，就是多收一秒没人想录的音频。
///
/// 所以听写给 90 秒、其余给 30 秒。具体数字的依据：
///
/// - RC003 固件 60 秒主动切断（`Testing/M3-Acceptance.md`），**手按着说话
///   不会超过一分钟**是有实测支撑的；90 秒在此之上留了 50% 余量。
/// - `scripts/mouse-decode.sh` 的离线路径已经用 90 秒（提交 `b7ca232`）。
///   同一支设备用同一个数，日志与脚本对得上，不必回头问「这次是哪档拦的」。
/// - `VoiceSessionKeepalive.maxDuration` 是 180 秒，那是 RC003 的值，
///   **不能照搬**：那边固件自己 60 秒就断，应用侧的 180 秒是第二道兜底；
///   这边 `0x31` 没有任何硬件兜底，我们这一道就是唯一的一道，必须更紧。
/// - 30 秒对 `0x31`：任何「长按说一句话」都用不了 30 秒。把最坏情况从
///   11 分钟压到 30 秒，是 22 倍。
///
/// 用户的原话是判据：**宁可截断一次有意的长录音，也不要默默收一段没人
/// 想录的音频。**
///
/// # 撞上限之后做什么
///
/// 停止喂样本（`acceptsAudio` 变 false）**并且**退订特征（`.stopReceiving`）。
/// 只做前者不够：设备还在发，射频与电量照烧，而且下一次订阅回来时那段
/// 陈旧的流会立刻灌进来。
///
/// **不发任何写入命令去关麦。** `…CB8` 确实可写，但没有一个已知的停止
/// 命令字节——为了试它去猜命令，猜错可能让设备进入未知状态，而收益只是
/// 省掉一次退订。本地侧的停止已经足够达成目的。
///
/// # 反复撞上限时退避
///
/// 退订之后要恢复订阅，否则语音键从此失灵。但若设备仍在那条陈旧的流上，
/// 恢复订阅等于立刻再收一遍。所以冷却时间按连续撞线次数翻倍
/// （10 → 20 → 40 …，上限 300 秒），并且恢复之后**必须有一个新的开始码**
/// 才会再接收音频——`.idle` 下 `acceptsAudio` 是 false。

/// 会话结束的原因。写进日志，也决定上层要不要出文本。
enum MouseSessionEndReason: Equatable {
    /// 收到配对的结束码。
    case controlFrame(UInt8)
    /// 撞到时长上限。
    case durationLimit(TimeInterval)
    /// 连接断了。
    case disconnected
    /// 旧会话还没结束就来了新的开始码。
    case superseded(UInt8)
}

/// 状态机对外要求的动作。**不含日志**——日志由外壳按动作打，
/// 这样测试比对的是行为而不是字符串。
enum MouseSessionAction: Equatable {
    /// 开始一次听写。
    case beginDictation
    /// 结束当前听写。
    case endDictation(MouseSessionEndReason)
    /// 主动停止收流（退订特征），`cooldown` 秒后恢复。
    case stopReceiving(cooldown: TimeInterval)
    /// 冷却结束，恢复订阅。
    case resumeReceiving
    /// 按一次回车。
    case pressEnter
    /// 一个非听写会话在宽限期内一个音频包都没收到，已静默收掉。
    /// **不退订、不冷却**——它是一次按键，不是送流。
    case closedSilentForeign(code: UInt8)
    /// 收到一个偶数码，但它不是本次会话的配对码，已忽略。
    ///
    /// **有这个动作是为了让日志不说谎。** 桥对每个控制码都打一行
    /// 「控制码 0x2A（结束码…）」，若这里悄无声息，读日志的人会以为
    /// 会话被它结束了。同时它也是发现新按键的线索：出现一次，
    /// 就说明鼠标上有个键我们还不认识。
    case ignoredStop(code: UInt8, expected: UInt8)
    /// 一段无主音频自己停了（空档超过 `orphanStreamGap`），计时已清零，
    /// **没有退订**。`duration` 是这段流从首包到末包的时长。
    ///
    /// 有这个动作同样是为了日志不说谎：这条路径修的就是一次静默误伤
    /// （见 `orphanAudioLastPacketAt` 的注释），修完不能又静默。
    case closedOrphanBurst(duration: TimeInterval)
}

/// 会话时长上限与冷却时间。集中在一处，理由见文件头。
enum MouseSessionLimits {
    /// 听写会话（`0x21` → `0x22`）的上限。
    static let dictation: TimeInterval = 90
    /// 没有配对结束码的会话（`0x31` 与未知奇数开始码）的上限。
    static let unpaired: TimeInterval = 30
    /// 撞线退订后的初始冷却。
    static let initialCooldown: TimeInterval = 10
    /// 连续撞线时冷却翻倍的上限。5 分钟已经足够长到「人会去查」，
    /// 再长就等于把功能默默关掉了。
    static let maxCooldown: TimeInterval = 300
}

/// 会话状态机。纯逻辑，时间从外面传进来，测试不必等真实时间。
final class MouseVoiceSession {
    enum Phase: Equatable {
        case idle
        /// 听写进行中。`startCode` 是开这次会话的那个码（实测只可能是
        /// `0x21`），用来判结束码配不配对——见 `currentStartCode`。
        case dictating(startCode: UInt8, startedAt: Date)
        /// 非听写的开麦会话（`0x31` / `0x23` / `0x27` / 未知奇数码）。
        ///
        /// **这类会话不启动听写。** 理由：`0x23`/`0x27` 是鼠标上别的 AI
        /// 功能键，实测只开麦零点几秒，转写它只会产出垃圾；`0x31` 是事故
        /// 源头，更不该把一段没人想录的音频转写出来注入到前台应用里。
        /// 它们仍然进状态机，是因为**要给它们计时并在撞线时退订**。
        case foreign(code: UInt8, startedAt: Date)
        /// 已主动退订，等冷却结束。
        case muted(until: Date)
    }

    private(set) var phase: Phase = .idle
    /// 连续撞线次数。恢复订阅后正常走完一次会话就清零。
    private(set) var consecutiveLimitHits = 0

    /// 当前是否该把音频包喂给音频源。**只有听写会话为真。**
    var acceptsAudio: Bool {
        if case .dictating = phase { return true }
        return false
    }

    var isDictating: Bool { acceptsAudio }

    /// 收到一个控制帧。
    func handleControl(code: UInt8, at now: Date) -> [MouseSessionAction] {
        switch MouseVoiceProtocol.classify(code: code) {
        case .wake:
            // 只是准备信号，不动状态。证据见 MouseVoiceProtocol.classify。
            return []

        case .voiceStart:
            return begin(.dictating(startCode: code, startedAt: now), code: code, at: now)

        case .unpairedStart:
            return begin(.foreign(code: code, startedAt: now), code: code, at: now)

        case .ignored:
            // 不动状态机、不起计时器、不产出任何动作。
            return []

        case .enterKey:
            // **不动状态机。** 它不是会话，是一次即时按键。
            // 正在听写时也照发——用户按它就是想换行/确认，
            // 而听写与回车互不冲突。
            return [.pressEnter]

        case .otherStart(let value):
            return begin(.foreign(code: value, startedAt: now), code: code, at: now)

        case .stop(let value):
            // **只认本次会话的配对码。**
            //
            // 原来这里是「任意偶数码结束任何进行中的会话」，从没论证过，
            // 而且已经误伤两次：`0x28`（回车松开）会把正在进行的听写截断，
            // `0x24`（第三个键松开）同样，两次都是**事后手工加忽略名单**
            // 才堵上的。那条路上每发现一个新按键就要回来补一次，
            // 而在补上之前，误碰它就会打断用户正在说的话。
            //
            // 改成配对之后，陌生的偶数码**默认无害**。代价是「配对规律
            // 若不成立，会话不会被结束码收掉」——这个代价有界且已有对策：
            // 时长上限会收尾（听写那档还会照常出文本），而
            // 「结束码永远不来」本来就是这台设备上必须处理的一档
            // （`0x31` 根本没有结束码）。
            //
            // 更关键的一条：**鼠标只在按住时送流**（硬件行为，见 Roadmap
            // 的 toggle 一节）。所以漏认一个结束码不会多录到一秒音频，
            // 只会晚一点出文本——不在「一切不出本机」那条线的错误方向上。
            guard let startCode = currentStartCode else {
                // 空闲或静默期：没有会话可结束，也没什么可报的。
                // 静默期**不退出静默**——退订是我们主动做的，该由冷却计时
                // 决定何时恢复，不该由设备的一个字节决定。
                return []
            }
            let expected = MouseVoiceProtocol.pairedStop(forStart: startCode)
            guard value == expected else {
                return [.ignoredStop(code: value, expected: expected)]
            }
            let wasDictating = isDictating
            phase = .idle
            consecutiveLimitHits = 0
            return wasDictating ? [.endDictation(.controlFrame(value))] : []
        }
    }

    /// 开出当前这次会话的那个码。没有会话时是 nil。
    ///
    /// 放在 phase 里而不是单独一个变量：单独一个变量要在每一处
    /// `phase = .idle` 旁边记得清掉，迟早漏一处，而漏掉的表现是
    /// 「上一次会话的配对码还认得」这种极难复现的错。
    private var currentStartCode: UInt8? {
        switch phase {
        case .dictating(let code, _): return code
        case .foreign(let code, _): return code
        case .idle, .muted: return nil
        }
    }

    /// 非听写会话「没有音频」的宽限期。
    ///
    /// **区分的不是「多久」，是「到底有没有音频在流」。** 退订 + 冷却那套
    /// 保护是为 `0x31`（真的在持续送音频）设计的；而 `0x43` 这类按键只发
    /// 一个开始码、不送音频、也永远不发结束码（2026-08-18 实测 3/3 次）。
    /// 拿同一套对付它，结果是按一下鼠标上某个键，30 秒后特征被退订、
    /// 鼠标停摆 10 秒——**误伤，而且用户完全不知道为什么**。
    ///
    /// 所以：宽限期内一个音频包都没来，就静默收掉会话，不退订、不冷却。
    /// 3 秒足够——实测其他按键的会话在 0.09–0.35 秒内就开始送音频了。
    static let silentForeignGrace: TimeInterval = 3

    /// 每秒调用一次。撞线与冷却结束都在这里判。
    func tick(at now: Date) -> [MouseSessionAction] {
        switch phase {
        case .idle:
            // 没有会话却持续来音频包：设备在自说自话。这是 B1 的兜底，
            // 也覆盖「退订恢复后设备还在发陈旧流」那一档。
            guard let since = orphanAudioStartedAt, let last = orphanAudioLastPacketAt
            else { return [] }
            // **流停了就撤销计时，不退订。** 判据是空档，不是总时长——
            // 「还在不在流」与「流了多久」是两个独立的问题，
            // 原实现只看后者，误伤见 `orphanAudioLastPacketAt`。
            if now.timeIntervalSince(last) > Self.orphanStreamGap {
                orphanAudioStartedAt = nil
                orphanAudioLastPacketAt = nil
                return [.closedOrphanBurst(duration: last.timeIntervalSince(since))]
            }
            guard now.timeIntervalSince(since) >= MouseSessionLimits.unpaired else { return [] }
            orphanAudioStartedAt = nil
            orphanAudioLastPacketAt = nil
            let cooldown = enterMuted(at: now)
            return [.stopReceiving(cooldown: cooldown)]

        case .dictating(_, let startedAt):
            let elapsed = now.timeIntervalSince(startedAt)
            guard elapsed >= MouseSessionLimits.dictation else { return [] }
            let cooldown = enterMuted(at: now)
            // 先收尾听写再退订：用户明明按了语音键，撞线也该把已经说过的
            // 那 90 秒交出来，而不是连同截断一起丢掉。
            return [.endDictation(.durationLimit(elapsed)), .stopReceiving(cooldown: cooldown)]

        case .foreign(let code, let startedAt):
            let elapsed = now.timeIntervalSince(startedAt)
            // 一个音频包都没来过：这不是送流，是一次按键。静默收掉，
            // 不退订、不冷却——理由见 silentForeignGrace。
            if !foreignSawAudio, elapsed >= Self.silentForeignGrace {
                phase = .idle
                return [.closedSilentForeign(code: code)]
            }
            guard elapsed >= MouseSessionLimits.unpaired else { return [] }
            let cooldown = enterMuted(at: now)
            return [.stopReceiving(cooldown: cooldown)]

        case .muted(let until):
            guard now >= until else { return [] }
            phase = .idle
            return [.resumeReceiving]
        }
    }

    /// 没有任何会话时，音频包**仍然在来**的起始时刻。
    ///
    /// **B1 的补丁。** 原先静默收掉非听写会话后 `phase` 打回 `.idle`，
    /// 而 `noteAudioPacket()` 只在 `.foreign` 下记账——于是设备晚于宽限期
    /// 才开始送流时，记账永远不再发生、`tick` 在 `.idle` 恒返回空，
    /// **再没有任何东西会退订那个特征**。独立验收用出货代码实测：
    /// 送流起始 4 秒后，600 秒仍未退订，全程零日志、菜单栏仍显示已连接
    /// ——正好回到 2026-08-18 那次 11 分钟事故的状态。
    ///
    /// 根因是标定样本选错了维度：`silentForeignGrace = 3 秒` 来自
    /// `0x23`/`0x27`（首包延迟 0.04 秒），而它要保护的 `0x31` **在抓包里
    /// 一个控制帧都没有**，首包延迟从未被观测过。
    ///
    /// 所以这道防线不能依赖「会话」这个概念：**只要音频还在来，就该有人
    /// 计时**。它同时堵住「陈旧流」那一档——退订恢复后设备若还在发，
    /// 这里照样兜得住。
    private var orphanAudioStartedAt: Date?

    /// 无主音频**最后一包**的时刻。与起始时刻配对，缺一不可。
    ///
    /// **只记起始不记末包，是 2026-08-20 真机抓到的一次静默误伤的根因**：
    /// 长按鼠标回车键 3.4 秒，期间鼠标开麦送流（M7 就实测过按键会短暂
    /// 开麦），这些包在 `.idle` 下走 B1 记账；音频停了计时却不清零，
    /// 30 秒后照样按「持续送流」退订 + 冷却 10 秒——之后按语音键没反应。
    /// **这正是用户报过的「无法使用鼠标收音」的形态**（冷却翻倍最长
    /// 300 秒，误伤窗口足够长到被撞上）。
    ///
    /// B1 防的是「持续在流」（0x31 事故是 11 分钟不停）；一段停了的
    /// 短音频不构成那个威胁，判据必须能把两者分开。
    private var orphanAudioLastPacketAt: Date?

    /// 无主音频的「流停」判据：超过这个空档没有新包就算这段流结束。
    /// 音频包实测 31.25 包/秒，正常送流的包间隔是 32 毫秒——2 秒的空档
    /// 比它宽 60 倍，不会把一次丢包误判成停止；与 BLE 扫描器的分段判据
    /// 用同一个数（提交 `97af648`），同一支设备两处对得上。
    static let orphanStreamGap: TimeInterval = 2

    /// 当前这次非听写会话有没有真的收到过音频包。
    ///
    /// 桥每收到一个音频包就调 `noteAudioPacket()`——**在 `acceptsAudio`
    /// 这道过滤之前**。不然非听写会话的音频被丢掉，会话永远不知道
    /// 「其实有流」，也就分不清按键与送流。
    private var foreignSawAudio = false

    /// 收到一个音频包。只做记账，不改状态。
    ///
    /// **必须在 `acceptsAudio` 那道过滤之前调**，否则非听写会话的音频被
    /// 丢掉，会话永远不知道「其实有流」。
    func noteAudioPacket(at now: Date = Date()) {
        switch phase {
        case .foreign:
            foreignSawAudio = true
            orphanAudioStartedAt = nil
            orphanAudioLastPacketAt = nil
        case .idle:
            // 没有会话却在收音频——B1 那条路径。开始计时，并记录末包时刻
            // （tick 靠它判「流还在不在」）。
            if orphanAudioStartedAt == nil { orphanAudioStartedAt = now }
            orphanAudioLastPacketAt = now
        case .dictating, .muted:
            orphanAudioStartedAt = nil
            orphanAudioLastPacketAt = nil
        }
    }

    /// 连接断开。会话一律作废。
    func handleDisconnected() -> [MouseSessionAction] {
        let wasDictating = isDictating
        phase = .idle
        consecutiveLimitHits = 0
        return wasDictating ? [.endDictation(.disconnected)] : []
    }

    /// 主动停止（应用退出、功能关闭）。不产生动作，只清状态。
    func reset() {
        phase = .idle
        consecutiveLimitHits = 0
    }

    // MARK: - 私有

    /// 开始任一会话时清掉上一次的音频记账。
    private func resetAudioAccounting() { foreignSawAudio = false }

    private func begin(_ next: Phase, code: UInt8, at now: Date) -> [MouseSessionAction] {
        // 静默期内不开新会话：此刻已经退订，开了也收不到音频，
        // 只会让状态与射频事实不一致。
        if case .muted = phase { return [] }

        var actions: [MouseSessionAction] = []
        if isDictating {
            // 旧会话没等到结束码就来了新的开始码。把旧的收掉再开新的，
            // 否则旧会话的计时点会被新会话顶掉，上限从此永远撞不到。
            actions.append(.endDictation(.superseded(code)))
        }

        // **B2 的补丁：非听写会话之间重发开始码，不刷新计时点。**
        //
        // 上面那段注释写对了风险，却只对 `.dictating` 做了处理。独立验收
        // 用出货代码实测：`0x31` 全程送流 + 每 29 秒重发一次，600 秒仍未
        // 退订——因为每次 `begin` 都把 `startedAt` 推到当下，30 秒的上限
        // 永远撞不到。`0x31` 会不会重发？**它的触发动作至今未知**，
        // 这一维不能靠「应该不会」过关。
        if case .foreign(_, let existingStart) = phase, case .foreign(let newCode, _) = next {
            phase = .foreign(code: newCode, startedAt: existingStart)
            if case .dictating = next { actions.append(.beginDictation) }
            return actions
        }

        phase = next
        resetAudioAccounting()
        if case .dictating = next { actions.append(.beginDictation) }
        return actions
    }

    /// 进入静默，返回本次冷却时长。
    private func enterMuted(at now: Date) -> TimeInterval {
        consecutiveLimitHits += 1
        let cooldown = Self.cooldown(forConsecutiveHits: consecutiveLimitHits)
        phase = .muted(until: now.addingTimeInterval(cooldown))
        return cooldown
    }

    /// 冷却时长按连续撞线次数翻倍。
    ///
    /// 抽成静态纯函数以便单测——退避这种东西写反了不会崩，只会在真机上
    /// 表现为「过一会儿又收上来了」，而那正是最难被发现的一档。
    static func cooldown(forConsecutiveHits hits: Int) -> TimeInterval {
        guard hits > 1 else { return MouseSessionLimits.initialCooldown }
        let scaled = MouseSessionLimits.initialCooldown * pow(2, Double(hits - 1))
        return min(scaled, MouseSessionLimits.maxCooldown)
    }
}
