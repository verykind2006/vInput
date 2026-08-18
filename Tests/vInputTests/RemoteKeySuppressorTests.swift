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

    // MARK: - 鼠标那一档

    /// 鼠标语音键的键码没抓到（上一轮扫描的 HID 报文只按 report ID 汇总）。
    /// 「漏抑制」的后果是输入框被按键垃圾填满、注入的文字被淹没——M3 在
    /// RC003 上实测过；「多抑制」的后果只是说话那几秒键盘不响应。不对称。
    @Test("鼠标会话期间无条件抑制未知键码")
    func mouseSuppressesUnknownKeys() {
        let suppressor = RemoteKeySuppressor()
        suppressor.beginSuppressing(policy: RemoteKeySuppressor.mousePolicy)
        for key in [kVK_F5, kVK_ANSI_A, kVK_Return, kVK_PageUp, kVK_F13, kVK_Space] {
            #expect(suppressor.shouldSuppress(keyCode: Int64(key)))
        }
    }

    /// Esc 是录音期间唯一的取消键（CancelHotkeyController 只在 .listening
    /// 期间注册它）。连它一起吞掉等于把用户关在一次录音里。
    @Test("鼠标会话期间仍然放行 Esc")
    func mouseKeepsEscapeHatch() {
        let suppressor = RemoteKeySuppressor()
        suppressor.beginSuppressing(policy: RemoteKeySuppressor.mousePolicy)
        #expect(!suppressor.shouldSuppress(keyCode: Int64(kVK_Escape)))
    }

    @Test("鼠标会话结束后一律放行")
    func mousePassesThroughOutsideSession() {
        let suppressor = RemoteKeySuppressor()
        suppressor.beginSuppressing(policy: RemoteKeySuppressor.mousePolicy)
        suppressor.endSuppressing()
        for key in [kVK_ANSI_A, kVK_Return, kVK_F5] {
            #expect(!suppressor.shouldSuppress(keyCode: Int64(key)))
        }
    }

    /// 遥控器与鼠标共用一个抑制器实例（同一个 CGEvent tap）。
    /// 上一次会话的策略不能粘住——否则用鼠标录一次之后，遥控器那条路
    /// 会从此吞掉用户的所有按键。
    @Test("策略不会在会话之间粘住")
    func policyDoesNotLeakBetweenSessions() {
        let suppressor = RemoteKeySuppressor()

        suppressor.beginSuppressing(policy: RemoteKeySuppressor.mousePolicy)
        #expect(suppressor.shouldSuppress(keyCode: Int64(kVK_ANSI_A)))
        suppressor.endSuppressing()

        suppressor.beginSuppressing()   // 默认回到 RC003 那档
        #expect(!suppressor.shouldSuppress(keyCode: Int64(kVK_ANSI_A)))
        #expect(suppressor.shouldSuppress(keyCode: Int64(kVK_F5)))
    }
}
