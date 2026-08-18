import Foundation
import Testing

@testable import vInput

@Suite("鼠标语音会话状态机")
struct MouseVoiceSessionTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    // MARK: - 正常的一次听写

    @Test("语音键开始码开启听写")
    func voiceStartBeginsDictation() {
        let session = MouseVoiceSession()
        #expect(session.handleControl(code: 0x21, at: t0) == [.beginDictation])
        #expect(session.acceptsAudio)
    }

    @Test("配对的结束码收尾听写")
    func pairedStopEndsDictation() {
        let session = MouseVoiceSession()
        _ = session.handleControl(code: 0x21, at: t0)
        #expect(session.handleControl(code: 0x22, at: at(5)) == [.endDictation(.controlFrame(0x22))])
        #expect(!session.acceptsAudio)
    }

    /// 0x51 之后 0.31 秒才是 0x21，中间没有音频包。把它当开始码
    /// 会让每次按键多开一个空会话。
    @Test("0x51 不开会话")
    func wakeDoesNothing() {
        let session = MouseVoiceSession()
        #expect(session.handleControl(code: 0x51, at: t0).isEmpty)
        #expect(!session.acceptsAudio)
        #expect(session.handleControl(code: 0x21, at: at(0.31)) == [.beginDictation])
    }

    @Test("空闲时的结束码不产生动作")
    func stopWhileIdleIsNoop() {
        let session = MouseVoiceSession()
        #expect(session.handleControl(code: 0x22, at: t0).isEmpty)
    }

    // MARK: - 非听写的开麦会话

    /// 0x23/0x27 是鼠标上别的 AI 功能键，实测只开麦零点几秒。
    /// 转写它只会产出垃圾，更不该注入到前台应用。
    @Test("其他功能键不启动听写")
    func otherKeysDoNotDictate() {
        let session = MouseVoiceSession()
        #expect(session.handleControl(code: 0x23, at: t0).isEmpty)
        #expect(!session.acceptsAudio)
        #expect(session.handleControl(code: 0x24, at: at(0.4)).isEmpty)
    }

    @Test("0x31 不启动听写")
    func unpairedStartDoesNotDictate() {
        let session = MouseVoiceSession()
        #expect(session.handleControl(code: 0x31, at: t0).isEmpty)
        #expect(!session.acceptsAudio)
    }

    @Test("未知的奇数开始码按非听写会话处理")
    func unknownOddCodeIsForeign() {
        let session = MouseVoiceSession()
        #expect(session.handleControl(code: 0x35, at: t0).isEmpty)
        #expect(!session.acceptsAudio)
        // 但它仍在计时——撞线要能退订
        #expect(session.tick(at: at(MouseSessionLimits.unpaired)).count == 1)
    }

    // MARK: - 只按了一下的按键，不该被当成送流

    /// 2026-08-18 实测：鼠标上还有一个键发 `0x43`，**只发开始码、不送音频、
    /// 也永远不发结束码**（3/3 次）。
    ///
    /// 按原来的处理它会挂起一个 30 秒会话，撞线后退订特征 + 冷却 10 秒
    /// ——**按一下鼠标上某个键，鼠标停摆 10 秒，而用户完全不知道为什么**。
    /// 那套保护是为 `0x31`（真的在持续送音频）设计的，用来对付一次按键
    /// 属于误伤。区分的不是「多久」，是「到底有没有音频在流」。
    @Test("只发开始码、不送音频的按键被静默收掉，不退订不冷却")
    func silentForeignSessionClosesWithoutMuting() {
        let session = MouseVoiceSession()
        _ = session.handleControl(code: 0x43, at: t0)

        // 宽限期内不动。
        #expect(session.tick(at: at(MouseVoiceSession.silentForeignGrace - 1)).isEmpty)
        // 宽限期到，静默收掉——**不是** stopReceiving。
        #expect(
            session.tick(at: at(MouseVoiceSession.silentForeignGrace))
                == [.closedSilentForeign(code: 0x43)]
        )
        // 关键：没进静默期，下一次按语音键照常能开始。
        #expect(
            session.handleControl(code: 0x21, at: at(MouseVoiceSession.silentForeignGrace + 1))
                == [.beginDictation]
        )
        #expect(session.isDictating)
    }

    /// 反面：来过音频就走原来那条路。两条一起看才说明「记账」真的起作用。
    @Test("送过音频的非听写会话仍然走退订 + 冷却")
    func streamingForeignSessionStillMutes() {
        let session = MouseVoiceSession()
        _ = session.handleControl(code: 0x43, at: t0)
        session.noteAudioPacket()

        #expect(session.tick(at: at(MouseVoiceSession.silentForeignGrace + 1)).isEmpty)
        #expect(
            session.tick(at: at(MouseSessionLimits.unpaired))
                == [.stopReceiving(cooldown: MouseSessionLimits.initialCooldown)]
        )
    }

    // MARK: - 0x31 的保护（本里程碑最重要的一条）

    /// 2026-08-18 真机事故：0x31 之后鼠标持续送流 11 分钟。
    /// 没有配对的结束码，停不停只能由我们决定。
    @Test("0x31 会话撞上限后主动退订")
    func unpairedSessionStopsAtLimit() {
        let session = MouseVoiceSession()
        _ = session.handleControl(code: 0x31, at: t0)
        // 真实的 0x31 **是在送流的**——那正是它危险的原因。不喂音频包的话
        // 会走「按键，静默收掉」那条路（见 silentForeignGrace），
        // 测的就不是这个事故了。
        session.noteAudioPacket()

        #expect(session.tick(at: at(MouseSessionLimits.unpaired - 1)).isEmpty)
        #expect(
            session.tick(at: at(MouseSessionLimits.unpaired))
                == [.stopReceiving(cooldown: MouseSessionLimits.initialCooldown)]
        )
        #expect(!session.acceptsAudio)
    }

    @Test("11 分钟的事故场景会在 30 秒被拦住")
    func elevenMinuteIncidentIsCapped() {
        let session = MouseVoiceSession()
        _ = session.handleControl(code: 0x31, at: t0)
        // 真实的 0x31 **是在送流的**——那正是它危险的原因。不喂音频包的话
        // 会走「按键，静默收掉」那条路（见 silentForeignGrace），
        // 测的就不是这个事故了。
        session.noteAudioPacket()

        var stoppedAt: TimeInterval?
        for second in stride(from: 1.0, through: 660, by: 1) {
            let actions = session.tick(at: at(second))
            if actions.contains(where: { if case .stopReceiving = $0 { return true } else { return false } }) {
                stoppedAt = second
                break
            }
        }

        #expect(stoppedAt == MouseSessionLimits.unpaired)
    }

    @Test("听写会话撞上限时先收尾再退订")
    func dictationLimitFinishesThenStops() {
        let session = MouseVoiceSession()
        _ = session.handleControl(code: 0x21, at: t0)

        #expect(session.tick(at: at(MouseSessionLimits.dictation - 1)).isEmpty)
        let actions = session.tick(at: at(MouseSessionLimits.dictation))
        #expect(actions.count == 2)
        // 顺序有意义：用户按了语音键，撞线也该把已经说过的那段交出来
        #expect(actions.first == .endDictation(.durationLimit(MouseSessionLimits.dictation)))
        #expect(actions.last == .stopReceiving(cooldown: MouseSessionLimits.initialCooldown))
        #expect(!session.acceptsAudio)
    }

    /// 听写给 90 秒、无结束码的给 30 秒：两类会话的代价不对称。
    @Test("两档上限的相对关系钉死")
    func limitsOrdering() {
        #expect(MouseSessionLimits.unpaired < MouseSessionLimits.dictation)
        // 上限只有比 RC003 固件的 60 秒切断更严才有意义——那边有硬件兜底，
        // 这边 0x31 一个兜底都没有。
        #expect(MouseSessionLimits.unpaired < 60)
        // 也不能松到 VoiceSessionKeepalive 的 180 秒
        #expect(MouseSessionLimits.dictation < VoiceSessionKeepalive.maxDuration)
    }

    // MARK: - 静默与恢复

    @Test("静默期不接收音频，冷却结束后恢复订阅")
    func mutedThenResumes() {
        let session = MouseVoiceSession()
        _ = session.handleControl(code: 0x31, at: t0)
        // 真实的 0x31 **是在送流的**——那正是它危险的原因。不喂音频包的话
        // 会走「按键，静默收掉」那条路（见 silentForeignGrace），
        // 测的就不是这个事故了。
        session.noteAudioPacket()
        _ = session.tick(at: at(MouseSessionLimits.unpaired))

        let stillMuted = MouseSessionLimits.unpaired + MouseSessionLimits.initialCooldown - 1
        #expect(session.tick(at: at(stillMuted)).isEmpty)

        let resumeAt = MouseSessionLimits.unpaired + MouseSessionLimits.initialCooldown
        #expect(session.tick(at: at(resumeAt)) == [.resumeReceiving])
        #expect(!session.acceptsAudio)
    }

    /// 恢复订阅本身不该重新开始收音——必须有一个**新的**开始码。
    /// 否则设备若还在那条陈旧的流上，恢复等于立刻再收一遍。
    @Test("恢复订阅后仍需新的开始码才接收音频")
    func resumeRequiresFreshStart() {
        let session = MouseVoiceSession()
        _ = session.handleControl(code: 0x21, at: t0)
        _ = session.tick(at: at(MouseSessionLimits.dictation))
        _ = session.tick(at: at(MouseSessionLimits.dictation + MouseSessionLimits.initialCooldown))

        #expect(!session.acceptsAudio)
        #expect(session.handleControl(code: 0x21, at: at(200)) == [.beginDictation])
        #expect(session.acceptsAudio)
    }

    @Test("静默期内的开始码被忽略")
    func startIgnoredWhileMuted() {
        let session = MouseVoiceSession()
        _ = session.handleControl(code: 0x31, at: t0)
        // 真实的 0x31 **是在送流的**——那正是它危险的原因。不喂音频包的话
        // 会走「按键，静默收掉」那条路（见 silentForeignGrace），
        // 测的就不是这个事故了。
        session.noteAudioPacket()
        _ = session.tick(at: at(MouseSessionLimits.unpaired))

        #expect(session.handleControl(code: 0x21, at: at(MouseSessionLimits.unpaired + 1)).isEmpty)
        #expect(!session.acceptsAudio)
    }

    /// 退订是我们主动做的，何时恢复该由冷却计时决定，
    /// 不该被设备的一个字节提前解除。
    @Test("静默期内的结束码不解除静默")
    func stopDoesNotClearMute() {
        let session = MouseVoiceSession()
        _ = session.handleControl(code: 0x31, at: t0)
        // 真实的 0x31 **是在送流的**——那正是它危险的原因。不喂音频包的话
        // 会走「按键，静默收掉」那条路（见 silentForeignGrace），
        // 测的就不是这个事故了。
        session.noteAudioPacket()
        _ = session.tick(at: at(MouseSessionLimits.unpaired))

        #expect(session.handleControl(code: 0x22, at: at(MouseSessionLimits.unpaired + 1)).isEmpty)
        let stillMuted = MouseSessionLimits.unpaired + MouseSessionLimits.initialCooldown - 1
        #expect(session.tick(at: at(stillMuted)).isEmpty)
    }

    // MARK: - 退避

    @Test("连续撞线时冷却翻倍并封顶")
    func cooldownBacksOff() {
        #expect(MouseVoiceSession.cooldown(forConsecutiveHits: 1) == 10)
        #expect(MouseVoiceSession.cooldown(forConsecutiveHits: 2) == 20)
        #expect(MouseVoiceSession.cooldown(forConsecutiveHits: 3) == 40)
        #expect(MouseVoiceSession.cooldown(forConsecutiveHits: 99) == MouseSessionLimits.maxCooldown)
    }

    @Test("设备不停发流时冷却逐次拉长")
    func repeatedOffenceLengthensCooldown() {
        let session = MouseVoiceSession()
        var now: TimeInterval = 0

        _ = session.handleControl(code: 0x31, at: at(now))
        session.noteAudioPacket()
        now += MouseSessionLimits.unpaired
        #expect(session.tick(at: at(now)) == [.stopReceiving(cooldown: 10)])

        now += 10
        #expect(session.tick(at: at(now)) == [.resumeReceiving])

        _ = session.handleControl(code: 0x31, at: at(now))
        session.noteAudioPacket()
        now += MouseSessionLimits.unpaired
        #expect(session.tick(at: at(now)) == [.stopReceiving(cooldown: 20)])
    }

    @Test("正常走完一次会话后退避计数清零")
    func normalSessionResetsBackoff() {
        let session = MouseVoiceSession()
        _ = session.handleControl(code: 0x31, at: t0)
        // 真实的 0x31 **是在送流的**——那正是它危险的原因。不喂音频包的话
        // 会走「按键，静默收掉」那条路（见 silentForeignGrace），
        // 测的就不是这个事故了。
        session.noteAudioPacket()
        _ = session.tick(at: at(MouseSessionLimits.unpaired))
        _ = session.tick(at: at(MouseSessionLimits.unpaired + 10))
        #expect(session.consecutiveLimitHits == 1)

        _ = session.handleControl(code: 0x21, at: at(100))
        _ = session.handleControl(code: 0x22, at: at(103))
        #expect(session.consecutiveLimitHits == 0)
    }

    // MARK: - 边界

    /// 旧会话没等到结束码就来了新的开始码。不收掉旧的，
    /// 计时起点会被顶掉，上限从此永远撞不到。
    @Test("新的开始码顶掉未结束的旧会话")
    func newStartSupersedesOldSession() {
        let session = MouseVoiceSession()
        _ = session.handleControl(code: 0x21, at: t0)

        let actions = session.handleControl(code: 0x21, at: at(5))
        #expect(actions == [.endDictation(.superseded(0x21)), .beginDictation])

        // 计时从新会话算起：旧起点 +90 秒还不该撞线
        #expect(session.tick(at: at(MouseSessionLimits.dictation)).isEmpty)
        #expect(session.tick(at: at(5 + MouseSessionLimits.dictation)).count == 2)
    }

    @Test("0x31 顶掉进行中的听写")
    func unpairedStartSupersedesDictation() {
        let session = MouseVoiceSession()
        _ = session.handleControl(code: 0x21, at: t0)
        #expect(session.handleControl(code: 0x31, at: at(2)) == [.endDictation(.superseded(0x31))])
        #expect(!session.acceptsAudio)
    }

    @Test("断连时结束进行中的听写")
    func disconnectEndsDictation() {
        let session = MouseVoiceSession()
        _ = session.handleControl(code: 0x21, at: t0)
        #expect(session.handleDisconnected() == [.endDictation(.disconnected)])
        #expect(!session.acceptsAudio)
    }

    @Test("空闲时断连不产生动作")
    func disconnectWhileIdleIsNoop() {
        let session = MouseVoiceSession()
        #expect(session.handleDisconnected().isEmpty)
    }

    @Test("空闲时 tick 不产生动作")
    func idleTickIsNoop() {
        let session = MouseVoiceSession()
        #expect(session.tick(at: at(10_000)).isEmpty)
    }
}
