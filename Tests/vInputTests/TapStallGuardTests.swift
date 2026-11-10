import Carbon.HIToolbox
import Testing

@testable import vInput

/// 2026-11-10 全系统键盘失灵事故的保险。事故经过与证据见
/// `TapStallGuard` 的类注释和 `docs/BUG-2026-11-10-键盘输入被吞.md`。
///
/// 这里钉三件事：
/// 1. 判据（纯状态机）：什么时候算卡死、什么时候绝不能算；
/// 2. 预算：反复卡死时要停手，**不能无限重建**；
/// 3. 两个宿主收到「卡死」后**真的把 tap 拆掉**——那一步才是把键盘还给用户的动作。
@MainActor
@Suite("事件 tap 卡死看门狗")
struct TapStallGuardTests {
    typealias Detector = TapStallGuard.Detector

    /// `#expect` 宏里不能调 mutating 方法，包一层引用类型。
    final class DetectorBox {
        var detector = Detector()
        func check(
            now: TimeInterval, systemLastKeyDown: TimeInterval, tapLastKeyDown: TimeInterval?,
            tapInstalledAt: TimeInterval, secureInput: Bool
        ) -> Bool {
            detector.check(
                now: now, systemLastKeyDown: systemLastKeyDown, tapLastKeyDown: tapLastKeyDown,
                tapInstalledAt: tapInstalledAt, secureInput: secureInput)
        }
    }

    // MARK: - 判据

    /// 事故本身：系统收到了按键，我们的回调一直没看到。
    @Test("系统有按键、回调没看到，超过 grace 判卡死")
    func detectsStallAfterGrace() {
        let d = DetectorBox()
        // 装于 0 秒，系统 10 秒时有一次按键，回调从没见过按键。
        #expect(!d.check(now: 10.1, systemLastKeyDown: 10, tapLastKeyDown: nil,
                         tapInstalledAt: 0, secureInput: false), "第一次发现只起算，不判")
        #expect(!d.check(now: 11.0, systemLastKeyDown: 10, tapLastKeyDown: nil,
                         tapInstalledAt: 0, secureInput: false), "不到 grace 不判")
        #expect(d.check(now: 12.1, systemLastKeyDown: 10, tapLastKeyDown: nil,
                        tapInstalledAt: 0, secureInput: false), "超过 grace 还没对上，该判")
    }

    /// 回调见到的是更早的一次按键，系统那边又来了新的——同样算没对上。
    @Test("回调只见过更早的按键，同样判卡死")
    func staleCallbackCountsAsUnseen() {
        let d = DetectorBox()
        _ = d.check(now: 10.1, systemLastKeyDown: 10, tapLastKeyDown: 5,
                    tapInstalledAt: 0, secureInput: false)
        #expect(d.check(now: 12.2, systemLastKeyDown: 10, tapLastKeyDown: 5,
                        tapInstalledAt: 0, secureInput: false))
    }

    /// 健康时：回调几毫秒内就看到同一次按键，**绝不能判**。
    /// 判错的代价虽小（重建一次），但每次打字都判就是天天刷日志、天天拆 tap。
    @Test("回调看到了同一次按键，不判")
    func healthyTapNeverStalls() {
        let d = DetectorBox()
        for t in stride(from: 1.0, through: 30.0, by: 0.5) {
            // 回调比系统晚 3 毫秒看到——真机上的量级。
            #expect(!d.check(now: t, systemLastKeyDown: t - 0.1, tapLastKeyDown: t - 0.097,
                             tapInstalledAt: 0, secureInput: false))
        }
    }

    /// 两个时钟来源不同，回调时间略早于系统推算的时间也算对上。
    @Test("两边时间差在容差内算对上")
    func withinSlackIsSeen() {
        let d = DetectorBox()
        _ = d.check(now: 10.1, systemLastKeyDown: 10.2, tapLastKeyDown: 10.0,
                    tapInstalledAt: 0, secureInput: false)
        #expect(!d.check(now: 13, systemLastKeyDown: 10.2, tapLastKeyDown: 10.0,
                         tapInstalledAt: 0, secureInput: false))
    }

    /// 刚装上时，系统里「最近一次按键」可能是装之前的，那不归我们看。
    @Test("tap 装上之前的按键不算")
    func keysBeforeInstallDoNotCount() {
        let d = DetectorBox()
        _ = d.check(now: 100.1, systemLastKeyDown: 50, tapLastKeyDown: nil,
                    tapInstalledAt: 100, secureInput: false)
        #expect(!d.check(now: 110, systemLastKeyDown: 50, tapLastKeyDown: nil,
                         tapInstalledAt: 100, secureInput: false))
    }

    /// 密码框开着安全输入时，tap 本来就收不到按键。这时判卡死就是误判。
    @Test("安全输入开着时不判")
    func secureInputSuppressesVerdict() {
        let d = DetectorBox()
        _ = d.check(now: 10.1, systemLastKeyDown: 10, tapLastKeyDown: nil,
                    tapInstalledAt: 0, secureInput: true)
        #expect(!d.check(now: 20, systemLastKeyDown: 10, tapLastKeyDown: nil,
                         tapInstalledAt: 0, secureInput: true))
    }

    /// 中途对上了（比如只是一次卡顿），计时要清零，不能累计到下一次。
    @Test("中途对上就清零重计")
    func recoveryResetsTimer() {
        let d = DetectorBox()
        _ = d.check(now: 10.1, systemLastKeyDown: 10, tapLastKeyDown: nil,
                    tapInstalledAt: 0, secureInput: false)
        // 1.5 秒后回调看到了。
        #expect(!d.check(now: 11.6, systemLastKeyDown: 10, tapLastKeyDown: 10.001,
                         tapInstalledAt: 0, secureInput: false))
        // 又一次没对上的按键：从这里重新起算。
        #expect(!d.check(now: 12.0, systemLastKeyDown: 11.9, tapLastKeyDown: 10.001,
                         tapInstalledAt: 0, secureInput: false))
        #expect(!d.check(now: 13.0, systemLastKeyDown: 11.9, tapLastKeyDown: 10.001,
                         tapInstalledAt: 0, secureInput: false), "沿用了旧的起算点")
        #expect(d.check(now: 14.1, systemLastKeyDown: 11.9, tapLastKeyDown: 10.001,
                        tapInstalledAt: 0, secureInput: false))
    }

    /// 判过一次之后状态要清掉，宿主重建后从头再计，不能下一次检查又立刻判。
    @Test("判定后清零")
    func verdictClearsState() {
        let d = DetectorBox()
        _ = d.check(now: 10.1, systemLastKeyDown: 10, tapLastKeyDown: nil,
                    tapInstalledAt: 0, secureInput: false)
        #expect(d.check(now: 12.2, systemLastKeyDown: 10, tapLastKeyDown: nil,
                        tapInstalledAt: 0, secureInput: false))
        #expect(d.detector.unseenSince == nil)
        #expect(!d.check(now: 12.7, systemLastKeyDown: 10, tapLastKeyDown: nil,
                         tapInstalledAt: 0, secureInput: false))
    }

    // MARK: - 预算

    @Test("窗口内最多重建 maxRecoveries 次，过了窗口恢复额度")
    func recoveryBudget() {
        let limit = TapStallGuard.maxRecoveries
        let window = TapStallGuard.recoveryWindow
        let full = (0..<limit).map { Double($0) }
        #expect(TapStallGuard.mayRecover(now: 10, previous: Array(full.dropLast())))
        #expect(!TapStallGuard.mayRecover(now: 10, previous: full), "额度用完还在重建")
        #expect(TapStallGuard.mayRecover(now: window + Double(limit), previous: full),
                "过了窗口还不给重建")
    }

    // MARK: - 宿主

    /// 手动时钟。测试里推时间、按键全由它喂。
    @MainActor
    final class ManualClock {
        var now: TimeInterval = 0
        var systemLastKeyDown: TimeInterval = 0
        var environment: TapStallGuard.Environment {
            .manual(now: { self.now }, systemLastKeyDown: { self.systemLastKeyDown })
        }

        /// 模拟「用户按了一下键，但 tap 的回调没收到」，然后推过 grace。
        func unseenKeyPress(on guardian: TapStallGuard) {
            now += 1
            systemLastKeyDown = now
            guardian.check()
            now += TapStallGuard.grace + 0.1
            guardian.check()
        }
    }

    @MainActor
    final class FakeTap: EventTapping {
        private(set) var invalidateCount = 0
        nonisolated func invalidate() {
            MainActor.assumeIsolated { invalidateCount += 1 }
        }
        nonisolated func setEnabled(_ enabled: Bool) {}
    }

    /// **事故的修复动作本身**：判卡死 → 旧 tap 被拆掉 → 装一个新的。
    /// 只换新不拆旧的话，卡死的那个还挂在系统里吞键盘。
    @Test("按键抑制器：卡死后拆掉旧 tap 并重建")
    func suppressorRebuildsOnStall() {
        let clock = ManualClock()
        var taps: [FakeTap] = []
        let suppressor = RemoteKeySuppressor(
            installer: { _ in
                let tap = FakeTap()
                taps.append(tap)
                return tap
            },
            stallEnvironment: clock.environment)
        suppressor.start()
        #expect(taps.count == 1)

        clock.unseenKeyPress(on: suppressor.stallGuard)
        #expect(taps[0].invalidateCount == 1, "卡死的 tap 没拆，键盘还被它吞着")
        #expect(taps.count == 2, "拆了没重建，遥控器杂键从此没人管")
        #expect(suppressor.hasTap)
        #expect(taps[1].invalidateCount == 0)
    }

    /// 反复卡死：拆掉之后不再重建，**键盘优先**。不停手的话就是
    /// 「每 2.5 秒吞一次键盘」的无限循环。
    @Test("按键抑制器：预算用完后只拆不建，stop 之后才清账")
    func suppressorGivesUpAfterBudget() {
        let clock = ManualClock()
        var installs = 0
        var taps: [FakeTap] = []
        let suppressor = RemoteKeySuppressor(
            installer: { _ in
                installs += 1
                let tap = FakeTap()
                taps.append(tap)
                return tap
            },
            stallEnvironment: clock.environment)
        suppressor.start()
        for _ in 0..<TapStallGuard.maxRecoveries {
            clock.unseenKeyPress(on: suppressor.stallGuard)
        }
        #expect(installs == 1 + TapStallGuard.maxRecoveries)
        #expect(suppressor.hasTap)

        clock.unseenKeyPress(on: suppressor.stallGuard)
        #expect(!suppressor.hasTap, "预算用完还留着 tap")
        #expect(taps.last?.invalidateCount == 1, "最后那个卡死的 tap 没拆")
        #expect(installs == 1 + TapStallGuard.maxRecoveries, "预算用完还在重建")

        // 会话开始时会顺手 start()——预算用完后它也不该把 tap 装回来。
        suppressor.beginSuppressing()
        #expect(!suppressor.hasTap, "beginSuppressing 绕过了「放弃」")

        suppressor.stop()
        suppressor.start()
        #expect(suppressor.hasTap, "stop 之后没清账，遥控器重连也装不回来")
    }

    /// 健康的 tap 不该被拆：回调看到了按键，看门狗就不动。
    @Test("按键抑制器：回调看到按键时不动 tap")
    func suppressorLeavesHealthyTapAlone() {
        let clock = ManualClock()
        let tap = FakeTap()
        let suppressor = RemoteKeySuppressor(
            installer: { _ in tap }, stallEnvironment: clock.environment)
        suppressor.start()
        for _ in 0..<10 {
            clock.now += 1
            clock.systemLastKeyDown = clock.now
            suppressor.stallGuard.sawKeyDown()
            suppressor.stallGuard.check()
            clock.now += TapStallGuard.grace + 0.1
            suppressor.stallGuard.check()
        }
        #expect(tap.invalidateCount == 0)
    }

    @Test("回声吞键器：卡死后拆掉旧 tap 并重建，预算用完只拆不建")
    func swallowerRebuildsThenGivesUp() {
        let clock = ManualClock()
        var taps: [FakeTap] = []
        let swallower = RemoteEchoSwallower(
            installer: { _ in
                let tap = FakeTap()
                taps.append(tap)
                return tap
            },
            stallEnvironment: clock.environment)
        swallower.start()

        clock.unseenKeyPress(on: swallower.stallGuard)
        #expect(taps[0].invalidateCount == 1, "卡死的 tap 没拆")
        #expect(taps.count == 2)

        for _ in 1..<TapStallGuard.maxRecoveries {
            clock.unseenKeyPress(on: swallower.stallGuard)
        }
        clock.unseenKeyPress(on: swallower.stallGuard)
        #expect(!swallower.hasTap, "预算用完还留着 tap")
        #expect(taps.count == 1 + TapStallGuard.maxRecoveries)

        // HID 层武装时会顺手 start()——也不该绕过「放弃」。
        swallower.arm(.grave)
        #expect(!swallower.hasTap, "arm 绕过了「放弃」")

        swallower.stop()
        swallower.start()
        #expect(swallower.hasTap)
    }

    /// 没装 tap 时看门狗什么都不做（测试进程、缺辅助功能授权都是这种情况）。
    @Test("没装 tap 时不判")
    func noTapNoVerdict() {
        let clock = ManualClock()
        var stalls = 0
        let guardian = TapStallGuard(environment: clock.environment) { stalls += 1 }
        clock.unseenKeyPress(on: guardian)
        #expect(stalls == 0)
        guardian.tapInstalled()
        clock.unseenKeyPress(on: guardian)
        #expect(stalls == 1)
        guardian.tapRemoved()
        clock.unseenKeyPress(on: guardian)
        #expect(stalls == 1, "拆掉之后还在判")
    }
}
