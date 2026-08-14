import Carbon.HIToolbox
import Testing

@testable import vInput

@MainActor
@Suite("遥控器杂键抑制")
struct RemoteKeySuppressorTests {
    /// 真机实测：RC003 语音键按住期间持续产生 keyCode 96(F5)，
    /// 淹没了随后注入的文字。键码写死在这里，改动需要有新的实测依据。
    @Test("抑制实测到的语音键键码 F5")
    func suppressesVoiceKeyCode() {
        let suppressor = RemoteKeySuppressor()
        suppressor.beginSuppressing()
        #expect(suppressor.shouldSuppress(keyCode: Int64(kVK_F5)))
    }

    @Test("不吞用户的普通按键")
    func passesThroughOrdinaryKeys() {
        let suppressor = RemoteKeySuppressor()
        suppressor.beginSuppressing()
        for key in [kVK_ANSI_A, kVK_Return, kVK_PageUp, kVK_Escape] {
            #expect(!suppressor.shouldSuppress(keyCode: Int64(key)))
        }
    }

    /// 抑制必须严格限定在语音会话期间。否则用户平时按 F5
    /// （系统听写）会被我们无声吞掉——那是抢用户的键盘。
    @Test("会话外一律放行，包括语音键键码")
    func passesThroughOutsideSession() {
        let suppressor = RemoteKeySuppressor()
        #expect(!suppressor.shouldSuppress(keyCode: Int64(kVK_F5)))

        suppressor.beginSuppressing()
        suppressor.endSuppressing()
        #expect(!suppressor.shouldSuppress(keyCode: Int64(kVK_F5)))
    }
}
