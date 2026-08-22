import Carbon.HIToolbox
import Foundation
import Testing

@testable import vInput

/// 遥控器「·」键 → 空格（2026-08-21 用户提的：Finder 里选中图片按它弹
/// Quick Look）。
///
/// **本套用例的重心不是「空格有没有注入」，是「用户自己的反引号键还在不在」。**
/// 吞键器是一个常开的、看得见每一次按键的系统级 tap；判错一个条件，终端里
/// 的 `~`、中文输入法的「·」就都没了。所以窗口外、非目标键、时钟回拨这几条
/// 各钉一条用例，还额外扫了一遍 0…127 的全部键码。
///
/// 测得到 / 测不到的分界（本仓库的老规矩）：状态机是纯函数，全测；
/// 真事件 tap 与真 HID 设备在测试进程里造不出来，那两截由真机验收覆盖。
@Suite("遥控器「·」键映射空格")
struct GraveKeyMappingTests {
    /// 0x35 写死钉住——它是三次真机按键逐一对出来的数，不是猜的
    /// （2026-08-21 16:42:17.620 / 16:42:20.185 / 16:42:22.525 三行
    /// `遥控器按键 usage=0x35`）。
    @Test("「·」键的 usage 是 0x35")
    func graveUsageIsPinned() {
        #expect(HIDReportParser.graveButtonUsage == 0x35)
    }

    @Test("「·」键按下沿被检测到")
    func gravePressDetected() {
        #expect(RemoteHIDListener.didPress(
            usage: HIDReportParser.graveButtonUsage, previous: [], current: [0x35]
        ))
    }

    /// 录音中忽略：说话时误碰不该往目标应用里插东西。同关机键那条哲学。
    @Test("空闲时注空格，听写中忽略")
    func spaceOnlyWhenIdle() {
        #expect(AppModel.graveKeyPostsSpace(dictationIdle: true))
        #expect(!AppModel.graveKeyPostsSpace(dictationIdle: false))
    }

    /// 键码 50 == `kVK_ANSI_Grave`。它同时是用户自己的 `` ` `` / `~` 键。
    @Test("吞的是键码 50，也就是反引号那个键")
    func graveKeyCodeIsPinned() {
        #expect(RemoteEchoSwallower.Key.grave.keyCode == 50)
        #expect(RemoteEchoSwallower.Key.grave.keyCode == Int64(kVK_ANSI_Grave))
    }

    /// 50 毫秒 = 实测 2 毫秒的 25 倍。数从哪来见
    /// `RemoteEchoSwallower.correlationWindow` 的注释。
    @Test("相关窗口是 50 毫秒")
    func windowIsPinned() {
        #expect(RemoteEchoSwallower.correlationWindow == 0.050)
    }

    /// 注入的是**空格键**，不是别的键。
    ///
    /// 这条守的是「有没有引错常量」。**「49 这个数对不对」本身没法测**：
    /// 真发 CGEvent 需要辅助功能授权，测试进程发不出去——实测把
    /// `post(key: 49)` 改成 51，1183 条用例全绿。所以源码那边改成了
    /// 引 `kVK_*`，让系统头文件来回答那个数，这里只钉引用没引错。
    @Test("三个注入目标各引对了 Carbon 常量")
    func keyCodesArePinned() {
        #expect(SystemKeyPoster.spaceKey == 49)
        #expect(SystemKeyPoster.returnKey == 36)
        #expect(SystemKeyPoster.backspaceKey == 51)
    }
}

/// 吞键状态机本身。纯函数，逐条钉。
///
/// 2026-08-22 起状态机是**两个键共用**的（「·」与菜单键），所以状态里记的
/// 不再是「有没有武装」而是「为哪个键武装的」。本套仍以「·」为主角——
/// 它是危险的那个（键码 50 是用户自己天天在按的键）；两个键之间不能串的
/// 那几条在 `AppSwitchKeyTests` 里。
@Suite("遥控器回声吞键状态机")
struct RemoteEchoSwallowerStateTests {
    static let grave = RemoteEchoSwallower.Key.grave.keyCode

    /// **基准时刻必须取 `timeIntervalSinceReferenceDate: 0`。**
    ///
    /// `Date` 内部就是一个相对参考日的 `Double`。取 0 时
    /// `base.addingTimeInterval(0.050).timeIntervalSince(base)` 得到的
    /// 正好是 `0.050` 这个 `Double` 字面量本身，边界断言才落在边界上。
    ///
    /// 原来写的是 `Date(timeIntervalSince1970: 1_000_000)`：内部值约
    /// -977307200，加 0.05 之后尾数被舍掉一截，差回来是 0.04999999998。
    /// 于是「恰好落在边界上算命中」那条**在 `<=` 改成 `<` 时照样全绿**
    /// ——一条空断言，2026-08-21 变异验证当场抓到（M10）。
    static let base = Date(timeIntervalSinceReferenceDate: 0)

    static func armed(
        _ key: RemoteEchoSwallower.Key = .grave, at offset: TimeInterval = 0
    ) -> RemoteEchoSwallower.State {
        RemoteEchoSwallower.State(
            armed: key, armedAt: base.addingTimeInterval(offset), awaitingKeyUpFor: nil)
    }

    static func decide(
        keyCode: Int64 = grave,
        isKeyDown: Bool = true,
        at offset: TimeInterval,
        state: RemoteEchoSwallower.State
    ) -> RemoteEchoSwallower.Decision {
        RemoteEchoSwallower.decide(
            keyCode: keyCode,
            isKeyDown: isKeyDown,
            now: base.addingTimeInterval(offset),
            state: state
        )
    }

    @Test("窗口内的「·」按下被吞掉")
    func swallowsInsideWindow() {
        let decision = Self.decide(at: 0.002, state: Self.armed())
        #expect(decision.swallow, "实测的 2 毫秒间隔都没吞掉，这个功能等于没有")
        #expect(decision.swallowed == .grave, "吞掉的键没记对，日志会写成另一个键")
        #expect(decision.state.armedAt == nil, "武装没被用掉，窗口余下的时间还会继续吞键")
        #expect(decision.state.armed == nil, "武装的键没被清掉")
        #expect(decision.state.awaitingKeyUpFor == .grave, "按下沿吞了，配对的松开沿却没记下来")
    }

    /// **本套最重要的一条。** 没武装时的「·」就是用户自己按的反引号。
    @Test("没有武装时「·」照常放行")
    func passesWhenNotArmed() {
        let decision = Self.decide(at: 0, state: RemoteEchoSwallower.State())
        #expect(!decision.swallow, "无差别吞掉了键码 50——用户的反引号键坏了")
        #expect(decision.state.awaitingKeyUpFor == nil)
    }

    /// 窗口过期之后同样是用户自己的键。
    @Test("超出窗口的「·」放行")
    func passesAfterWindowExpires() {
        let decision = Self.decide(at: 0.051, state: Self.armed())
        #expect(!decision.swallow, "窗口已过还在吞键，用户的反引号键会被随机吃掉")
        #expect(decision.state.armedAt == nil, "过期的武装没被清掉")
        #expect(decision.state.awaitingKeyUpFor == nil, "没吞按下沿却记了要吞松开沿")
    }

    /// 边界取闭区间：恰好 50 毫秒算命中。
    /// 能真的落在边界上，靠的是 `base` 那条注释里说的浮点取值。
    @Test("恰好落在窗口边界上算命中")
    func windowBoundaryIsInclusive() {
        let armedAt = Self.base
        let now = armedAt.addingTimeInterval(RemoteEchoSwallower.correlationWindow)
        #expect(now.timeIntervalSince(armedAt) == RemoteEchoSwallower.correlationWindow,
                "基准时刻选得不对，这条断言根本没落在边界上")
        let decision = RemoteEchoSwallower.decide(
            keyCode: Self.grave, isKeyDown: true, now: now,
            state: RemoteEchoSwallower.State(armed: .grave, armedAt: armedAt, awaitingKeyUpFor: nil))
        #expect(decision.swallow)
    }

    /// 时钟被 NTP 往回拨时 `elapsed` 为负。少了 `elapsed >= 0` 这一条，
    /// 负值照样满足 `<= window`，等于武装了一个无限长的窗口——
    /// 用户的反引号键会一直被吞。
    @Test("系统时钟往回拨时不吞键")
    func passesWhenClockGoesBackwards() {
        // 武装发生在「未来」：now - armedAt == -10 秒
        let decision = Self.decide(at: 0, state: Self.armed(at: 10))
        #expect(!decision.swallow, "时钟回拨后 elapsed 为负也被当成命中了")
    }

    /// 一次武装只换一次空格。
    @Test("一次武装只吞一次按下沿")
    func oneArmSwallowsOnlyOnePress() {
        let first = Self.decide(at: 0.002, state: Self.armed())
        #expect(first.swallow)
        let second = Self.decide(at: 0.004, state: first.state)
        #expect(!second.swallow, "同一次武装吞了第二个按键")
    }

    @Test("吞掉按下沿后，配对的松开沿也吞掉")
    func swallowsMatchingKeyUp() {
        let down = Self.decide(at: 0.002, state: Self.armed())
        let up = Self.decide(isKeyDown: false, at: 0.06, state: down.state)
        #expect(up.swallow, "只吞了一半，应用会收到一个没有配对按下的松开事件")
        #expect(up.state.awaitingKeyUpFor == nil, "松开沿吞完没有复位，下一次松开会被误吞")
    }

    /// 松开沿**不看窗口，只看有没有吞过配对的按下沿**——所以没吞过按下沿时
    /// 必须放行，否则用户的反引号会被吃掉一半（字打出来了，松开事件丢了）。
    @Test("没吞过按下沿时，松开沿放行")
    func passesUnmatchedKeyUp() {
        let up = Self.decide(isKeyDown: false, at: 0.002, state: Self.armed())
        #expect(!up.swallow, "吞了一个没有配对按下的松开事件")
    }

    /// 我们自己注入的空格会**穿过我们自己这个 tap**（常开、head-insert、
    /// 而 `postSpace` 发到 `.cgSessionEventTap`）。它必须原样放行，
    /// 否则这个功能会把自己注入的空格吃掉，表现是「按键完全没反应」。
    ///
    /// 真机日志能看到这一条在跑：`遥控器「·」键的武装窗口内出现
    /// keyCode=49，不是 50，未吞`（2026-08-22 18:26:36.439 等）。
    @Test("我们注入的空格不会被自己吞掉")
    func doesNotSwallowItsOwnSpace() {
        let decision = Self.decide(keyCode: Int64(kVK_Space), at: 0.001, state: Self.armed())
        #expect(!decision.swallow, "自己注入的空格被自己的 tap 吞了")
    }

    /// **武装期间的其他按键连状态都不该碰。** 若在这里顺手把武装清掉，
    /// 「按遥控器的同时键盘上落了一个键」就会让功能失效；若在这里吞键，
    /// 那就是全键盘失灵。扫一遍 0…127 而不是抽查几个。
    @Test("武装期间除「·」外的所有键码一律放行，且不改状态")
    func neverTouchesOtherKeyCodes() {
        var swallowed: [Int64] = []
        var mutated: [Int64] = []
        let state = Self.armed()
        for code in Int64(0)...Int64(127) where code != Self.grave {
            for isDown in [true, false] {
                let decision = Self.decide(
                    keyCode: code, isKeyDown: isDown, at: 0.002, state: state)
                if decision.swallow { swallowed.append(code) }
                if decision.state != state { mutated.append(code) }
            }
        }
        #expect(swallowed.isEmpty, "这些键码在武装期间被吞掉了：\(swallowed)")
        #expect(mutated.isEmpty, "这些键码改动了吞键状态：\(mutated)")
    }

    // MARK: - 诊断观测口

    /// 「遥控器那个键到事件层是哪个键码」是本功能唯一一类**推断**
    /// （日志里从没直接出现过，理由见 `Decision.observedWhileArmed`）。
    /// 这个观测口就是它错了时的兜底。
    @Test("武装窗口内的非「·」按下沿会被观测到")
    func observesNonGraveKeyDownWhileArmed() {
        let decision = Self.decide(keyCode: 24, at: 0.002, state: Self.armed())
        #expect(decision.observedWhileArmed == .grave, "推断错了的话，日志里连真实键码都没有")
        #expect(!decision.swallow, "观测口不该顺手把键吞了")
    }

    /// **不武装时一个键码都不记。** 这个 tap 看得见用户的全部输入，
    /// 无条件记键码就是键盘记录器。
    @Test("没武装时不观测任何键码")
    func observesNothingWhenNotArmed() {
        var observed: [Int64] = []
        for code in Int64(0)...Int64(127) {
            for isDown in [true, false] {
                let decision = Self.decide(
                    keyCode: code, isKeyDown: isDown, at: 0,
                    state: RemoteEchoSwallower.State())
                if decision.observedWhileArmed != nil { observed.append(code) }
            }
        }
        #expect(observed.isEmpty, "武装窗口外记了这些键码，成了键盘记录器：\(observed)")
    }

    @Test("窗口过期后不再观测")
    func stopsObservingAfterWindow() {
        #expect(Self.decide(keyCode: 24, at: 0.051, state: Self.armed()).observedWhileArmed == nil)
    }

    /// 只记按下沿：松开沿一起记只是把同一件事写两遍。
    @Test("松开沿不观测")
    func doesNotObserveKeyUp() {
        #expect(Self.decide(
            keyCode: 24, isKeyDown: false, at: 0.002, state: Self.armed()
        ).observedWhileArmed == nil)
    }

    /// 「·」自己走的是吞键那条路，日志由 `handle` 那边记，不重复观测。
    @Test("「·」本身不走观测口")
    func graveItselfIsNotObserved() {
        #expect(Self.decide(at: 0.002, state: Self.armed()).observedWhileArmed == nil)
    }
}

/// 吞键器实例：tap 的生命周期，以及「测试进程绝不装真 tap」。
///
/// 后者不是洁癖：`RemoteKeySuppressor` 因为同一件事崩过四次
/// （见那边 `TapInstaller` 的注释里的崩溃报告），本类是照它的形状写的，
/// 同一个坑必须同样堵上。
@MainActor
@Suite("遥控器回声吞键器的 tap 生命周期")
struct RemoteEchoSwallowerTapTests {
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

    /// 装了几次。`FakeTap` 自己数不出来——重复 `start()` 会把同一个假 tap
    /// 再装一遍，`invalidateCount` 仍是 0，那条断言就是空的。
    @MainActor
    final class InstallCounter {
        var count = 0
    }

    private func makeSwallower(
        tap: FakeTap? = nil, counter: InstallCounter? = nil
    ) -> RemoteEchoSwallower {
        RemoteEchoSwallower(installer: { _ in
            counter?.count += 1
            return tap
        })
    }

    /// 守的是上面那个 `makeSwallower`。谁把它改回默认构造都不会有人发现，
    /// 而失效的表现是「跑完测试之后某次按键让测试进程崩掉」。
    @Test("测试用的吞键器不装系统级 tap")
    func installsNoSystemTap() {
        let swallower = makeSwallower()
        swallower.start()
        #expect(!swallower.hasTap, "测试进程装了真的 CGEvent tap")
        swallower.arm(.grave)
        #expect(!swallower.hasTap, "arm() 里的补装重试装了真 tap")
    }

    @Test("start 装上 tap，重复 start 不重复装")
    func startInstallsOnce() {
        let counter = InstallCounter()
        let swallower = makeSwallower(tap: FakeTap(), counter: counter)
        swallower.start()
        #expect(swallower.hasTap)
        swallower.start()
        swallower.arm(.grave)
        #expect(counter.count == 1, "重复装了 tap，系统里会留下够不到的第二个")
    }

    /// tap 尚未装上时 `arm()` 要补装一次：开发期每次重新打包签名都变、
    /// TCC 授权随之重置，用户补授权后不必重启应用。
    @Test("tap 没装上时 arm 会补装一次")
    func armRetriesInstall() {
        let counter = InstallCounter()
        let swallower = makeSwallower(tap: FakeTap(), counter: counter)
        #expect(!swallower.hasTap)
        swallower.arm(.grave)
        #expect(swallower.hasTap, "arm() 没有补装 tap，补授权之后要重启才生效")
        #expect(counter.count == 1)
    }

    /// `stop()` 必须真的拆掉 tap，不是只禁用——mach port 还活着的话系统
    /// 仍可能投递事件，而那时 `userInfo` 已是野指针。
    @Test("stop 真的拆掉 tap，且解除武装")
    func stopInvalidatesAndDisarms() {
        let tap = FakeTap()
        let swallower = makeSwallower(tap: tap)
        swallower.arm(.grave)
        #expect(swallower.hasTap)

        swallower.stop()
        #expect(tap.isInvalidated, "stop 只禁用了 tap，没有拆掉它")
        #expect(!swallower.hasTap)

        // 停掉之后残留的武装若还在，下次 start 会莫名其妙吞掉一个反引号。
        swallower.start()
        #expect(!swallower.consume(
            keyCode: RemoteEchoSwallower.Key.grave.keyCode, isKeyDown: true).swallow,
                "stop 之后武装还留着")
    }

    /// **tap 绝不能活得比宿主久。** 宿主释放后 tap 仍挂在系统里，
    /// 回调拿着裸指针去访问已释放的内存 → SIGSEGV。
    @Test("deinit 拆掉 tap")
    func deinitInvalidatesTap() {
        let tap = FakeTap()
        do {
            let swallower = makeSwallower(tap: tap)
            swallower.start()
            #expect(swallower.hasTap)
        }
        #expect(tap.isInvalidated, "宿主析构了，系统级 tap 还挂着——下一次按键就是野指针")
    }

    /// 实例入口跑的是同一个状态机：武装 → 吞按下沿 → 吞松开沿。
    @Test("实例入口按状态机吞键")
    func consumeFollowsStateMachine() {
        let swallower = makeSwallower(tap: FakeTap())
        let now = Date()
        swallower.arm(.grave, now: now)
        #expect(swallower.consume(
            keyCode: RemoteEchoSwallower.Key.grave.keyCode, isKeyDown: true,
            now: now.addingTimeInterval(0.002)).swallow)
        #expect(swallower.consume(
            keyCode: RemoteEchoSwallower.Key.grave.keyCode, isKeyDown: false,
            now: now.addingTimeInterval(0.06)).swallow)
        // 武装用掉之后，用户自己按的反引号必须原样放行
        #expect(!swallower.consume(
            keyCode: RemoteEchoSwallower.Key.grave.keyCode, isKeyDown: true,
            now: now.addingTimeInterval(1)).swallow)
    }

    /// 实例入口认得两个键：为菜单键武装时，吞的是菜单键那个键码。
    @Test("实例入口按武装的那个键吞")
    func consumeHonoursArmedKey() {
        let swallower = makeSwallower(tap: FakeTap())
        let now = Date()
        swallower.arm(.contextualMenu, now: now)
        #expect(!swallower.consume(
            keyCode: RemoteEchoSwallower.Key.grave.keyCode, isKeyDown: true,
            now: now.addingTimeInterval(0.002)).swallow,
                "为菜单键武装，却把反引号吞了")
        #expect(swallower.consume(
            keyCode: RemoteEchoSwallower.Key.contextualMenu.keyCode, isKeyDown: true,
            now: now.addingTimeInterval(0.003)).swallow,
                "为菜单键武装，菜单键却没被吞")
    }
}
