import Foundation
import Testing
@testable import vInput

@Suite("蓝牙设备名匹配")
struct RemoteNameMatcherTests {
    @Test("识别小米遥控器的各种名称")
    func matchesKnownNames() {
        #expect(XiaomiVoiceRemoteNameMatcher.matches("MI RC"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("Xiaomi Bluetooth Remote 2"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("Xiaomi Bluetooth Remote 2 Pro"))
    }

    @Test("不匹配无关设备")
    func rejectsOtherDevices() {
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("AirPods Pro"))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("Magic Keyboard"))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches(""))
    }
}

@Suite("ATVV 会话门控")
struct ATVVSessionGateTests {
    @Test("能力未确认时不允许开麦")
    func blocksBeforeCapabilities() {
        #expect(!ATVVSessionGate.canOpenMicrophone(
            phase: .stopped, generation: 0,
            capabilitiesConfirmed: false, sampleRate: 16_000
        ))
    }

    @Test("采样率不受支持时不允许开麦")
    func blocksUnsupportedSampleRate() {
        #expect(!ATVVSessionGate.canOpenMicrophone(
            phase: .stopped, generation: 0,
            capabilitiesConfirmed: true, sampleRate: 8_000
        ))
    }

    @Test("取消开麦后的短时间内忽略音频流")
    func suppressesStreamAfterCancelledOpen() {
        let now = Date()
        #expect(ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: now, now: now.addingTimeInterval(1)
        ))
        #expect(!ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: now, now: now.addingTimeInterval(3)
        ))
    }

    @Test("没有取消记录时不忽略")
    func noSuppressionWithoutCancellation() {
        #expect(!ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(cancelledAt: nil))
    }

    @Test("开麦成功但未进入流式时记录取消时刻")
    func recordsCancellation() {
        let now = Date()
        #expect(ATVVSessionGate.cancelledOpenDate(microphoneOpened: true, streaming: false, now: now) == now)
        #expect(ATVVSessionGate.cancelledOpenDate(microphoneOpened: true, streaming: true, now: now) == nil)
        #expect(ATVVSessionGate.cancelledOpenDate(microphoneOpened: false, streaming: false, now: now) == nil)
    }
}

@Suite("语音会话续期门禁")
struct MicrophoneExtendGateTests {
    /// 这是 RC003 的真实用法：用户按遥控器上的实体语音键，会话由设备
    /// 主动发起，主机从未调用 requestMicrophoneOpen，microphoneOpened
    /// 始终为 false。旧实现把它列入 guard，导致保活从未发出过一个字节。
    @Test("设备主动发起的会话也能续期")
    func extendsDeviceInitiatedSession() {
        #expect(ATVVSessionGate.canExtendMicrophone(streaming: true))
    }

    @Test("没有进行中的会话时不续期")
    func skipsWhenNotStreaming() {
        #expect(!ATVVSessionGate.canExtendMicrophone(streaming: false))
    }
}
