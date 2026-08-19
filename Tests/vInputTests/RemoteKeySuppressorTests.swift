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

    // MARK: - 跟着会话状态自己收（Esc 取消那条缺口）

    /// **这一条来自一个真 bug。** `AppModel` 的 `cancelHotkey.onCancel`
    /// 原来只调 `session.cancel()`，不收抑制：鼠标那档是
    /// `.allExcept([Esc])`，于是按 Esc 取消之后**整个键盘只剩 Esc 能用**，
    /// 直到用户松开鼠标语音键（`0x22` 走 `onFinishSession` 才自愈）。
    /// RC003 那档是 `.only([F5])`，同样的不对称从来看不出来——
    /// 第三个源把旧的缺口暴露了出来。独立验收 2026-08-18 指出。
    ///
    /// 修法不是「在 onCancel 里补一次调用」就完了：**出口不止一个**
    /// （松开键、撞时长上限、转写失败、取消），每多一个出口就多一次
    /// 忘记的机会。所以把它挂到会话状态上——状态一离开 `.listening`
    /// 就收，与 `CancelHotkeyController.update(for:)` 同一个形状。
    @Test("会话离开 listening 就收掉抑制")
    func endsSuppressionWhenSessionLeavesListening() {
        // 遍历「除 .listening 之外的全部状态」，列表向 `DictationSession` 要而
        // 不是手抄一份：原来这里抄了四格，M8 加 `.translating` 时没有任何东西
        // 会提醒人回来补第五格——而漏掉的那一格恰恰就是没被覆盖的那一格。
        for state in DictationSession.State.allCasesInPipelineOrder.filter({ $0 != .listening }) {
            let suppressor = RemoteKeySuppressor()
            suppressor.beginSuppressing(policy: RemoteKeySuppressor.mousePolicy)
            suppressor.update(for: state)
            #expect(
                !suppressor.shouldSuppress(keyCode: Int64(kVK_ANSI_A)),
                "离开 listening 进入 \(state) 之后键盘必须恢复"
            )
        }
    }

    @Test("listening 期间不收")
    func keepsSuppressingWhileListening() {
        let suppressor = RemoteKeySuppressor()
        suppressor.beginSuppressing(policy: RemoteKeySuppressor.mousePolicy)
        suppressor.update(for: .listening)
        #expect(suppressor.shouldSuppress(keyCode: Int64(kVK_ANSI_A)))
    }

    /// `update(for:)` 不该反过来**开**抑制。⌥D 那条路从不调
    /// `beginSuppressing`（内置麦克风不产生杂键），而它同样会经过
    /// `.listening`——若在这里顺手打开，用户用 ⌥D 说话时键盘会莫名其妙
    /// 失灵。只收不开。
    @Test("update 只收不开")
    func updateNeverStartsSuppression() {
        let suppressor = RemoteKeySuppressor()
        suppressor.update(for: .listening)
        #expect(!suppressor.shouldSuppress(keyCode: Int64(kVK_F5)))
    }
}
