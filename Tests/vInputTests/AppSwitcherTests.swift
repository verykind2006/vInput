import AppKit
import Foundation
import Testing

@testable import vInput

/// 应用切换器：按住 Command 跨越多次按键，用户才能在最近使用列表里连着往后翻。
///
/// 2026-08-22 真机验收暴露的问题：一次按一次松，macOS 一提交就重排 MRU，
/// 用户只能在 Terminal ⇄ Finder 之间来回，翻不到第三个应用。
///
/// **本套用例的重心不是「切没切成」，是「Command 有没有被卡住」。**
/// 合成的 Command 留在按下状态，用户之后敲什么都变成快捷键，而且他既不知道
/// 发生了什么，也没法自己解除（松开真键盘没用）。所以五道兜底各钉用例，
/// 顺序与配对（一个按下、N 个 Tab、一个抬起）逐条钉。
///
/// 测得到 / 测不到：状态推进与计时判断是纯函数，全测；实例这一层靠
/// `tick(now:)` 驱动，也全测。真发不发得出 `CGEvent`、切换器浮层认不认这套
/// 修饰键序列，只有真机能验。
@Suite("应用切换器的会话状态机")
struct AppSwitcherStateTests {
    /// **基准时刻取 `timeIntervalSinceReferenceDate: 0`。**
    /// `Date` 内部是相对参考日的 `Double`，取 0 时
    /// `base.addingTimeInterval(0.700).timeIntervalSince(base)` 正好是 `0.700`
    /// 这个字面量，边界断言才真的落在边界上。取别的基准会被浮点尾数吃掉一截，
    /// 「恰好到点」那条就变成空断言（2026-08-21 变异验证抓到过一次）。
    static let base = Date(timeIntervalSinceReferenceDate: 0)

    static func holding(
        since: TimeInterval = 0, lastPress: TimeInterval = 0, tabs: Int = 1
    ) -> AppSwitcher.State {
        AppSwitcher.State(holding: AppSwitcher.State.Holding(
            since: base.addingTimeInterval(since),
            lastPressAt: base.addingTimeInterval(lastPress),
            tabCount: tabs))
    }

    // MARK: - 1. 首次按下

    @Test("首次按下发 Command 按下 + 一个 Tab")
    func firstPressOpensSession() {
        let result = AppSwitcher.press(now: Self.base, state: AppSwitcher.State())
        #expect(result.steps == [.commandDown, .tab], "第一次按没有唤出浮层，功能等于没有")
        #expect(result.state.holding?.tabCount == 1)
        #expect(result.state.holding?.since == Self.base)
        #expect(result.state.holding?.lastPressAt == Self.base)
    }

    // MARK: - 2. 会话中再按

    /// **这条是本次改动的全部意义所在。** 重复发 Command 按下，等于每次都
    /// 重开一次切换器，用户又退回「只能在两个应用间来回」。
    @Test("会话进行中再按只发 Tab，不重复发 Command 按下")
    func secondPressOnlySendsTab() {
        let first = AppSwitcher.press(now: Self.base, state: AppSwitcher.State())
        let second = AppSwitcher.press(now: Self.base.addingTimeInterval(0.3), state: first.state)
        #expect(second.steps == [.tab], "会话中又发了一次 Command 按下，切换器被重开了")
        #expect(second.state.holding?.tabCount == 2)
        #expect(second.state.holding?.since == Self.base, "会话开始时刻被改了，封顶会一直往后顺延")
        #expect(second.state.holding?.lastPressAt == Self.base.addingTimeInterval(0.3),
                "停手计时没有被这次按键刷新，会提前提交")
    }

    // MARK: - 3./4. 停手提交，连按 N 次

    @Test("连按 N 次恰好是一个 Command 按下、N 个 Tab、一个 Command 抬起")
    func nPressesProduceExactSequence() {
        var state = AppSwitcher.State()
        var steps: [AppSwitchStep] = []
        for index in 0..<5 {
            let result = AppSwitcher.press(
                now: Self.base.addingTimeInterval(Double(index) * 0.3), state: state)
            steps += result.steps
            state = result.state
        }
        // 最后一次按在 1.2 秒，停手到 1.9 秒（满 0.7）才提交
        let now = Self.base.addingTimeInterval(1.9)
        #expect(AppSwitcher.dueRelease(now: now, state: state) == .idle)
        let released = AppSwitcher.release(state: state)
        steps += released.steps

        #expect(steps.filter { $0 == .commandDown }.count == 1, "Command 按下发了不止一次")
        #expect(steps.filter { $0 == .tab }.count == 5, "Tab 的次数与按键次数对不上：\(steps)")
        #expect(steps.filter { $0 == .commandUp }.count == 1, "Command 抬起发了不止一次")
        #expect(steps.first == .commandDown && steps.last == .commandUp,
                "顺序错了——Command 不是最先按下、最后抬起：\(steps)")
        #expect(released.state.holding == nil)
    }

    @Test("停手不满 700 毫秒不提交")
    func doesNotCommitBeforeIdleDelay() {
        let state = Self.holding()
        #expect(AppSwitcher.dueRelease(
            now: Self.base.addingTimeInterval(0.699), state: state) == nil,
                "还没停够就提交了，用户按第二下时切换器已经关了")
    }

    /// 边界取闭区间：恰好 700 毫秒就提交。
    @Test("恰好停手 700 毫秒就提交")
    func commitsExactlyAtIdleDelay() {
        let now = Self.base.addingTimeInterval(AppSwitcher.idleCommitDelay)
        #expect(now.timeIntervalSince(Self.base) == AppSwitcher.idleCommitDelay,
                "基准时刻选得不对，这条断言根本没落在边界上")
        #expect(AppSwitcher.dueRelease(now: now, state: Self.holding()) == .idle)
    }

    // MARK: - 5. 封顶

    @Test("按住满封顶时长无条件释放，哪怕刚按过")
    func capReleasesEvenWhileStillPressing() {
        // 会话开始于 0，最后一次按键就在此刻——停手那条完全没到期
        let state = Self.holding(since: 0, lastPress: 12.0, tabs: 20)
        #expect(AppSwitcher.dueRelease(
            now: Self.base.addingTimeInterval(12.0), state: state) == .cap,
                "封顶没生效——用户一直连按就能让 Command 无限期按着")
    }

    @Test("封顶前一刻不释放")
    func doesNotCapEarly() {
        let state = Self.holding(since: 0, lastPress: 11.999)
        #expect(AppSwitcher.dueRelease(
            now: Self.base.addingTimeInterval(11.999), state: state) == nil)
    }

    /// 两条同时到期时报封顶：「按满了封顶」比「停手 0.7 秒」更能说明当时发生了什么。
    @Test("封顶与停手同时到期时报封顶")
    func capWinsOverIdle() {
        let state = Self.holding(since: 0, lastPress: 1.0)
        #expect(AppSwitcher.dueRelease(
            now: Self.base.addingTimeInterval(13.0), state: state) == .cap)
    }

    /// 时钟被 NTP 往回拨时 elapsed 为负。**这里必须往「立刻释放」那边倒**
    /// ——负值若被当成「还没到期」，封顶就成了一个永远到不了的期限，
    /// 那正是「Command 永远按着」。与 `RemoteEchoSwallower` 的取舍方向相反。
    @Test("系统时钟往回拨时立刻释放")
    func releasesWhenClockGoesBackwards() {
        let state = Self.holding(since: 10, lastPress: 10)
        #expect(AppSwitcher.dueRelease(now: Self.base, state: state) == .cap,
                "时钟回拨后期限永远到不了，Command 会一直按着")
    }

    @Test("没有会话时不该释放")
    func noReleaseWhenIdle() {
        #expect(AppSwitcher.dueRelease(
            now: Self.base.addingTimeInterval(100), state: AppSwitcher.State()) == nil)
    }

    /// 计时器漏拍（主线程忙、或系统睡醒）时，`press` 自己也要认封顶：
    /// 先把上一段收掉再开新的，绝不把一段已经超时的会话继续往下拖。
    @Test("超过封顶后再按：先抬起再开新会话")
    func pressAfterCapClosesTheOldSession() {
        let state = Self.holding(since: 0, lastPress: 0, tabs: 3)
        let result = AppSwitcher.press(now: Self.base.addingTimeInterval(13), state: state)
        #expect(result.steps == [.commandUp, .commandDown, .tab],
                "计时器漏拍时又把超时会话往下拖了：\(result.steps)")
        #expect(result.state.holding?.tabCount == 1, "新会话的计数没有重置")
        #expect(result.state.holding?.since == Self.base.addingTimeInterval(13))
    }

    // MARK: - 7. 幂等释放

    @Test("没按住时释放是空操作")
    func releaseIsIdempotent() {
        let first = AppSwitcher.release(state: Self.holding())
        #expect(first.steps == [.commandUp])
        let second = AppSwitcher.release(state: first.state)
        #expect(second.steps.isEmpty, "重复释放发出了第二个 Command 抬起")
        #expect(second.state.holding == nil)
    }

    // MARK: - 常量与日志用的枚举

    @Test("两个时间常量钉住")
    func constantsArePinned() {
        #expect(AppSwitcher.idleCommitDelay == 0.700)
        // 12 秒是 2026-08-22 真机实测后从 5 秒放宽的：那次用户六次会话有三次
        // 连按到 16 下、一次 20 下（约 190 毫秒一下），其中一次撞上 5 秒被强制
        // 提交——「一口气按十几下」对这位用户是常态。写死字面量而不是引用
        // 常量：引用的话改常量测试会跟着自适应，等于没钉。
        #expect(AppSwitcher.maxHold == 12.0)
        #expect(AppSwitcher.tickInterval == 0.050)
        #expect(AppSwitcher.tickInterval < AppSwitcher.idleCommitDelay,
                "查得比提交期限还稀，提交会被拖到下一拍之后")
        #expect(AppSwitcher.idleCommitDelay < AppSwitcher.maxHold,
                "停手期限比封顶还长，封顶就永远轮不到了")
    }

    /// 释放原因是真机上认路的唯一依据——两条同名就分不清是哪条兜底走到了。
    @Test("六个释放原因的日志名互不相同且非空")
    func releaseReasonsAreDistinct() {
        let names = AppSwitcher.ReleaseReason.allCases.map(\.rawValue)
        #expect(names.count == 6)
        #expect(Set(names).count == names.count, "有两条兜底的日志名一样：\(names)")
        #expect(names.allSatisfy { !$0.isEmpty })
    }
}

/// 实例这一层：真的把按键发出去、计时器、五道兜底。
@MainActor
@Suite("应用切换器的实例行为与兜底")
struct AppSwitcherInstanceTests {
    /// **一律用 `noTimerInstaller`。** 真往主 run loop 上挂一个 0.05 秒的
    /// 重复计时器，它会在别的用例跑到一半时醒过来改这个对象的状态——
    /// 同 `RemoteEchoSwallower` 那条「测试进程不装真 tap」的规矩。
    static func makeSwitcher() -> (AppSwitcher, FakeKeyPoster) {
        let poster = FakeKeyPoster()
        return (AppSwitcher(poster: poster, timerInstaller: AppSwitcher.noTimerInstaller), poster)
    }

    static let base = Date(timeIntervalSinceReferenceDate: 0)

    /// 守上面那个工厂：谁把它改回默认构造都不会有人发现，而失效的表现是
    /// 「测试跑完之后某个用例莫名其妙红一次」。
    @Test("测试用的切换器不装真计时器")
    func installsNoRealTimer() {
        let (switcher, _) = Self.makeSwitcher()
        switcher.press(now: Self.base)
        #expect(!switcher.hasTimer, "测试进程挂上了真的重复计时器")
        #expect(switcher.isHolding)
        switcher.release(reason: .shutdown)
    }

    @Test("按一下真的把两步发出去了")
    func pressEmitsSteps() {
        let (switcher, poster) = Self.makeSwitcher()
        switcher.press(now: Self.base)
        #expect(poster.appSwitchSteps == [.commandDown, .tab])
        #expect(switcher.tabCount == 1)
        switcher.release(reason: .shutdown)
    }

    @Test("连按三次再停手：一个按下、三个 Tab、一个抬起")
    func threePressesThenCommit() {
        let (switcher, poster) = Self.makeSwitcher()
        switcher.press(now: Self.base)
        switcher.press(now: Self.base.addingTimeInterval(0.2))
        switcher.press(now: Self.base.addingTimeInterval(0.4))
        #expect(poster.appSwitchSteps == [.commandDown, .tab, .tab, .tab])

        // 停手还不够久
        switcher.tick(now: Self.base.addingTimeInterval(1.0))
        #expect(switcher.isHolding, "才停了 0.6 秒就提交了")

        switcher.tick(now: Self.base.addingTimeInterval(1.2))
        #expect(!switcher.isHolding)
        #expect(poster.appSwitchSteps == [.commandDown, .tab, .tab, .tab, .commandUp])
    }

    /// 提交之后计时器要收掉，否则一个空转的计时器会一直挂在 run loop 上。
    @Test("提交之后计时器被收掉")
    func timerStopsAfterCommit() {
        let poster = FakeKeyPoster()
        var installs = 0
        let switcher = AppSwitcher(poster: poster, timerInstaller: { _ in
            installs += 1
            return FakeTicker()
        })
        switcher.press(now: Self.base)
        #expect(switcher.hasTimer && installs == 1)
        switcher.press(now: Self.base.addingTimeInterval(0.1))
        #expect(installs == 1, "第二次按键又装了一个计时器")
        switcher.tick(now: Self.base.addingTimeInterval(1.0))
        #expect(!switcher.hasTimer, "提交之后计时器还挂着，会一直空转")
        // 新会话要能重新装上
        switcher.press(now: Self.base.addingTimeInterval(2))
        #expect(installs == 2, "新会话没有重新装计时器，之后永远不会自动提交")
        switcher.release(reason: .shutdown)
    }

    @MainActor
    final class FakeTicker: AppSwitcher.Ticking {
        private(set) var invalidateCount = 0
        nonisolated func invalidate() {
            MainActor.assumeIsolated { invalidateCount += 1 }
        }
    }

    @Test("计时器真的被作废，不是只丢掉引用")
    func timerIsInvalidated() {
        let ticker = FakeTicker()
        let switcher = AppSwitcher(poster: FakeKeyPoster(), timerInstaller: { _ in ticker })
        switcher.press(now: Self.base)
        switcher.release(reason: .shutdown)
        #expect(ticker.invalidateCount == 1, "只丢了引用没作废，计时器还在 run loop 上跑")
    }

    // MARK: - 兜底

    @Test("封顶到点强制释放，哪怕还在连按")
    func capReleases() {
        let (switcher, poster) = Self.makeSwitcher()
        for index in 0..<10 {
            switcher.press(now: Self.base.addingTimeInterval(Double(index) * 0.5))
        }
        #expect(switcher.isHolding)
        switcher.tick(now: Self.base.addingTimeInterval(12.0))
        #expect(!switcher.isHolding, "连按到封顶时长还没释放——Command 可以被无限期按着")
        #expect(poster.appSwitchSteps.last == .commandUp)
        #expect(poster.appSwitchSteps.filter { $0 == .commandUp }.count == 1)
    }

    /// 兜底之三：应用失活。**走的是真的 `NotificationCenter` 通知**，
    /// 不是直接调 `release`——「观察者到底挂上没有」正是这条兜底会失效的地方。
    @Test("应用失活时释放")
    func releasesOnResignActive() {
        let (switcher, poster) = Self.makeSwitcher()
        let center = NotificationCenter()
        switcher.start(center: center)
        switcher.press(now: Self.base)
        #expect(switcher.isHolding)

        center.post(name: NSApplication.willResignActiveNotification, object: nil)
        #expect(!switcher.isHolding, "用户切走了，Command 还按着——之后他敲什么都是快捷键")
        #expect(poster.appSwitchSteps == [.commandDown, .tab, .commandUp])
        switcher.stop(center: center)
    }

    /// **不能靠「一次失活发了几个 Command 抬起」来验这条。**
    ///
    /// 释放是幂等的：挂两个观察者时，第一个释放、第二个空转，抬起还是只有
    /// 一个——那样写的断言在把 `guard` 删掉之后照样全绿（2026-08-22 变异
    /// 验证当场抓到的空断言）。
    ///
    /// 重复挂的真实伤害是**摘不掉**：`resignObserver` 只存得下最后一个，
    /// `stop()` 摘掉它之后，先挂的那个还留在 center 上一直响。所以这条从
    /// 「stop 之后还有没有人在响」来验。
    @Test("重复 start 不重复挂观察者")
    func startIsIdempotent() {
        let (switcher, _) = Self.makeSwitcher()
        let center = NotificationCenter()
        switcher.start(center: center)
        switcher.start(center: center)
        switcher.stop(center: center)

        switcher.press(now: Self.base)
        center.post(name: NSApplication.willResignActiveNotification, object: nil)
        #expect(switcher.isHolding,
                "start 挂了两个观察者，stop 只摘得掉最后一个——先挂的那个会一直响")
        switcher.release(reason: .shutdown)
    }

    /// 兜底之五：停止。摘掉观察者**并且**释放。
    @Test("stop 释放 Command，并且摘掉观察者")
    func stopReleasesAndRemovesObserver() {
        let (switcher, poster) = Self.makeSwitcher()
        let center = NotificationCenter()
        switcher.start(center: center)
        switcher.press(now: Self.base)
        switcher.stop(center: center)
        #expect(!switcher.isHolding)
        #expect(poster.appSwitchSteps == [.commandDown, .tab, .commandUp])

        // 观察者摘干净了：再发一次失活通知不该有任何动静
        switcher.press(now: Self.base.addingTimeInterval(10))
        center.post(name: NSApplication.willResignActiveNotification, object: nil)
        #expect(switcher.isHolding, "stop 之后观察者还挂着")
        switcher.release(reason: .shutdown)
    }

    /// 兜底之六：宿主析构。上面四条都没拦住时的最后一道。
    @Test("deinit 抬起还按着的 Command")
    func deinitReleasesCommand() {
        let poster = FakeKeyPoster()
        do {
            let switcher = AppSwitcher(
                poster: poster, timerInstaller: AppSwitcher.noTimerInstaller)
            switcher.press(now: Self.base)
            #expect(poster.appSwitchSteps == [.commandDown, .tab])
        }
        #expect(poster.appSwitchSteps == [.commandDown, .tab, .commandUp],
                "宿主没了，Command 还按着——用户的键盘从此全是快捷键，重启应用都解不掉")
    }

    /// 反过来：没按住时析构不该凭空发一个 Command 抬起。
    @Test("没按住时 deinit 什么都不发")
    func deinitEmitsNothingWhenNotHolding() {
        let poster = FakeKeyPoster()
        do {
            let switcher = AppSwitcher(
                poster: poster, timerInstaller: AppSwitcher.noTimerInstaller)
            switcher.press(now: Self.base)
            switcher.release(reason: .shutdown)
        }
        #expect(poster.appSwitchSteps == [.commandDown, .tab, .commandUp],
                "析构时又补了一个 Command 抬起")
    }

    /// **释放之后再按是新的一次会话**——听写打断、用户切走之后，
    /// 下一次按键必须重新唤出浮层，只补 Tab 是没有效果的。
    @Test("被打断后再按是新的一次会话")
    func pressAfterInterruptionStartsNewSession() {
        let (switcher, poster) = Self.makeSwitcher()
        switcher.press(now: Self.base)
        switcher.release(reason: .dictation)
        switcher.press(now: Self.base.addingTimeInterval(1))
        #expect(poster.appSwitchSteps == [.commandDown, .tab, .commandUp, .commandDown, .tab],
                "打断之后没有重新按下 Command，这一按什么都不会发生")
        switcher.release(reason: .shutdown)
    }

    @Test("幂等释放不会发出第二个 Command 抬起")
    func repeatedReleaseEmitsOnce() {
        let (switcher, poster) = Self.makeSwitcher()
        switcher.press(now: Self.base)
        switcher.release(reason: .dictation)
        switcher.release(reason: .resignActive)
        switcher.release(reason: .shutdown)
        #expect(poster.appSwitchSteps.filter { $0 == .commandUp }.count == 1,
                "重复释放发出了多个 Command 抬起：\(poster.appSwitchSteps)")
    }

    @Test("从没按过时释放什么都不发")
    func releaseWithoutSessionEmitsNothing() {
        let (switcher, poster) = Self.makeSwitcher()
        switcher.release(reason: .dictation)
        #expect(poster.appSwitchSteps.isEmpty, "凭空发了一个 Command 抬起")
        #expect(!switcher.isHolding)
    }

    @Test("tick 在没有会话时什么都不做")
    func tickWithoutSessionDoesNothing() {
        let (switcher, poster) = Self.makeSwitcher()
        switcher.tick(now: Self.base.addingTimeInterval(100))
        #expect(poster.appSwitchSteps.isEmpty)
    }
}
