import Foundation
import Testing
@testable import vInput

@Suite("HID 按下沿检测")
struct HIDPressDetectionTests {
    @Test("从未按下到按下算一次按下")
    func detectsPress() {
        #expect(RemoteHIDListener.didPress(
            usage: 0xF1, previous: [], current: [0xF1]
        ))
    }

    @Test("持续按住不重复触发")
    func doesNotRepeatWhileHeld() {
        #expect(!RemoteHIDListener.didPress(
            usage: 0xF1, previous: [0xF1], current: [0xF1]
        ))
    }

    @Test("松开不触发")
    func releaseDoesNotTrigger() {
        #expect(!RemoteHIDListener.didPress(
            usage: 0xF1, previous: [0xF1], current: []
        ))
    }

    @Test("其他键按下不触发")
    func otherKeysDoNotTrigger() {
        #expect(!RemoteHIDListener.didPress(
            usage: 0xF1, previous: [], current: [0x28]
        ))
    }

    @Test("与其他键同时按下仍触发")
    func triggersAlongsideOtherKeys() {
        #expect(RemoteHIDListener.didPress(
            usage: 0xF1, previous: [0x28], current: [0x28, 0xF1]
        ))
    }

    @Test("松开再按下会再次触发")
    func triggersAgainAfterRelease() {
        #expect(!RemoteHIDListener.didPress(usage: 0xF1, previous: [0xF1], current: []))
        #expect(RemoteHIDListener.didPress(usage: 0xF1, previous: [], current: [0xF1]))
    }
}

/// 关机键 → 退格（2026-08-20 真机侦察后接的）。
///
/// 侦察结论（三次短按 + 一次长按，逐次对日志）：短按系统零投递零副作用，
/// 所以只需「识别 + 注入」，不需要拦截；长按弹系统关机框，在监听之外，
/// 不拦也不必拦。usage 与判断各钉一条；接线闭包（AppModel 里那几行）
/// 测不了真设备，由真机验收覆盖。
@Suite("关机键映射退格")
struct PowerKeyTests {
    /// 0x66 写死钉住——它是三次真机按键逐一对出来的数，不是猜的。
    @Test("关机键的 usage 是 0x66")
    func powerUsageIsPinned() {
        #expect(HIDReportParser.powerButtonUsage == 0x66)
    }

    @Test("关机键按下沿被检测到")
    func powerPressDetected() {
        #expect(RemoteHIDListener.didPress(
            usage: HIDReportParser.powerButtonUsage, previous: [], current: [0x66]
        ))
    }

    /// 录音中忽略：说话时误碰关机键去删目标应用里的字，比什么都不做
    /// 更糟——与会话期间按键抑制同一条哲学。
    @Test("空闲时注退格，听写中忽略")
    func backspaceOnlyWhenIdle() {
        #expect(AppModel.powerKeyPostsBackspace(dictationIdle: true))
        #expect(!AppModel.powerKeyPostsBackspace(dictationIdle: false))
    }
}
