import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// 吞掉遥控器「·」键在系统里留下的那一次原始按键，只留下我们注入的空格。
///
/// # 为什么需要它
///
/// 遥控器那个键的 usage 是 `0x35`（标准 Grave/Tilde），**系统会把它当普通
/// 按键正常投递**——中文输入法下就是用户今天看到的那个「·」。我们要把它变成
/// 空格键，于是必须两件事都做：注入真空格（`KeyPoster.postSpace`）＋ 吞掉
/// 原来那个「·」。少做后一件，用户会同时得到「·」和一个空格。
///
/// 这一点上它和关机键正相反：`0x66` 短按系统零投递，识别到直接注入就行，
/// **没有东西要拦**。
///
/// # 为什么是独立的一个 tap，而不是扩展 `RemoteKeySuppressor`
///
/// `RemoteKeySuppressor` 是**会话作用域**的：只在说话那几秒装 tap、吞键。
/// 本功能要求 tap 一直挂着（用户随时可能按那个键）。把它改成常开，等于
/// 让听写主路径上那段有事故史的代码换一种生命周期跑——`6a24f18` 修的正是
/// 它的 tap 生命周期野指针崩溃（四份崩溃报告见那边的注释）。
///
/// 分开写的收益很直接：**这里出问题最多是「·」不被吞掉，听写照常。**
/// 反过来合并的话，一次误吞就能把听写和用户的键盘一起带走。
/// `EventTapping` / `SystemEventTap` 那层抽象是共用的（定义在
/// `RemoteKeySuppressor.swift`），假 tap 的可测性也一并继承。
///
/// # 危险性与它的边界
///
/// 这是一个**常开的、看得见每一次按键的**系统级 tap。写错一个条件，
/// 用户自己的 `` ` `` 和 `~` 就没了（终端里的 `~`、中文输入法的「·」）。
/// 因此：
///
/// - 判定逻辑全部在 `decide` 这个**纯函数**里，`handle` 只负责搬运；
/// - 只在**武装窗口内**吞键，窗口外一律放行；
/// - keyCode 不是 `` ` `` 的事件**连状态都不碰**，直接放行；
/// - **不记录任何按键的键码。** 它看得见用户的全部输入，逐键记日志就是
///   键盘记录器。只在真吞掉的时候记一行。
@MainActor
final class GraveKeySwallower {
    /// 装 tap 的方式。返回 nil 表示没装成（缺辅助功能授权，或测试里刻意不装）。
    /// 形状与理由同 `RemoteKeySuppressor.TapInstaller`：真 tap 的 `userInfo`
    /// 必须是那个具体实例的指针，回调靠它找回宿主。
    typealias TapInstaller = @MainActor (GraveKeySwallower) -> (any EventTapping)?

    /// 生产用：真的装一个系统级 tap。
    static let systemInstaller: TapInstaller = { makeSystemTap(for: $0) }

    /// 测试用：什么都不装。**测试进程一律用这个**——理由（含四份 SIGSEGV
    /// 崩溃报告）见 `RemoteKeySuppressor.TapInstaller` 的注释。
    static let noTapInstaller: TapInstaller = { _ in nil }

    /// 「·」键的虚拟键码。`kVK_ANSI_Grave` == 50。
    ///
    /// 它同时是用户自己那个 `` ` `` / `~` 键——**这就是本文件全部的小心
    /// 都花在哪儿的原因**。无差别抑制 keyCode 50 会让终端里打不出 `~`。
    nonisolated static let graveKeyCode = Int64(kVK_ANSI_Grave)

    /// 相关窗口：HID 报文到达后多久之内的「·」算作它带出来的。
    ///
    /// **50 毫秒 = 实测间隔的 25 倍。** 实测来自 2026-08-21 的真机日志：
    /// 语音键的 HID 报文在 16:42:28.286 被处理（`遥控器按键 usage=0x3E`），
    /// 系统投递出的键盘事件在 16:42:28.288 才被事件 tap 看到
    /// （`会话期间按键 keyCode=96`）——**相差 2 毫秒**。
    ///
    /// 两条边都留了余量：
    /// - 往大了取，是因为那 2 毫秒是一次采样，机器忙的时候会拉长；
    /// - 不往更大了取，是因为窗口越长，越可能把用户**自己**按的
    ///   `` ` `` 误吞进去。50 毫秒内人手不可能补上一次真实按键。
    ///
    /// 顺带说明那 2 毫秒**已经包含了 `DispatchQueue.main.async` 那一跳**：
    /// 日志里 HID 那一行是在跳回主线程之后才写的，而 tap 那一行是在回调
    /// 里当场写的。所以「先武装、后吞键」这个顺序是被实测覆盖的，不是推断。
    nonisolated static let correlationWindow: TimeInterval = 0.050

    /// 吞键状态机的全部状态。
    struct State: Equatable, Sendable {
        /// 最近一次 HID 「·」键按下的时刻。nil 表示没武装。
        var armedAt: Date?
        /// 已经吞掉了一次按下沿，对应的松开沿也要吞。
        ///
        /// **不能只吞按下沿**：只吞一半的话，应用会收到一个没有配对按下的
        /// 松开事件。
        var awaitingKeyUp = false
    }

    /// 一次判断的结果：吞不吞，推进后的状态，以及一条诊断观测。
    struct Decision: Equatable, Sendable {
        var swallow: Bool
        var state: State
        /// 武装窗口内冒出了一个**不是** `` ` `` 的按下沿。
        ///
        /// **它是本功能唯一没被证据覆盖的那个假设的观测口。** 我们断定遥控器
        /// 那个键到了事件层是 keyCode 50，依据是「中文输入法下它打出「·」，
        /// 而「·」来自 Grave 键」——这是推断，不是日志。日志里从来没有出现过
        /// 一行 `keyCode=50`：`RemoteKeySuppressor` 的按键日志只在听写会话
        /// 期间才记，而用户按这个键的那几次都不在会话里。
        ///
        /// 万一它其实是别的键码，表现会是「空格出来了，「·」也还在」。
        /// 有了这条，日志会直接把真实键码写出来，不必再往返一轮真机侦察。
        ///
        /// **只在武装后的 50 毫秒内记，且只记按下沿。** 这个 tap 看得见用户的
        /// 全部输入，无条件记键码就是键盘记录器；限死在「用户刚按过遥控器」
        /// 那一瞬，记下的就只有遥控器自己带出来的东西。
        var observedWhileArmed = false
    }

    /// 这个事件该不该吞。**纯函数，本文件的全部判断力都在这里。**
    ///
    /// 抽成纯函数不是风格问题：`handle` 需要真实的 `CGEvent` 和真实的系统级
    /// tap，两样在测试进程里都造不出来（本仓库的约定，见
    /// `RemoteKeySuppressor.shouldSuppress`）。留在 `handle` 里就等于零覆盖，
    /// 而失效的表现是「用户的反引号键坏了」。
    ///
    /// 三条不变量，各有用例钉着：
    /// 1. keyCode 不是 50 → 放行，且**状态一个字节都不改**；
    /// 2. 是 50 但没武装 / 武装已过期 → 放行（这就是用户自己的 `` ` `` ）；
    /// 3. 是 50 且在窗口内 → 吞掉按下沿，并记住把配对的松开沿也吞掉。
    ///
    /// 无论命中与否，一次按下沿都会把武装**用掉**：遥控器按一次只该换来
    /// 一次空格，剩下的窗口不该继续吃后面的按键。
    nonisolated static func decide(
        keyCode: Int64,
        isKeyDown: Bool,
        now: Date,
        state: State,
        window: TimeInterval = correlationWindow
    ) -> Decision {
        // `elapsed >= 0` 不是多余的：系统时钟可能被 NTP 往回拨，
        // 那时 `elapsed` 为负而 `<= window` 恰好成立，等于武装了一个
        // 无限长的窗口——用户的反引号键会一直被吞。
        let inWindow = state.armedAt.map { armedAt in
            let elapsed = now.timeIntervalSince(armedAt)
            return elapsed >= 0 && elapsed <= window
        } ?? false

        guard keyCode == graveKeyCode else {
            // 不是「·」：**状态一个字节都不改**，只在武装窗口内留一条观测。
            return Decision(
                swallow: false, state: state,
                observedWhileArmed: inWindow && isKeyDown
            )
        }

        var next = state
        guard isKeyDown else {
            // 松开沿：只有在刚吞过配对的按下沿时才吞。
            guard state.awaitingKeyUp else { return Decision(swallow: false, state: state) }
            next.awaitingKeyUp = false
            return Decision(swallow: true, state: next)
        }

        next.armedAt = nil
        next.awaitingKeyUp = inWindow
        return Decision(swallow: inWindow, state: next)
    }

    private var state = State()

    /// 已装好的 tap。存 `EventTapping` 而不是裸 `CFMachPort`，
    /// 好让 `deinit` 够得着——理由见 `SystemEventTap` 的注释。
    private nonisolated(unsafe) var tapHandle: (any EventTapping)?

    private let installer: TapInstaller

    init(installer: @escaping TapInstaller = GraveKeySwallower.systemInstaller) {
        self.installer = installer
    }

    /// **tap 绝不能活得比宿主久。** 回调持的是 `passUnretained` 裸指针，
    /// 宿主先死就是野指针 → SIGSEGV。同 `RemoteKeySuppressor.deinit`，
    /// 那边有四份崩溃报告为证。
    deinit {
        tapHandle?.invalidate()
    }

    func start() {
        guard tapHandle == nil else { return }
        guard let tap = installer(self) else { return }
        tapHandle = tap
        AppLogger.shared.log("「·」键吞键器已启动")
    }

    func stop() {
        tapHandle?.invalidate()
        tapHandle = nil
        state = State()
    }

    /// 系统级 tap 现在装着没有。存在的唯一理由是让「测试不装真 tap」可测。
    var hasTap: Bool { tapHandle != nil }

    /// HID 层看到「·」键按下了：武装一次吞键。
    ///
    /// 窗口内的下一次 `` ` `` 按下会被吞掉；没有等到就自然过期。
    ///
    /// tap 尚未装上时在此重试，理由同 `RemoteKeySuppressor.beginSuppressing`：
    /// 开发期每次重新打包签名都变、TCC 授权随之重置，用户补授权后不必重启。
    func arm(now: Date = Date()) {
        if tapHandle == nil { start() }
        state.armedAt = now
    }

    /// 走一次判断并推进状态。`handle` 与单测共用这一个入口，
    /// 这样测到的状态机就是线上跑的那一个。
    @discardableResult
    func consume(keyCode: Int64, isKeyDown: Bool, now: Date = Date()) -> Decision {
        let decision = Self.decide(keyCode: keyCode, isKeyDown: isKeyDown, now: now, state: state)
        state = decision.state
        return decision
    }

    /// 真的去系统里装一个 tap。失败返回 nil。形状照 `RemoteKeySuppressor`。
    private static func makeSystemTap(for swallower: GraveKeySwallower) -> (any EventTapping)? {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)

        // `passUnretained`，不是 `passRetained`：retained 会让 tap 永久持有
        // 宿主、`deinit` 从此不跑，把崩溃换成静默泄漏。让 tap 先死才对。
        let context = Unmanaged.passUnretained(swallower).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let swallower = Unmanaged<GraveKeySwallower>
                    .fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    swallower.handle(type: type, event: event)
                }
            },
            userInfo: context
        ) else {
            // 需要辅助功能权限。没有也不阻断任何东西：空格照样注入，
            // 只是原来那个「·」也会一起进到应用里。如实记日志。
            AppLogger.shared.log("「·」键吞键器创建失败，按遥控器该键时会多出一个「·」")
            return nil
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            // 建不出 source 时必须把 tap 也拆掉，否则它挂在系统里而我们
            // 再也够不到它。
            CFMachPortInvalidate(tap)
            AppLogger.shared.log("「·」键吞键器的 run loop source 创建失败，已回滚")
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return SystemEventTap(tap: tap, source: source)
    }

    /// **本函数没有测试守着，明说。**
    ///
    /// 它要真 `CGEvent` 和真系统级 tap，两样都是本仓库禁止在测试里造的
    /// （理由见 `RemoteKeySuppressor.TapInstaller` 里那四份 SIGSEGV 崩溃
    /// 报告）。所以判断力全搬进了 `decide`/`consume`——**这里只许搬运，
    /// 不许判断**。2026-08-21 实测确认：把下面的 `postSpace` 目标键码改掉、
    /// 把诊断那一行删掉，1189 条用例全绿。改这几行的人得自己想清楚，
    /// 并且真机验一遍。
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统可能因超时或用户输入过快禁用 tap，重新启用。
        // **这一条不能省**：被禁用后不重开，用户就会开始看到「·」漏出来。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tapHandle?.setEnabled(true)
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let decision = consume(keyCode: keyCode, isKeyDown: type == .keyDown)

        // 诊断口，只在武装后的 50 毫秒内响一次。理由见 `Decision.observedWhileArmed`：
        // 「遥控器那个键到事件层是 keyCode 50」是全功能里唯一一条推断，
        // 它错了的话这行会把真实键码直接写出来。
        if decision.observedWhileArmed {
            AppLogger.shared.log("遥控器「·」键的武装窗口内出现 keyCode=\(keyCode)，不是 50，未吞")
        }

        guard decision.swallow else {
            return Unmanaged.passUnretained(event)
        }
        // **只在真吞掉时记一行，且不记任何别的键码。** 这个 tap 看得见
        // 用户的全部输入，逐键记日志就是键盘记录器。
        if type == .keyDown {
            AppLogger.shared.log("遥控器「·」键：已吞掉原始按键")
        }
        // 返回 nil 即吞掉该事件，不再投递给任何应用
        return nil
    }
}
