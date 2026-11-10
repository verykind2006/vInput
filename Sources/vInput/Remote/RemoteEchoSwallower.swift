import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// 吞掉遥控器按键在系统里留下的那一次「回声」——也就是系统自己投递出来的
/// 那个原始键盘事件——只留下我们注入的东西。
///
/// # 为什么需要它
///
/// 遥控器上有些键，系统**会把它当普通按键正常投递**：
///
/// - 「·」键的 usage 是 `0x35`（标准 Grave/Tilde），中文输入法下就是用户
///   看到的那个「·」。我们要把它变成空格；
/// - 菜单键的 usage 是 `0x65`（Keyboard Application），macOS 把它当
///   `kVK_ContextualMenu` 投递，表现就是用户说的「现在是唤醒菜单」。
///   我们要把它变成 Command+Tab。
///
/// 两者都必须两件事都做：注入我们要的东西 ＋ 吞掉原来那一下。少做后一件，
/// 用户会同时得到「·」和一个空格 / 同时得到「切了应用」和「弹出右键菜单」。
///
/// 这一点上它们和关机键正相反：`0x66` 短按系统零投递，识别到直接注入就行，
/// **没有东西要拦**。
///
/// # 为什么是独立的一个 tap，而不是扩展 `RemoteKeySuppressor`
///
/// `RemoteKeySuppressor` 是**会话作用域**的：只在说话那几秒装 tap、吞键。
/// 本功能要求 tap 一直挂着（用户随时可能按那几个键）。把它改成常开，等于
/// 让听写主路径上那段有事故史的代码换一种生命周期跑——`6a24f18` 修的正是
/// 它的 tap 生命周期野指针崩溃（四份崩溃报告见那边的注释）。
///
/// 分开写的收益很直接：**这里出问题最多是回声不被吞掉，听写照常。**
/// 反过来合并的话，一次误吞就能把听写和用户的键盘一起带走。
/// `EventTapping` / `SystemEventTap` 那层抽象是共用的（定义在
/// `RemoteKeySuppressor.swift`），假 tap 的可测性也一并继承。
///
/// # 为什么两个键共用一个吞键器（2026-08-22 加菜单键时定的）
///
/// 这是一个**常开的、看得见每一次按键的**系统级 tap。每多装一个，用户的
/// 每一次击键就多绕一跳 IPC，「tap 被系统禁用后要重开」这件事也多一份。
/// 而两个键的生命周期完全相同（跟着遥控器起、跟着遥控器收）、状态机也完全
/// 相同，没有任何把它们拆成两个 tap 的理由。于是状态里记的不再是「有没有
/// 武装」，而是**「为哪个键武装的」**（`State.armed`）。
///
/// # 危险性与它的边界
///
/// 写错一个条件，用户自己的 `` ` `` 和 `~` 就没了（终端里的 `~`、中文
/// 输入法的「·」）。因此：
///
/// - 判定逻辑全部在 `decide` 这个**纯函数**里，`handle` 只负责搬运；
/// - 只在**武装窗口内**吞键，窗口外一律放行；
/// - keyCode 不是当前武装那个键的事件**连状态都不碰**，直接放行；
/// - **不记录任何按键的键码。** 它看得见用户的全部输入，逐键记日志就是
///   键盘记录器。只在真吞掉的时候、以及武装窗口内那 50 毫秒里记。
@MainActor
final class RemoteEchoSwallower {
    /// 会产生回声、需要吞掉的遥控器按键。
    ///
    /// 每一项都是「HID usage → macOS 虚拟键码」这条链上**靠后**的那一段：
    /// usage 在 `HIDReportParser` 里，这里只管系统投递出来的键码。
    enum Key: String, CaseIterable, Sendable {
        /// 「·」键（usage `0x35`）→ 映射成空格。
        case grave
        /// 菜单键（usage `0x65`，Keyboard Application）→ 映射成 Command+Tab。
        case contextualMenu

        /// 系统投递这个键时用的虚拟键码。
        var keyCode: Int64 {
            switch self {
            case .grave:
                // `kVK_ANSI_Grave` == 50。它同时是用户自己那个 `` ` `` / `~`
                // 键——**这就是本文件全部的小心都花在哪儿的原因**。无差别
                // 抑制 keyCode 50 会让终端里打不出 `~`。
                //
                // 2026-08-22 实测确认这个推断是对的：真机日志里连着几十行
                // 「已吞掉原始按键」，同时用户的反引号键没有出过问题。
                Int64(kVK_ANSI_Grave)
            case .contextualMenu:
                // `kVK_ContextualMenu` == 0x6E == 110。
                //
                // **这一条是推断，不是实测——但不是猜。** 推理链：
                // 1. HID usage `0x65` 在键盘页里叫 Keyboard Application，
                //    也就是 PC 键盘上那个「菜单键」；
                // 2. 用户按它时看到的现象是**弹出右键菜单**
                //    （原话「现在是唤醒菜单」，2026-08-22）；
                // 3. macOS 把「弹右键菜单」这件事绑在 `kVK_ContextualMenu`
                //    上，而 Carbon 的 `Events.h` 里就有这个具名常量。
                //
                // 日志里**没有**一行能直接证明它：`0x65` 那九下（18:26–18:27）
                // 全都不在听写会话里，而按键抑制器只在会话期间记键码。
                // 兜底是 `Decision.observedWhileArmed` 那个诊断口——推断错了
                // 的话，真机日志会把真实键码直接写出来，改这一行即可。
                Int64(kVK_ContextualMenu)
            }
        }

        /// 日志里怎么称呼它。用户看日志时认的是这个，不是 usage。
        var label: String {
            switch self {
            case .grave: "「·」键"
            case .contextualMenu: "菜单键"
            }
        }
    }

    /// 装 tap 的方式。返回 nil 表示没装成（缺辅助功能授权，或测试里刻意不装）。
    /// 形状与理由同 `RemoteKeySuppressor.TapInstaller`：真 tap 的 `userInfo`
    /// 必须是那个具体实例的指针，回调靠它找回宿主。
    typealias TapInstaller = @MainActor (RemoteEchoSwallower) -> (any EventTapping)?

    /// 生产用：真的装一个系统级 tap。
    static let systemInstaller: TapInstaller = { makeSystemTap(for: $0) }

    /// 测试用：什么都不装。**测试进程一律用这个**——理由（含四份 SIGSEGV
    /// 崩溃报告）见 `RemoteKeySuppressor.TapInstaller` 的注释。
    static let noTapInstaller: TapInstaller = { _ in nil }

    /// 相关窗口：HID 报文到达后多久之内的那一下算作它带出来的回声。
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
        /// 当前为哪个键武装着。nil 表示没武装。
        var armed: Key?
        /// 最近一次 HID 按下的时刻。nil 表示没武装。
        var armedAt: Date?
        /// 已经吞掉了某个键的按下沿，对应的松开沿也要吞。
        ///
        /// **不能只吞按下沿**：只吞一半的话，应用会收到一个没有配对按下的
        /// 松开事件。**也不能只记一个 Bool**：两个键的键码不同，松开沿要认
        /// 键码才不会误吞另一个键的松开。
        var awaitingKeyUpFor: Key?
    }

    /// 一次判断的结果：吞不吞，推进后的状态，以及一条诊断观测。
    struct Decision: Equatable, Sendable {
        var swallow: Bool
        var state: State
        /// 真吞掉的是哪个键（只在 `swallow == true` 时有值），供日志用。
        var swallowed: Key?
        /// 武装窗口内冒出了一个**不是**目标键的按下沿；值是当时武装的那个键。
        ///
        /// **它是本功能里那条推断的观测口。** 「遥控器那个键到事件层是哪个
        /// 键码」这件事，日志从来没有直接写过：按键抑制器只在听写会话期间
        /// 记键码，而用户按这些键的时候都不在会话里。
        ///
        /// 万一某个键的键码推断错了，表现会是「我们注入的东西出来了，原来
        /// 那一下也还在」。有了这条，日志会直接把真实键码写出来，不必再往返
        /// 一轮真机侦察。
        ///
        /// **只在武装后的 50 毫秒内记，且只记按下沿。** 这个 tap 看得见用户的
        /// 全部输入，无条件记键码就是键盘记录器；限死在「用户刚按过遥控器」
        /// 那一瞬，记下的就只有遥控器自己带出来的东西，外加我们自己注入的
        /// 那一下（菜单键那路会看到一行 `keyCode=48`，那是我们发的 Tab，
        /// 属于预期噪声，同时也证明注入确实走到了事件层）。
        var observedWhileArmed: Key?
    }

    /// 这个事件该不该吞。**纯函数，本文件的全部判断力都在这里。**
    ///
    /// 抽成纯函数不是风格问题：`handle` 需要真实的 `CGEvent` 和真实的系统级
    /// tap，两样在测试进程里都造不出来（本仓库的约定，见
    /// `RemoteKeySuppressor.shouldSuppress`）。留在 `handle` 里就等于零覆盖，
    /// 而失效的表现是「用户的反引号键坏了」。
    ///
    /// 三条不变量，各有用例钉着：
    /// 1. keyCode 不是当前武装那个键 → 放行，且**状态一个字节都不改**；
    /// 2. 是它但没武装 / 武装已过期 → 放行（这就是用户自己的 `` ` `` ）；
    /// 3. 是它且在窗口内 → 吞掉按下沿，并记住把配对的松开沿也吞掉。
    ///
    /// 无论命中与否，一次按下沿都会把武装**用掉**：遥控器按一次只该换来
    /// 一次注入，剩下的窗口不该继续吃后面的按键。
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

        guard isKeyDown else {
            // 松开沿：只有在刚吞过**同一个键**的按下沿时才吞。
            // 不看窗口——按下沿吞了，配对的松开沿无论多晚都得跟着吞。
            guard let pending = state.awaitingKeyUpFor, pending.keyCode == keyCode else {
                return Decision(swallow: false, state: state)
            }
            var next = state
            next.awaitingKeyUpFor = nil
            return Decision(swallow: true, state: next, swallowed: pending)
        }

        guard let armed = state.armed, armed.keyCode == keyCode else {
            // 不是当前武装的那个键：**状态一个字节都不改**，
            // 只在武装窗口内留一条观测。
            return Decision(
                swallow: false, state: state,
                observedWhileArmed: inWindow ? state.armed : nil
            )
        }

        var next = state
        next.armed = nil
        next.armedAt = nil
        next.awaitingKeyUpFor = inWindow ? armed : nil
        return Decision(swallow: inWindow, state: next, swallowed: inWindow ? armed : nil)
    }

    private var state = State()

    /// 已装好的 tap。存 `EventTapping` 而不是裸 `CFMachPort`，
    /// 好让 `deinit` 够得着——理由见 `SystemEventTap` 的注释。
    private nonisolated(unsafe) var tapHandle: (any EventTapping)?

    private let installer: TapInstaller

    /// 卡死看门狗。**这个 tap 是常开的、看得见每一次按键**，它卡死就是
    /// 全系统键盘失灵——2026-11-10 的事故。理由见 `TapStallGuard`。
    private(set) lazy var stallGuard = TapStallGuard(environment: stallEnvironment) { [weak self] in
        self?.recoverFromStall()
    }
    private let stallEnvironment: TapStallGuard.Environment

    init(
        installer: @escaping TapInstaller = RemoteEchoSwallower.systemInstaller,
        stallEnvironment: TapStallGuard.Environment = .system
    ) {
        self.installer = installer
        self.stallEnvironment = stallEnvironment
    }

    /// **tap 绝不能活得比宿主久。** 回调持的是 `passUnretained` 裸指针，
    /// 宿主先死就是野指针 → SIGSEGV。同 `RemoteKeySuppressor.deinit`，
    /// 那边有四份崩溃报告为证。
    deinit {
        tapHandle?.invalidate()
    }

    func start() {
        guard tapHandle == nil else { return }
        // 预算用完就不再装，**键盘优先**；`stop()` 才清账。
        guard !stallGuard.gaveUp else { return }
        guard let tap = installer(self) else { return }
        tapHandle = tap
        stallGuard.tapInstalled()
        AppLogger.shared.log("遥控器回声吞键器已启动")
    }

    func stop() {
        tapHandle?.invalidate()
        tapHandle = nil
        state = State()
        stallGuard.reset()
    }

    /// 看门狗判定 tap 卡死：先拆（键盘立刻回来），再看预算重不重建。
    /// 同 `RemoteKeySuppressor.recoverFromStall`。
    func recoverFromStall() {
        tapHandle?.invalidate()
        tapHandle = nil
        state = State()
        stallGuard.tapRemoved()
        if stallGuard.recordRecovery() {
            AppLogger.shared.log(
                "遥控器回声吞键器卡死：系统收到了按键，回调超过 \(TapStallGuard.grace) 秒没看到，已拆掉重建")
            start()
        } else {
            AppLogger.shared.log(
                "遥控器回声吞键器卡死：\(Int(TapStallGuard.recoveryWindow)) 秒内已重建 "
                    + "\(TapStallGuard.maxRecoveries) 次，不再重建；「·」键与菜单键会多出一次原始按键")
        }
    }

    /// 系统级 tap 现在装着没有。存在的唯一理由是让「测试不装真 tap」可测。
    var hasTap: Bool { tapHandle != nil }

    /// HID 层看到某个键按下了：为它武装一次吞键。
    ///
    /// 窗口内的下一次同键码按下会被吞掉；没有等到就自然过期。
    ///
    /// tap 尚未装上时在此重试，理由同 `RemoteKeySuppressor.beginSuppressing`：
    /// 开发期每次重新打包签名都变、TCC 授权随之重置，用户补授权后不必重启。
    func arm(_ key: Key, now: Date = Date()) {
        if tapHandle == nil { start() }
        state.armed = key
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
    private static func makeSystemTap(for swallower: RemoteEchoSwallower) -> (any EventTapping)? {
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
                let swallower = Unmanaged<RemoteEchoSwallower>
                    .fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    swallower.handle(type: type, event: event)
                }
            },
            userInfo: context
        ) else {
            // 需要辅助功能权限。没有也不阻断任何东西：空格 / Command+Tab
            // 照样注入，只是原来那一下也会一起进到应用里。如实记日志。
            AppLogger.shared.log("遥控器回声吞键器创建失败，按这几个键时会多出一次原始按键")
            return nil
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            // 建不出 source 时必须把 tap 也拆掉，否则它挂在系统里而我们
            // 再也够不到它。
            CFMachPortInvalidate(tap)
            AppLogger.shared.log("遥控器回声吞键器的 run loop source 创建失败，已回滚")
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
    /// 不许判断**。2026-08-21 实测确认：把下面注入的目标键码改掉、
    /// 把诊断那一行删掉，1189 条用例全绿。改这几行的人得自己想清楚，
    /// 并且真机验一遍。
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统可能因超时或用户输入过快禁用 tap，重新启用。
        // **这一条不能省**：被禁用后不重开，用户就会开始看到「·」漏出来。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tapHandle?.setEnabled(true)
            AppLogger.shared.log(
                "遥控器回声吞键器被系统停用（\(type == .tapDisabledByTimeout ? "回调超时" : "用户输入")），已重新启用")
            return Unmanaged.passUnretained(event)
        }

        // 看门狗的对账依据。只记时间，不记键码（理由见类注释：不做键盘记录器）。
        if type == .keyDown { stallGuard.sawKeyDown() }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let decision = consume(keyCode: keyCode, isKeyDown: type == .keyDown)

        // 诊断口，只在武装后的 50 毫秒内响。理由见 `Decision.observedWhileArmed`：
        // 「遥控器那个键到事件层是哪个键码」是全功能里唯一一类推断，
        // 它错了的话这行会把真实键码直接写出来。
        if let armed = decision.observedWhileArmed {
            AppLogger.shared.log(
                "遥控器\(armed.label)的武装窗口内出现 keyCode=\(keyCode)，不是 \(armed.keyCode)，未吞"
            )
        }

        guard decision.swallow else {
            return Unmanaged.passUnretained(event)
        }
        // **只在真吞掉时记一行，且不记任何别的键码。** 这个 tap 看得见
        // 用户的全部输入，逐键记日志就是键盘记录器。
        if type == .keyDown, let swallowed = decision.swallowed {
            AppLogger.shared.log("遥控器\(swallowed.label)：已吞掉原始按键")
        }
        // 返回 nil 即吞掉该事件，不再投递给任何应用
        return nil
    }
}
