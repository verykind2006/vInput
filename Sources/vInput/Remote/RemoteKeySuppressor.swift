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
/// - `.only(...)`：只吞名单里的键。用于 RC003，F5 是实测得出的。
/// - `.allExcept(...)`：吞掉除逃生口以外的所有键。用于鼠标——键码未知时，
///   「漏抑制」的后果是输入框被按键垃圾填满、注入的文字被淹没
///   （M3 在 RC003 上实测过的现象），而「多抑制」的后果只是说话那几秒里
///   键盘不响应。前者是功能坏掉，后者是几秒钟的不便，不对称。
///
/// **逃生口必须留。** `Esc` 是录音期间唯一的取消键
/// （`CancelHotkeyController` 只在 `.listening` 期间注册它），连它一起吞掉
/// 等于把用户关在一次录音里。鼠标按键本身不是键盘事件，这个 tap 只挂
/// `keyDown`/`keyUp`，所以点击与滚轮全程不受影响。
///
/// 会话期间每个按下沿都记日志（含键码与是否被抑制）。**鼠标那个键码就靠
/// 这条日志实测出来**——拿到之后应当把鼠标也收窄成 `.only(...)`。
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

    /// 蓝牙鼠标的策略。键码未知，先无条件抑制，只放行 `Esc`。
    nonisolated static let mousePolicy = Policy.allExcept([Int64(kVK_Escape)])

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

    init(installer: @escaping TapInstaller = RemoteKeySuppressor.systemInstaller) {
        self.installer = installer
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
        guard let tap = installer(self) else { return }
        tapHandle = tap
        AppLogger.shared.log("按键抑制器已启动")
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
            return Unmanaged.passUnretained(event)
        }

        guard isActive else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // 只在按下沿记录，否则自动重复会把日志刷爆
        if type == .keyDown, !isRepeat {
            // 鼠标那条路走的是「无条件抑制」，键码未知——这行日志就是把它
            // 实测出来的唯一途径。拿到之后应当收窄成 .only(...)。
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
