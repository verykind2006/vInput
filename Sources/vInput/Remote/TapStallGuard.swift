import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// 常开事件 tap 的看门狗：**系统看到了按键、我们的回调却迟迟没看到，
/// 就判定 tap 卡死，交给宿主拆掉。**
///
/// # 为什么需要它（2026-11-10 事故）
///
/// Mac mini 上 vInput 连续跑了约 37 小时后，**全系统键盘失灵**：本机蓝牙
/// 键盘、VNC 远程打字都没反应，鼠标正常；`quit app "vInput"` 之后立刻恢复。
/// 事故记录在 `docs/BUG-2026-11-10-键盘输入被吞.md`，系统日志核对的结论：
///
/// - 按键**进了系统**：Siri 的热键监听在 HID 层，事故期间它照样收到了
///   K580 和 VNC 的按键；它在我们的 tap **上游**（它看得到被我们吞掉的 F5）。
/// - 按键**没到终端**：键盘焦点一直在终端（WindowServer 的焦点记录为证）。
/// - 夹在中间、且退出 vInput 就消失的，只有我们那两个挂在会话层、
///   `.defaultTap`（能拦截）的常开 tap。
/// - 从 10:30:50 起，按键抑制器的回调**再也没见过遥控器的 F5**——此前
///   122 次遥控器会话每次都有那行 `会话期间按键 keyCode=96`。
///
/// **回调为什么不再被调用，没有查实。** 回调的每个分支都放行事件，主线程
/// 也活着（能处理退出的 AppleEvent）。所以这里不赌根因，赌结果：
/// 一个拦截型 tap 一旦不再正常收事件，最坏的后果是吞掉整台机器的键盘，
/// 而这件事**可以从外面量出来**。
///
/// # 怎么量
///
/// `CGEventSource.secondsSinceLastEventType(.combinedSessionState, .keyDown)`
/// 问的是系统「最近一次按键是什么时候」，**不经过我们的 tap**。我们的回调
/// 每见到一个按下沿就记一次时间。系统那边有一次按键、我们这边超过
/// `grace` 秒还没对上，就是卡死（或者被系统停用了而我们没收到通知——
/// 那种情况拆掉重建同样是对的）。
///
/// 健康时回调在几毫秒内就会看到同一次按键，对不上的窗口不会超过一个
/// 检查周期。唯一已知的正常例外是**安全输入**（密码框）：开着时 tap 本来
/// 就收不到按键，所以那时不判。
@MainActor
final class TapStallGuard {
    /// 系统按键之后多久还没对上，判卡死。
    ///
    /// 2 秒：远长于健康回调的毫秒级延迟，又短到用户察觉「键盘没反应」时
    /// 基本已经恢复。判错的代价只是拆掉重建一次 tap（几毫秒），
    /// 判晚的代价是整台机器没法打字，不对称，往短了取。
    nonisolated static let grace: TimeInterval = 2.0

    /// 系统时间与回调时间之间的容差。两边的时钟来源不同
    /// （一个是 WindowServer 的事件时间戳推算，一个是回调里读的 uptime），
    /// 留 0.25 秒避免同一次按键因为几毫秒的差被当成「没对上」。
    nonisolated static let slack: TimeInterval = 0.25

    /// 多久查一次。
    nonisolated static let checkInterval: TimeInterval = 0.5

    /// 这么长时间内最多重建几次；超了就不再重建，**键盘优先**。
    nonisolated static let maxRecoveries = 3
    nonisolated static let recoveryWindow: TimeInterval = 300

    /// 纯状态机。**判断力全在这里**，宿主与计时器只负责搬运。
    struct Detector: Equatable, Sendable {
        /// 第一次发现「系统有、我们没有」的时刻。nil 表示当前对得上。
        private(set) var unseenSince: TimeInterval?

        /// 查一次。返回 true 表示判定卡死（同时清掉内部状态，
        /// 宿主重建 tap 后从头再计）。
        ///
        /// - Parameters:
        ///   - now: 当前时刻（uptime）。
        ///   - systemLastKeyDown: 系统最近一次按下沿的时刻（uptime）。
        ///   - tapLastKeyDown: 我们的回调最近一次见到按下沿的时刻，nil 表示还没见过。
        ///   - tapInstalledAt: tap 装上的时刻。**装之前的按键不算**——
        ///     刚启动时系统里那次「最近按键」可能是几小时前的。
        ///   - secureInput: 安全输入开着没有。开着时 tap 收不到按键是正常的。
        mutating func check(
            now: TimeInterval,
            systemLastKeyDown: TimeInterval,
            tapLastKeyDown: TimeInterval?,
            tapInstalledAt: TimeInterval,
            secureInput: Bool,
            grace: TimeInterval = TapStallGuard.grace,
            slack: TimeInterval = TapStallGuard.slack
        ) -> Bool {
            let unseen = !secureInput
                && systemLastKeyDown > tapInstalledAt + slack
                && systemLastKeyDown > (tapLastKeyDown ?? -.infinity) + slack
            guard unseen else {
                unseenSince = nil
                return false
            }
            guard let since = unseenSince else {
                unseenSince = now
                return false
            }
            // `now < since` 是时钟回拨之类的异常，当作重新起算，不判。
            guard now >= since else {
                unseenSince = now
                return false
            }
            guard now - since >= grace else { return false }
            unseenSince = nil
            return true
        }
    }

    /// 重建预算：`window` 秒内最多 `limit` 次。纯函数，单测直接钉。
    nonisolated static func mayRecover(
        now: TimeInterval,
        previous: [TimeInterval],
        limit: Int = maxRecoveries,
        window: TimeInterval = recoveryWindow
    ) -> Bool {
        previous.filter { now - $0 < window }.count < limit
    }

    /// 读系统状态与时间的口子。**生产用 `.system`；测试传手动的。**
    struct Environment {
        var now: @MainActor () -> TimeInterval
        var systemLastKeyDown: @MainActor () -> TimeInterval
        var secureInput: @MainActor () -> Bool
        var installTimer: @MainActor (TapStallGuard) -> (any AppSwitcher.Ticking)?

        static let system = Environment(
            now: { ProcessInfo.processInfo.systemUptime },
            systemLastKeyDown: {
                ProcessInfo.processInfo.systemUptime
                    - CGEventSource.secondsSinceLastEventType(
                        .combinedSessionState, eventType: .keyDown)
            },
            secureInput: { IsSecureEventInputEnabled() },
            installTimer: { guardian in
                Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) {
                    [weak guardian] _ in
                    Task { @MainActor [weak guardian] in guardian?.check() }
                }
            }
        )

        /// 测试用：不装计时器、不碰系统，时间与按键全由调用方喂。
        static func manual(
            now: @escaping @MainActor () -> TimeInterval,
            systemLastKeyDown: @escaping @MainActor () -> TimeInterval,
            secureInput: @escaping @MainActor () -> Bool = { false }
        ) -> Environment {
            Environment(
                now: now, systemLastKeyDown: systemLastKeyDown,
                secureInput: secureInput, installTimer: { _ in nil })
        }
    }

    private let env: Environment
    private let onStall: @MainActor () -> Void
    private var detector = Detector()
    private var installedAt: TimeInterval?
    private var lastKeyDownSeenAt: TimeInterval?
    private var recoveries: [TimeInterval] = []
    /// `deinit` 要够得着它（同 `RemoteKeySuppressor.tapHandle` 的理由）。
    private nonisolated(unsafe) var timer: (any AppSwitcher.Ticking)?

    /// 预算用完、已经不再重建了。宿主据此拒绝再装 tap，直到 `reset()`。
    private(set) var gaveUp = false

    init(environment: Environment = .system, onStall: @escaping @MainActor () -> Void) {
        self.env = environment
        self.onStall = onStall
    }

    deinit {
        timer?.invalidate()
    }

    /// tap 刚装上。开始计时，之前的按键一律不算。
    func tapInstalled() {
        installedAt = env.now()
        lastKeyDownSeenAt = nil
        detector = Detector()
        if timer == nil { timer = env.installTimer(self) }
    }

    /// tap 拆掉了。停表。
    func tapRemoved() {
        installedAt = nil
        detector = Detector()
        timer?.invalidate()
        timer = nil
    }

    /// 回调见到了一个按下沿。**在回调里调，只读一次时钟，别的什么都不做。**
    func sawKeyDown() {
        lastKeyDownSeenAt = env.now()
    }

    /// 查一次；判定卡死就通知宿主。计时器每 `checkInterval` 调一次，测试直接调。
    func check() {
        guard let installedAt else { return }
        let stalled = detector.check(
            now: env.now(),
            systemLastKeyDown: env.systemLastKeyDown(),
            tapLastKeyDown: lastKeyDownSeenAt,
            tapInstalledAt: installedAt,
            secureInput: env.secureInput()
        )
        if stalled { onStall() }
    }

    /// 宿主拆掉卡死的 tap 之后问一句：还能重建吗？
    /// 能就记一笔并返回 true；预算用完返回 false，并从此 `gaveUp`。
    func recordRecovery() -> Bool {
        let now = env.now()
        guard Self.mayRecover(now: now, previous: recoveries) else {
            gaveUp = true
            return false
        }
        recoveries = recoveries.filter { now - $0 < Self.recoveryWindow } + [now]
        return true
    }

    /// 宿主整个停掉（遥控器断开等）时清账，下次 `start()` 从头来。
    func reset() {
        tapRemoved()
        recoveries = []
        gaveUp = false
    }
}
