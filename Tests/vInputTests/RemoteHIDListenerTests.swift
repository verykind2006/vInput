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

/// 「哪个 usage 触发哪个回调」。
///
/// **这一层原先零覆盖**：`didPress` 那套用例只测纯函数，把 `handleReport`
/// 里三个分派全删掉照样全绿。真 HID 设备进不了测试进程，所以直接喂报文。
@MainActor
@Suite("HID 报文到回调的分派")
struct HIDDispatchTests {
    /// 小端 UInt16 的一帧报文。
    static func report(_ usages: [UInt16]) -> Data {
        var bytes: [UInt8] = []
        for usage in usages {
            bytes.append(UInt8(usage & 0xFF))
            bytes.append(UInt8(usage >> 8))
        }
        return Data(bytes.isEmpty ? [0x00, 0x00] : bytes)
    }

    /// 喂一串报文，返回三个回调各触发了几次。
    /// **不调 `start()`**：那会去要「输入监控」授权并真的开 IOHID。
    static func fire(_ frames: [[UInt16]]) -> (cancel: Int, power: Int, grave: Int) {
        let listener = RemoteHIDListener()
        var cancel = 0, power = 0, grave = 0
        listener.onCancelPressed = { cancel += 1 }
        listener.onPowerPressed = { power += 1 }
        listener.onGravePressed = { grave += 1 }
        for frame in frames {
            listener.handleReport(reportID: 1, data: report(frame))
        }
        return (cancel, power, grave)
    }

    @Test("0x35 触发「·」键回调，且不误触另外两个")
    func graveDispatch() {
        let counts = Self.fire([[0x35], []])
        #expect(counts.grave == 1, "0x35 没有触发 onGravePressed")
        #expect(counts.cancel == 0 && counts.power == 0, "0x35 误触了别的回调")
    }

    @Test("0x66 触发关机键回调，0xF1 触发取消回调")
    func powerAndCancelDispatch() {
        let power = Self.fire([[0x66], []])
        #expect(power.power == 1 && power.grave == 0 && power.cancel == 0)
        let cancel = Self.fire([[0xF1], []])
        #expect(cancel.cancel == 1 && cancel.grave == 0 && cancel.power == 0)
    }

    /// 按住不放只算一次：靠的是 `didPress` 的按下沿判断真的接在了这里。
    @Test("按住不放只触发一次，松开再按才有第二次")
    func onlyOnPressEdge() {
        let counts = Self.fire([[0x35], [0x35], [0x35], [], [0x35]])
        #expect(counts.grave == 2, "按下沿判断没接上，按住期间重复触发了")
    }

    /// 语音键（0x3E）与方向键不该触发这三个回调里的任何一个。
    @Test("无关按键不触发任何映射回调")
    func unrelatedUsagesDoNotDispatch() {
        let counts = Self.fire([[0x3E, 0x4F, 0x28], []])
        #expect(counts.cancel == 0 && counts.power == 0 && counts.grave == 0)
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
