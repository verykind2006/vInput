import AppKit
import Foundation

/// 应用切换器：把遥控器菜单键的每一次按下，攒成**一次按住 Command 的
/// 切换器会话**，让用户能在最近使用列表里连着往后翻。
///
/// # 为什么不能一次按一次松
///
/// 2026-08-22 真机验收：短按确实切到了上一个应用，但**只能在两个应用之间
/// 来回**。原因是每次都把 Command 松开了——macOS 一旦提交切换就重排 MRU，
/// 下一次按 Cmd+Tab 又从头开始，于是 Terminal ⇄ Finder 来回跳。
///
/// 用户要的是：Terminal → 按一下到 Finder → 再按一下到 Word → 再按一下
/// 回到 Terminal。那就必须让 Command **跨越多次按键一直按着**，浮层留在
/// 屏幕上、选中项一格一格前进，停手之后才提交。
///
/// # 一次会话长什么样
///
/// - 第一次按：`.commandDown` + `.tab` —— 浮层出现，选中项前进一格；
/// - 会话中再按：**只发 `.tab`**，Command 不重复按下 —— 再前进一格；
/// - 停手 `idleCommitDelay`（700 毫秒）无新按键：`.commandUp` —— 此刻才落地。
///
/// **代价是用户知情的**：单次按键不再立刻切换，浮层会停留那 0.7 秒才提交。
///
/// # 这个类唯一可能造成真实伤害的地方：卡住的 Command
///
/// 合成的 Command 长时间按住，一旦中途出岔子就会留下一个**按着的 Command**
/// ——之后用户敲什么都变成快捷键，而他既不知道发生了什么，也没法自己解除
/// （那不是物理按键，松开真键盘没用）。所以五道兜底，任何一条走到都释放：
///
/// 1. **停手** `idleCommitDelay` → 正常提交（`tick`）；
/// 2. **总时长封顶** `maxHold` 12 秒 → 无条件释放，哪怕用户还在连按
///    （`tick`，外加 `press` 里的防御性检查，防止计时器漏拍）；
/// 3. **应用失活** `NSApplication.willResignActiveNotification` → 释放；
/// 4. **听写开始** → 释放（现有的「听写中忽略这个键」守卫只挡新按键，
///    挡不住一个**已经按住**的 Command，见 `AppModel` 的 `onStateChange`）；
/// 5. **停止 / 退出 / 宿主析构** → 释放（`stop()` 与 `deinit`）。
///
/// `release(reason:)` 是**幂等**的：没按住时调它不发事件、不记日志。
/// 每一次释放都记原因，真机上万一卡住，日志能直接说出是哪条路没走到。
///
/// # 测得到 / 测不到
///
/// 状态推进与计时判断全在 `press` / `dueRelease` / `release` 三个**纯函数**
/// 里（时刻靠参数传进来，不读系统时钟），实例这一层靠 `tick(now:)` 驱动
/// ——形状照 `VoiceSessionKeepalive`：「生产环境由计时器调用；测试直接调用
/// 并传入构造的时刻」。真的发不发得出 `CGEvent`、切换器浮层认不认这套
/// 修饰键序列，只有真机能验。
@MainActor
final class AppSwitcher {
    /// 停手多久算「不再连按了，提交吧」。
    ///
    /// **700 毫秒是个取舍**：往小了取，用户还没来得及按第二下就提交了，
    /// 又退回「只能在两个应用间来回」；往大了取，每次切换都要干等，
    /// 按一下的手感就废了。700 毫秒够从容地按第二下，又不至于明显拖沓。
    /// 改这一行即可调。
    static let idleCommitDelay: TimeInterval = 0.700

    /// 按住 Command 的总时长上限。**到点无条件释放，哪怕用户还在连按。**
    ///
    /// 这是「卡住的修饰键」那条风险的硬底线：上面所有别的兜底都可能因为
    /// 某条路径没走到而失效，这一条只依赖计时器还在跑。碰到了，代价也只是
    /// 这一轮切换提前落地。
    ///
    /// **原本 5 秒，2026-08-22 真机实测后放到 12 秒。** 那次实测里用户六次
    /// 会话有三次连按到 16 下、一次 20 下（节奏约 190 毫秒一下），其中一次
    /// 撞上 5 秒被强制提交——也就是说「一口气按十几下」对这位用户是常态，
    /// 不是极端情况，而封顶纯粹是被按键次数撑到的，不是异常。12 秒按这个
    /// 节奏够连按六十下；真出岔子时 12 秒也远没到「用户会长期困惑」的程度。
    static let maxHold: TimeInterval = 12.0

    /// 计时器多久查一次。判断基于绝对时刻，不依赖 tick 的精确性
    /// （同 `VoiceSessionKeepalive.tick`），所以这个数只影响提交的粒度：
    /// 50 毫秒意味着实际提交落在 0.70–0.75 秒之间。计时器只在会话期间活着。
    static let tickInterval: TimeInterval = 0.050

    /// 一次释放是被哪条兜底触发的。**真机上卡住时靠它认路。**
    enum ReleaseReason: String, Sendable, CaseIterable {
        /// 停手 700 毫秒，正常提交。这是唯一「预期中」的那条。
        case idle = "停手"
        /// 撞上总时长封顶。
        case cap = "封顶"
        /// 本应用失活（用户切走了）。
        case resignActive = "应用失活"
        /// 听写开始了。
        case dictation = "听写介入"
        /// 遥控器停了 / 应用退出。
        case shutdown = "停止或退出"
        /// 宿主对象被析构。
        case deinitialized = "宿主析构"
    }

    /// 会话状态。**`holding == nil` 就是「Command 没按着」**，
    /// 两个字段同生同灭，不存在「按着但不知道何时开始」的中间态。
    struct State: Equatable, Sendable {
        struct Holding: Equatable, Sendable {
            /// Command 按下的时刻。封顶从这里算。
            var since: Date
            /// 最近一次按键的时刻。停手从这里算。
            var lastPressAt: Date
            /// 这次会话已经发了几个 Tab。只用于日志。
            var tabCount: Int
        }
        var holding: Holding?
    }

    /// 一次按键要发出去的按键序列。
    ///
    /// 用序列而不是「直接调 poster」，是为了让判断与副作用分开：
    /// 下面三个纯函数只算序列，实例那一层才真的发出去。
    nonisolated static func press(
        now: Date,
        state: State,
        maxHold: TimeInterval = maxHold
    ) -> (steps: [AppSwitchStep], state: State) {
        guard let holding = state.holding else {
            // 新会话：Command 按下 + 第一个 Tab。
            return (
                [.commandDown, .tab],
                State(holding: State.Holding(since: now, lastPressAt: now, tabCount: 1))
            )
        }

        // **防御性的封顶检查。** 正常情况下 `tick` 会先把会话收掉，这里
        // 不该命中；命中说明计时器漏拍了（主线程忙、或系统睡醒）。
        // `elapsed < 0` 一并收进来：系统时钟被 NTP 往回拨时，
        // 光靠 `>= maxHold` 会把封顶变成一个永远到不了的期限——
        // 那正是「Command 永远按着」。同 `RemoteEchoSwallower.decide`。
        let elapsed = now.timeIntervalSince(holding.since)
        guard elapsed >= 0, elapsed < maxHold else {
            return (
                [.commandUp, .commandDown, .tab],
                State(holding: State.Holding(since: now, lastPressAt: now, tabCount: 1))
            )
        }

        // 会话进行中：**只发 Tab**，Command 保持按住。
        var next = holding
        next.lastPressAt = now
        next.tabCount += 1
        return ([.tab], State(holding: next))
    }

    /// 这一刻该不该释放，以及是被哪条兜底逼的。nil 表示还不该。
    ///
    /// 封顶排在停手前面：两条同时到期（计时器漏拍）时，「按满了封顶」比
    /// 「停手 0.7 秒」更能说明当时发生了什么。
    nonisolated static func dueRelease(
        now: Date,
        state: State,
        idleDelay: TimeInterval = idleCommitDelay,
        maxHold: TimeInterval = maxHold
    ) -> ReleaseReason? {
        guard let holding = state.holding else { return nil }

        // 时钟往回拨时两个 elapsed 都会变负。这里与 `RemoteEchoSwallower`
        // 的取舍**方向相反**：那边负值意味着「别吞用户的键」，往安全的
        // 一侧倒是不吞；这边负值意味着「期限永远到不了」，往安全的一侧
        // 倒是**立刻释放**。卡住的 Command 比早一点提交严重得多。
        let held = now.timeIntervalSince(holding.since)
        if held < 0 || held >= maxHold { return .cap }

        let sinceLastPress = now.timeIntervalSince(holding.lastPressAt)
        if sinceLastPress < 0 || sinceLastPress >= idleDelay { return .idle }

        return nil
    }

    /// 释放要发的序列。**幂等**：没按住时返回空序列，状态不变。
    nonisolated static func release(state: State) -> (steps: [AppSwitchStep], state: State) {
        guard state.holding != nil else { return ([], state) }
        return ([.commandUp], State())
    }

    /// 可以被作废的周期性计时器。抽出来只为一件事：**测试进程不装真计时器**。
    ///
    /// 真的往主 run loop 上挂一个 0.05 秒的重复计时器，它会在别的用例跑到
    /// 一半时醒过来，把这个对象的状态改掉——同 `RemoteEchoSwallower.TapInstaller`
    /// 那条规矩（那边是四份 SIGSEGV 崩溃报告换来的）。
    protocol Ticking: AnyObject {
        func invalidate()
    }

    /// 装计时器的方式。返回 nil 表示没装（测试里刻意不装）。
    typealias TimerInstaller = @MainActor (AppSwitcher) -> (any Ticking)?

    /// 生产用：真的挂一个重复计时器。
    static let systemTimerInstaller: TimerInstaller = { switcher in
        Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak switcher] _ in
            Task { @MainActor [weak switcher] in
                switcher?.tick(now: Date())
            }
        }
    }

    /// 测试用：什么都不装，`tick(now:)` 由用例自己按构造的时刻调。
    static let noTimerInstaller: TimerInstaller = { _ in nil }

    private let poster: KeyPoster
    private let timerInstaller: TimerInstaller
    private var state = State()
    private var timer: (any Ticking)?
    private var resignObserver: NSObjectProtocol?

    /// **`deinit` 够得着的那一份「Command 现在按着没有」。**
    ///
    /// `deinit` 是 nonisolated 的，够不着 `MainActor` 隔离的 `state`，
    /// 而「宿主没了但 Command 还按着」正是最坏的一种卡住——用户的键盘从此
    /// 全是快捷键，重启应用都解不掉（那个修饰键状态在 WindowServer 里）。
    /// 所以镜像一份。写法与理由同 `RemoteEchoSwallower.tapHandle`。
    ///
    /// **它只在两处写：`apply(steps:)` 里跟着真实发出去的事件走。**
    private nonisolated(unsafe) var commandIsDown = false

    init(
        poster: KeyPoster,
        timerInstaller: @escaping TimerInstaller = AppSwitcher.systemTimerInstaller
    ) {
        self.poster = poster
        self.timerInstaller = timerInstaller
    }

    /// 兜底之五：宿主析构。走到这里说明上面四条都没拦住，如实记一行。
    deinit {
        guard commandIsDown else { return }
        poster.postAppSwitch(.commandUp)
        AppLogger.shared.log(
            "应用切换器：Command 抬起（原因=\(ReleaseReason.deinitialized.rawValue)）")
    }

    /// 挂上「应用失活就释放」这条兜底。
    ///
    /// **`queue: nil` 是刻意的**（`ForegroundAppTracker` 那边用的是 `.main`）：
    /// nil 表示在**投递通知的那个线程上同步**跑，AppKit 的失活通知本来就在
    /// 主线程投递，于是这条兜底是**立刻**执行的。排进队列的话，「释放」会
    /// 排在用户切走之后的某个时刻——而这条兜底存在的意义正是不让那段时间
    /// 里留着一个按住的 Command。同步执行也让它在测试里可判定。
    func start(center: NotificationCenter = NotificationCenter.default) {
        guard resignObserver == nil else { return }
        resignObserver = center.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.release(reason: .resignActive)
            }
        }
    }

    /// 摘掉观察者并释放。跟着遥控器那条路一起收（`AppModel.stopRemote`）。
    func stop(center: NotificationCenter = NotificationCenter.default) {
        if let resignObserver {
            center.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        release(reason: .shutdown)
    }

    /// Command 现在按着没有。给测试与日志用。
    var isHolding: Bool { state.holding != nil }

    /// 这次会话已经发了几个 Tab。
    var tabCount: Int { state.holding?.tabCount ?? 0 }

    /// 菜单键按了一下：开一次会话，或在已有会话里再前进一格。
    func press(now: Date = Date()) {
        let result = Self.press(now: now, state: state)
        state = result.state
        apply(steps: result.steps)

        if result.steps.contains(.commandDown) {
            AppLogger.shared.log("应用切换器：Command 按下，会话开始")
        }
        AppLogger.shared.log("应用切换器：第 \(tabCount) 次 Tab")
        startTimerIfNeeded()
    }

    /// 生产环境由计时器每 `tickInterval` 调一次；测试直接调用并传入构造的时刻。
    func tick(now: Date) {
        guard let reason = Self.dueRelease(now: now, state: state) else { return }
        release(reason: reason, now: now)
    }

    /// 释放 Command。**幂等**：没按住时什么都不做，不发事件也不记日志。
    func release(reason: ReleaseReason, now: Date = Date()) {
        let held = state.holding
        let result = Self.release(state: state)
        state = result.state
        stopTimer()
        guard !result.steps.isEmpty else { return }
        apply(steps: result.steps)

        let seconds = held.map { String(format: "%.2f", now.timeIntervalSince($0.since)) } ?? "?"
        AppLogger.shared.log(
            "应用切换器：Command 抬起（原因=\(reason.rawValue)，"
                + "共 \(held?.tabCount ?? 0) 次 Tab，按住 \(seconds) 秒）")
    }

    /// 真的把按键发出去，并同步 `deinit` 用的那面镜子。
    ///
    /// **镜子必须跟着这里走，不能跟着 `state` 走**：`state` 是判断的结果，
    /// 这里才是「事件真的发出去了」。
    private func apply(steps: [AppSwitchStep]) {
        for step in steps {
            poster.postAppSwitch(step)
            switch step {
            case .commandDown: commandIsDown = true
            case .commandUp: commandIsDown = false
            case .tab: break
            }
        }
    }

    /// 计时器现在挂着没有。存在的唯一理由是让「测试不装真计时器」可测。
    var hasTimer: Bool { timer != nil }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        timer = timerInstaller(self)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// `Timer` 本来就有 `invalidate()`，直接认领这个协议即可。
extension Timer: AppSwitcher.Ticking {}
