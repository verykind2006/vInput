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
        /// 听写进行中。
        case dictating(startedAt: Date)
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
            return begin(.dictating(startedAt: now), code: code, at: now)

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
            switch phase {
            case .dictating:
                phase = .idle
                consecutiveLimitHits = 0
                return [.endDictation(.controlFrame(value))]
            case .foreign:
                phase = .idle
                consecutiveLimitHits = 0
                return []
            case .idle, .muted:
                // 静默期或空闲期的结束码：没有会话可结束。
                // 静默期**不退出静默**——退订是我们主动做的，
                // 该由冷却计时决定何时恢复，不该由设备的一个字节决定。
                return []
            }
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
            return []

        case .dictating(let startedAt):
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

    /// 当前这次非听写会话有没有真的收到过音频包。
    ///
    /// 桥每收到一个音频包就调 `noteAudioPacket()`——**在 `acceptsAudio`
    /// 这道过滤之前**。不然非听写会话的音频被丢掉，会话永远不知道
    /// 「其实有流」，也就分不清按键与送流。
    private var foreignSawAudio = false

    /// 收到一个音频包。只做记账，不改状态。
    func noteAudioPacket() {
        if case .foreign = phase { foreignSawAudio = true }
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
