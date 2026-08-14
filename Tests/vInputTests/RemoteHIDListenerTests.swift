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
