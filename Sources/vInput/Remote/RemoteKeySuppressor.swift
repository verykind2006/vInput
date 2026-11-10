import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// 在遥控器语音会话期间吞掉遥控器产生的虚假按键。
///
/// **为什么需要它：** RC003 的语音键不只走 BLE，它同时也是一个 HID 按键。
/// 按住说话的整个过程中，macOS 会把它当普通按键持续投递给前台应用，终端里
/// 表现为一长串转义序列。结果是输入框被按键垃圾填满，随后注入的文字被淹没
/// ——表现为「遥控器录音后没有文字」，而 ⌥D 一切正常。
///
/// 用 CGEvent tap 拦截并吞掉，只在语音会话期间生效，影响范围限于说话那几秒。
///
/// # 两种策略，因为两台设备的已知程度不同
///
/// M7 接入蓝牙鼠标时遇到同一个问题，但**鼠标语音键的键码没抓到**——上一轮
/// 扫描的 HID 报文只按 report ID 汇总了，没有逐 usage 展开。等用户再按一轮
/// 键来定这个数，会把整个里程碑卡在一次真机往返上。
///
/// 所以策略做成两档：
///
/// - `.only(...)`：只吞名单里的键。RC003 是 `[F5]`（实测）；
///   **鼠标 2026-08-20 起是空集**——不吞任何键，见 `mousePolicy`。
/// - `.allExcept(...)`：吞掉除逃生口以外的所有键。鼠标在键码未知的
///   M7 期间用过这一档（当时的取舍：「漏抑制」是功能坏掉、「多抑制」
///   只是几秒不便，不对称）；键码侦察完成后已退役，档位保留是因为
///   下一台新设备接入时仍会经历同样的「键码未知期」。
///
/// 会话期间每个按下沿都记日志（含键码与是否被抑制）。**鼠标的证据就是
/// 这条日志给的**（两轮真机：08-19 对照、08-20 全部按键与会话），
/// 新设备的键码同样靠它实测。
/// 一个装好的事件 tap 能做的两件事。
///
/// 抽成协议**只为一个理由：让「拆得干净」可测**。
/// 真 tap 是系统级的，测试进程一装就会留下能崩掉进程的野指针
/// （见 `RemoteKeySuppressor.TapInstaller`）；而「`stop()` 有没有真的
/// 拆掉」「`deinit` 有没有拆」这两件事恰恰是本文件修的那个 bug 本身。
/// 没有这层，那两条守卫在测试里是平凡成立的空断言——实测确认过：
/// 把 `stop()` 改成只 `setEnabled(false)`、把 `deinit` 整个删掉，
/// 12 条用例照样全绿。
protocol EventTapping: AnyObject {
    func invalidate()
    func setEnabled(_ enabled: Bool)
}

/// 已装好的**系统级**事件 tap，**持有权与拆除都不依赖 MainActor**。
///
/// 单独抽一个类型，唯一的理由是 `deinit` 必须够得着它。
/// `RemoteKeySuppressor` 是 `@MainActor` 的，而 `deinit` 是 nonisolated
/// ——把 `CFMachPort` 存成宿主的隔离属性，`deinit` 里就碰不到，
/// 而**碰不到就意味着拆不掉**，正是下面那个 bug 的成因。
///
/// 三个 CF 调用都是线程安全的 C API，不需要回到主线程。
final class SystemEventTap: EventTapping, @unchecked Sendable {
    private let tap: CFMachPort
    private let source: CFRunLoopSource
    private var invalidated = false

    init(tap: CFMachPort, source: CFRunLoopSource) {
        self.tap = tap
        self.source = source
    }

    /// 拆掉 tap。可重复调用。
    ///
    /// **`CFMachPortInvalidate` 不能省。** 只做 `tapEnable(false)` +
    /// `CFRunLoopRemoveSource` 的话，mach port 本身还活着，
    /// 系统仍可能把事件投递过来——而那时回调里的 `userInfo` 已经是野指针。
    ///
    /// **这三行没有测试守着，明说。** 假 tap 验的是协议契约
    /// （「`stop()` 与 `deinit` 有没有调 `invalidate()`」），验不了这里面
    /// 具体调了哪几个 CF 函数——要验就得装一个真的系统级 tap，
    /// 而那正是本轮要禁掉的事。实测确认过：把下面这行 `CFMachPortInvalidate`
    /// 删掉，13 条用例全绿。**改这三行的人得自己想清楚。**
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
    }

    func setEnabled(_ enabled: Bool) {
        guard !invalidated else { return }
        CGEvent.tapEnable(tap: tap, enable: enabled)
    }
}

@MainActor
final class RemoteKeySuppressor {
    /// 怎么装这个 tap。**默认装真的；测试传 `.disabled`。**
    ///
    /// **这个口子是一个真 bug 逼出来的（2026-08-19）。**
    /// `RemoteKeySuppressorTests` 的 11 条用例每条都 `beginSuppressing()`，
    /// 而它会调 `start()` 去装一个**系统级**的 CGEvent tap——测试结束、
    /// 对象释放，tap 却还挂在系统里，`userInfo` 指着已释放的内存。
    /// **下一次用户敲键盘，测试进程就 SIGSEGV。**
    /// 崩溃报告：08-18 17:01、08-18 23:00、08-19 11:06、08-19 11:07，
    /// 栈是 `__CFMachPortPerform → eventTapMessageHandler →
    /// closure #1 in start() → swift_retain`。
    ///
    /// 它间歇发生，是因为 tap 建不建得起来取决于测试二进制有没有辅助功能
    /// 授权，而临时签名每次构建都变、TCC 授权随之重置。
    /// **同一个根还有另一个已知后果**：测试曾真的往前台应用注入 Return 键
    /// （`SystemKeyPoster` 的默认值）。**测试不该跑真的系统副作用。**
    /// 装 tap 的方式。返回 nil 表示没装成（缺辅助功能授权，或测试里刻意不装）。
    /// **参数是宿主本身**：真 tap 的 `userInfo` 必须是那个具体实例的指针，
    /// 而回调正是靠它找回宿主的。
    typealias TapInstaller = @MainActor (RemoteKeySuppressor) -> (any EventTapping)?

    /// 生产用：真的装一个系统级 tap。
    static let systemInstaller: TapInstaller = { makeSystemTap(for: $0) }

    /// 测试用：什么都不装。
    static let noTapInstaller: TapInstaller = { _ in nil }

    /// 抑制策略。
    enum Policy: Equatable, Sendable {
        /// 只吞名单里的键。
        case only(Set<Int64>)
        /// 吞掉除名单以外的所有键。名单是逃生口。
        case allExcept(Set<Int64>)

        func suppresses(keyCode: Int64) -> Bool {
            switch self {
            case .only(let codes): return codes.contains(keyCode)
            case .allExcept(let codes): return !codes.contains(keyCode)
            }
        }
    }

    /// RC003 的策略。
    ///
    /// **F5 是真机实测得出的，不是推断。** 会话期间的按键日志显示语音键
    /// 产生 `keyCode=96`（F5）。这也说得通：F5 在 macOS 上是系统听写键，
    /// 遥控器把语音键映射到它是自然的选择。
    ///
    /// 只列实测到的键。多抑制一个键就多吞掉一次用户的真实按键——录音期间
    /// 想翻页是完全正常的操作。
    // nonisolated：它被用作 `beginSuppressing` 的默认参数值，
    // 而默认参数在调用方的隔离域里求值。
    nonisolated static let remotePolicy = Policy.only([Int64(kVK_F5)])

    /// 蓝牙鼠标的策略：**一个键都不吞**（2026-08-20 收窄）。
    ///
    /// 证据（两轮真机、逐日志核对）：鼠标的语音键、回车键、无用途键在
    /// 短按/长按/双击全部形态下**零键盘事件**——会话期间没有出现过一行
    /// keyCode 日志，而同期遥控器的 F5 每次都在。它的按键走 GATT 控制帧，
    /// 不走 HID 键盘，抑制没有对象。
    ///
    /// 收成 `.only([])` 而不是不装 tap：tap 挂着，按下沿日志就还在——
    /// 它是唯一的观测通道，哪天固件在某种没测到的形态下真冒出键盘事件，
    /// 日志会打出「抑制=false」的行，届时再决定要不要加名单。
    /// M7 那档 `.allExcept([Esc])` 的副作用（说话那几秒键盘不响应、
    /// 按 Esc 取消后键盘只剩 Esc 能用的那个 bug 的温床）随收窄一并消失。
    nonisolated static let mousePolicy = Policy.only([])

    /// 当前生效的策略。未在会话中时不生效（见 `isActive`）。
    private(set) var policy: Policy = RemoteKeySuppressor.remotePolicy

    /// 仅在语音会话进行中吞键。平时完全不干预用户的键盘。
    private var isActive = false

    /// 已装好的 tap。**存的是 `EventTapHandle` 而不是裸的 `CFMachPort`**，
    /// 这样 `deinit` 够得着它——理由见 `EventTapHandle` 的注释。
    ///
    /// `nonisolated(unsafe)`：只在 MainActor 上读写（`start` / `stop`
    /// 都是隔离方法），唯一的例外是 `deinit`，而那时已经没有别的引用了。
    private nonisolated(unsafe) var tapHandle: (any EventTapping)?

    private let installer: TapInstaller

    /// 卡死看门狗。理由见 `TapStallGuard`（2026-11-10 全系统键盘失灵事故）。
    /// `lazy`：它的 `onStall` 要回调 `self`。
    private(set) lazy var stallGuard = TapStallGuard(environment: stallEnvironment) { [weak self] in
        self?.recoverFromStall()
    }
    private let stallEnvironment: TapStallGuard.Environment

    init(
        installer: @escaping TapInstaller = RemoteKeySuppressor.systemInstaller,
        stallEnvironment: TapStallGuard.Environment = .system
    ) {
        self.installer = installer
        self.stallEnvironment = stallEnvironment
    }

    /// **tap 绝不能活得比宿主久。**
    ///
    /// 没有这个 `deinit` 时：对象释放后 tap 仍挂在系统里，回调拿着
    /// `Unmanaged.passUnretained(self)` 留下的裸指针去 `takeUnretainedValue()`
    /// 一块已释放的内存 → SIGSEGV。见 `TapInstaller` 的注释里那四份崩溃报告。
    ///
    /// **不改成 `passRetained` 来「保命」**：那会让 tap 永久持有宿主，
    /// `deinit` 从此不会被调用，泄漏一个系统级 tap——把崩溃换成静默泄漏，
    /// 而后者更难发现。正确的方向是让 tap 先死。
    deinit {
        tapHandle?.invalidate()
    }

    func start() {
        guard tapHandle == nil else { return }
        // 看门狗判过几次卡死、预算用完之后不再装：**键盘优先**。
        // 只有 `stop()`（遥控器整个停掉）才清账。
        guard !stallGuard.gaveUp else { return }
        guard let tap = installer(self) else { return }
        tapHandle = tap
        stallGuard.tapInstalled()
        AppLogger.shared.log("按键抑制器已启动")
    }

    /// 看门狗判定 tap 卡死：**先拆掉，键盘立刻回来**，再看预算决定重不重建。
    ///
    /// 拆这一步不看预算——卡死的拦截型 tap 留在系统里，用户整台机器就打不了字。
    func recoverFromStall() {
        tapHandle?.invalidate()
        tapHandle = nil
        stallGuard.tapRemoved()
        if stallGuard.recordRecovery() {
            AppLogger.shared.log(
                "按键抑制器卡死：系统收到了按键，回调超过 \(TapStallGuard.grace) 秒没看到，已拆掉重建"
                    + "（会话中=\(isActive)）")
            start()
        } else {
            AppLogger.shared.log(
                "按键抑制器卡死：\(Int(TapStallGuard.recoveryWindow)) 秒内已重建 "
                    + "\(TapStallGuard.maxRecoveries) 次，不再重建；遥控器录音期间可能出现杂键")
        }
    }

    /// 真的去系统里装一个 tap。失败返回 nil。
    private static func makeSystemTap(for suppressor: RemoteKeySuppressor) -> (any EventTapping)? {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)

        // **`passUnretained`，不是 `passRetained`。**
        // 用 retained 让 tap 替我们保命的话，宿主永远不会析构、`deinit`
        // 从此不跑，泄漏一个系统级 tap——把崩溃换成静默泄漏，更难发现。
        // 正确的方向是让 tap 先死，那由宿主的 `deinit` 保证。
        let context = Unmanaged.passUnretained(suppressor).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let suppressor = Unmanaged<RemoteKeySuppressor>
                    .fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    suppressor.handle(type: type, event: event)
                }
            },
            userInfo: context
        ) else {
            // 需要辅助功能权限。没有也不影响听写主路径，只是遥控器录音
            // 期间会有按键垃圾——如实记日志，不阻断。
            AppLogger.shared.log("按键抑制器创建失败，遥控器录音期间可能出现杂键")
            return nil
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            // 建不出 run loop source 时必须把 tap 也拆掉，否则它挂在系统里
            // 而我们再也够不到它。
            CFMachPortInvalidate(tap)
            AppLogger.shared.log("按键抑制器的 run loop source 创建失败，已回滚")
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return SystemEventTap(tap: tap, source: source)
    }

    func stop() {
        tapHandle?.invalidate()
        tapHandle = nil
        isActive = false
        stallGuard.reset()
    }

    /// 语音会话开始，开始吞键。
    ///
    /// 若 tap 尚未建立（通常是启动时还没拿到辅助功能权限）则在此重试——
    /// 开发期每次重新打包都会因签名变化而重置 TCC 授权，用户补授权后
    /// 不必重启应用。
    /// - Parameter policy: 本次会话用哪一档。默认是 RC003 那档，
    ///   这样遥控器那条路径的调用点一个字都不用改。
    func beginSuppressing(policy: Policy = RemoteKeySuppressor.remotePolicy) {
        if tapHandle == nil { start() }
        self.policy = policy
        isActive = true
    }

    /// 语音会话结束，恢复正常。
    func endSuppressing() {
        isActive = false
    }

    /// 跟着听写会话的状态自己收。**只收不开。**
    ///
    /// **这道是一个真 bug 逼出来的。** `AppModel` 的 `cancelHotkey.onCancel`
    /// 原来只调 `session.cancel()`：鼠标那档策略是 `.allExcept([Esc])`，
    /// 于是按 Esc 取消之后**整个键盘只剩 Esc 能用**，直到用户松开鼠标语音键
    /// （`0x22` 走 `onFinishSession` 才自愈）。RC003 那档是 `.only([F5])`，
    /// 这个不对称从来看不出来——第三个源把旧的缺口暴露了出来。
    /// 独立验收 2026-08-18 指出。
    ///
    /// 只在 `onCancel` 里补一次调用不够：**离开 `.listening` 的出口不止一个**
    /// （松开键、撞时长上限、转写失败、用户取消），每多一个出口就多一次忘记
    /// 的机会，而忘记的后果是用户的键盘从此不响应。挂到状态上以后，
    /// 「说完了就还给用户」这件事只有一个落点。形状照 `CancelHotkeyController`
    /// 的 `update(for:)`，两者管的是同一段时间窗。
    ///
    /// **不在 `.listening` 时打开**：⌥D 那条路从不 `beginSuppressing`
    /// （内置麦克风不产生杂键），而它同样会经过 `.listening`。
    /// 在这里顺手打开等于让用户用 ⌥D 说话时键盘莫名失灵。
    func update(for state: DictationSession.State) {
        guard state != .listening else { return }
        endSuppressing()
    }

    /// 系统级 tap 现在装着没有。**存在的唯一理由是让「测试不装真 tap」
    /// 这件事可测**——否则那道保护没有任何东西守着，而它失效的表现是
    /// 「跑完测试之后某次按键让测试进程崩掉」，没人会联想到这里。
    var hasTap: Bool { tapHandle != nil }

    /// 是否该吞掉这个键。抽成纯函数以便测试——`handle` 需要真实 CGEvent。
    ///
    /// 只在会话进行中吞键：平时用户按 F5 是他自己的意思，不该被我们截走。
    func shouldSuppress(keyCode: Int64) -> Bool {
        isActive && policy.suppresses(keyCode: keyCode)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统可能因超时或用户输入过快禁用 tap，重新启用。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tapHandle?.setEnabled(true)
            // 2026-11-10 事故前这里是静默的，事后查不出 tap 有没有被系统停过。
            AppLogger.shared.log(
                "按键抑制器被系统停用（\(type == .tapDisabledByTimeout ? "回调超时" : "用户输入")），已重新启用")
            return Unmanaged.passUnretained(event)
        }

        // 看门狗的对账依据。**在 `isActive` 之前**：平时也要对，
        // 2026-11-10 那次正是在不在会话里的时候把键盘吞了。
        if type == .keyDown { stallGuard.sawKeyDown() }

        guard isActive else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // 只在按下沿记录，否则自动重复会把日志刷爆
        if type == .keyDown, !isRepeat {
            // 这行日志是各设备键码的唯一观测通道——鼠标 2026-08-20 就是
            // 靠它证明零键盘事件后收窄成空集的。哪天这里冒出一行
            // 「抑制=false」的鼠标会话记录，说明固件在某种没测到的形态下
            // 会产生键盘事件，届时再决定要不要加名单。
            AppLogger.shared.log(
                "会话期间按键 keyCode=\(keyCode) 抑制=\(policy.suppresses(keyCode: keyCode))"
            )
        }

        guard shouldSuppress(keyCode: keyCode) else {
            return Unmanaged.passUnretained(event)
        }
        // 返回 nil 即吞掉该事件，不再投递给任何应用
        return nil
    }
}
