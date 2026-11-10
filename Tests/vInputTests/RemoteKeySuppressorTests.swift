import Carbon.HIToolbox
import Testing

@testable import vInput

@MainActor
@Suite("遥控器杂键抑制")
struct RemoteKeySuppressorTests {
    /// 可观测的假 tap。**存在的理由是让「拆得干净」这件事测得出来。**
    ///
    /// 最初这批用例传的是「什么都不装」，于是 `tapHandle` 永远是 nil，
    /// `stop()` 与 `deinit` 的行为**根本观测不到**——实测确认过：把
    /// `stop()` 改成只 `setEnabled(false)` 不 invalidate、把 `deinit` 整个
    /// 删掉，12 条用例照样全绿。**那是两条空断言，而它们守的正是本轮修的
    /// 那个 bug 本身。**
    @MainActor
    final class FakeTap: EventTapping {
        private(set) var invalidateCount = 0
        private(set) var enabledHistory: [Bool] = []
        var isInvalidated: Bool { invalidateCount > 0 }

        nonisolated func invalidate() {
            MainActor.assumeIsolated { invalidateCount += 1 }
        }
        nonisolated func setEnabled(_ enabled: Bool) {
            MainActor.assumeIsolated { enabledHistory.append(enabled) }
        }
    }

    /// **一律不装真的系统级 CGEvent tap。**
    ///
    /// 2026-08-19 查出来的一个真 bug：本文件每条用例都 `beginSuppressing()`，
    /// 而它会调 `start()` 装一个**系统级**的 tap；没有一条用例调 `stop()`，
    /// 当时类里也没有 `deinit`。于是每跑一次测试，系统里就留下若干个 tap，
    /// 各自的 `userInfo` 指着已释放的内存——**下一次用户敲键盘，
    /// 测试进程就 SIGSEGV**。崩溃报告四份：08-18 17:01、08-18 23:00、
    /// 08-19 11:06、08-19 11:07，栈是
    /// `__CFMachPortPerform → eventTapMessageHandler → closure #1 in start()
    /// → swift_retain`。
    ///
    /// 它间歇发生，是因为 tap 建不建得起来取决于测试二进制有没有辅助功能
    /// 授权，而临时签名每次构建都变、TCC 授权随之重置。**「一直没出事」
    /// 只是因为大部分时候授权不在，那是运气不是设计。**
    private func makeSuppressor(tap: FakeTap? = nil) -> RemoteKeySuppressor {
        // 看门狗也用手动环境：`.system` 会装真计时器、读真实的系统按键，
        // 跑测试时用户一打字，假 tap 没见到按键就会被「判卡死」拆掉。
        RemoteKeySuppressor(
            installer: { _ in tap },
            stallEnvironment: .manual(now: { 0 }, systemLastKeyDown: { 0 }))
    }

    /// 上面那条保护本身的守卫。
    ///
    /// 没有它的话，谁把 `makeSuppressor` 改回默认构造都不会有人发现，
    /// 而失效的表现是「跑完测试之后某次按键让测试进程崩掉」——
    /// 没人会联想到这里。
    @Test("测试用的抑制器不装系统级 tap")
    func testSuppressorInstallsNoSystemTap() {
        let suppressor = makeSuppressor()
        suppressor.beginSuppressing()
        #expect(!suppressor.hasTap, "测试进程装了真的 CGEvent tap")
        suppressor.start()
        #expect(!suppressor.hasTap, "显式 start() 也不该装")
    }

    /// **`stop()` 必须真的把 tap 拆掉，不是只禁用。**
    ///
    /// 只 `tapEnable(false)` 的话 mach port 还活着，系统仍可能投递事件，
    /// 而那时 `userInfo` 已经是野指针。这条钉的就是 `CFMachPortInvalidate`
    /// 那一步。
    @Test("stop 真的拆掉 tap，且可重复调用")
    func stopInvalidatesTheTap() {
        let tap = FakeTap()
        let suppressor = makeSuppressor(tap: tap)
        suppressor.beginSuppressing()
        #expect(suppressor.hasTap)

        suppressor.stop()
        #expect(tap.isInvalidated, "stop 只禁用了 tap，没有拆掉它")
        #expect(!suppressor.hasTap)
        #expect(!suppressor.shouldSuppress(keyCode: Int64(kVK_F5)), "拆完还在吞键")

        suppressor.stop()
        #expect(tap.invalidateCount == 1, "重复 stop 不该重复拆")
    }

    /// **tap 绝不能活得比宿主久。**
    ///
    /// 这是那四份崩溃报告的直接成因：对象释放了，tap 还挂在系统里指着
    /// 已释放的内存。删掉 `deinit` 时本条会红。
    @Test("宿主释放时 tap 跟着被拆掉")
    func deinitInvalidatesTheTap() {
        let tap = FakeTap()
        do {
            let suppressor = makeSuppressor(tap: tap)
            suppressor.beginSuppressing()
            #expect(suppressor.hasTap)
        }
        #expect(tap.isInvalidated, "宿主没了，tap 还挂在系统里——这正是那四次 SIGSEGV")
    }

    /// 真机实测：RC003 语音键按住期间持续产生 keyCode 96(F5)，
    /// 淹没了随后注入的文字。键码写死在这里，改动需要有新的实测依据。
    @Test("抑制实测到的语音键键码 F5")
    func suppressesVoiceKeyCode() {
        let suppressor = makeSuppressor()
        suppressor.beginSuppressing()
        #expect(suppressor.shouldSuppress(keyCode: Int64(kVK_F5)))
    }

    @Test("不吞用户的普通按键")
    func passesThroughOrdinaryKeys() {
        let suppressor = makeSuppressor()
        suppressor.beginSuppressing()
        for key in [kVK_ANSI_A, kVK_Return, kVK_PageUp, kVK_Escape] {
            #expect(!suppressor.shouldSuppress(keyCode: Int64(key)))
        }
    }

    /// 抑制必须严格限定在语音会话期间。否则用户平时按 F5
    /// （系统听写）会被我们无声吞掉——那是抢用户的键盘。
    @Test("会话外一律放行，包括语音键键码")
    func passesThroughOutsideSession() {
        let suppressor = makeSuppressor()
        #expect(!suppressor.shouldSuppress(keyCode: Int64(kVK_F5)))

        suppressor.beginSuppressing()
        suppressor.endSuppressing()
        #expect(!suppressor.shouldSuppress(keyCode: Int64(kVK_F5)))
    }

    // MARK: - 鼠标那一档

    /// 2026-08-20 收窄：鼠标的按键走 GATT 控制帧不走 HID 键盘，两轮真机
    /// 全部按键形态零键盘事件——抑制没有对象，**一个键都不吞**。
    /// 用户说话那几秒的键盘从此照常响应。
    @Test("鼠标会话期间不吞任何键")
    func mouseSuppressesNothing() {
        let suppressor = makeSuppressor()
        suppressor.beginSuppressing(policy: RemoteKeySuppressor.mousePolicy)
        for key in [kVK_F5, kVK_ANSI_A, kVK_Return, kVK_PageUp, kVK_F13, kVK_Space] {
            #expect(!suppressor.shouldSuppress(keyCode: Int64(key)))
        }
    }

    /// Esc 是录音期间唯一的取消键。收窄前它靠 `.allExcept` 的逃生口特判
    /// 放行，收窄后空集自然吞不到它——这条钉住的是「无论鼠标档将来怎么
    /// 改，Esc 必须放行」。
    @Test("鼠标会话期间仍然放行 Esc")
    func mouseKeepsEscapeHatch() {
        let suppressor = makeSuppressor()
        suppressor.beginSuppressing(policy: RemoteKeySuppressor.mousePolicy)
        #expect(!suppressor.shouldSuppress(keyCode: Int64(kVK_Escape)))
    }

    @Test("鼠标会话结束后一律放行")
    func mousePassesThroughOutsideSession() {
        let suppressor = makeSuppressor()
        suppressor.beginSuppressing(policy: RemoteKeySuppressor.mousePolicy)
        suppressor.endSuppressing()
        for key in [kVK_ANSI_A, kVK_Return, kVK_F5] {
            #expect(!suppressor.shouldSuppress(keyCode: Int64(key)))
        }
    }

    /// 遥控器与鼠标共用一个抑制器实例（同一个 CGEvent tap）。
    /// 上一次会话的策略不能粘住。收窄后两档的方向反过来了：粘住的风险
    /// 变成「遥控器会话沿用了鼠标的空集，F5 漏出去淹掉注入的文字」——
    /// 用宽档 `.allExcept` 验粘住（它与空集的差别最大），再验切回
    /// 默认档后 F5 被吞、A 放行。
    @Test("策略不会在会话之间粘住")
    func policyDoesNotLeakBetweenSessions() {
        let suppressor = makeSuppressor()

        suppressor.beginSuppressing(policy: .allExcept([Int64(kVK_Escape)]))
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
        // 素材用宽档：鼠标档收窄成空集后本来就不吞 A，拿它验「恢复」
        // 是恒真断言。这条测的是 update 收抑制的行为，不是策略内容。
        for state in DictationSession.State.allCasesInPipelineOrder.filter({ $0 != .listening }) {
            let suppressor = makeSuppressor()
            suppressor.beginSuppressing(policy: .allExcept([Int64(kVK_Escape)]))
            suppressor.update(for: state)
            #expect(
                !suppressor.shouldSuppress(keyCode: Int64(kVK_ANSI_A)),
                "离开 listening 进入 \(state) 之后键盘必须恢复"
            )
        }
    }

    /// 素材用宽档而不是 `mousePolicy`：鼠标档收窄成空集后本来就什么都
    /// 不吞，拿它验「listening 期间抑制不被收掉」是恒真。这条测的是
    /// `update` 的行为，不是某档策略的内容。
    @Test("listening 期间不收")
    func keepsSuppressingWhileListening() {
        let suppressor = makeSuppressor()
        suppressor.beginSuppressing(policy: .allExcept([Int64(kVK_Escape)]))
        suppressor.update(for: .listening)
        #expect(suppressor.shouldSuppress(keyCode: Int64(kVK_ANSI_A)))
    }

    /// `update(for:)` 不该反过来**开**抑制。⌥D 那条路从不调
    /// `beginSuppressing`（内置麦克风不产生杂键），而它同样会经过
    /// `.listening`——若在这里顺手打开，用户用 ⌥D 说话时键盘会莫名其妙
    /// 失灵。只收不开。
    @Test("update 只收不开")
    func updateNeverStartsSuppression() {
        let suppressor = makeSuppressor()
        suppressor.update(for: .listening)
        #expect(!suppressor.shouldSuppress(keyCode: Int64(kVK_F5)))
    }
}
