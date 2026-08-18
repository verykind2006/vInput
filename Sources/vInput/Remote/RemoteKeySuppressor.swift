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
@MainActor
final class RemoteKeySuppressor {
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

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()
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
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        AppLogger.shared.log("按键抑制器已启动")
    }

    func stop() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        self.eventTap = nil
        runLoopSource = nil
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
        if eventTap == nil { start() }
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

    /// 是否该吞掉这个键。抽成纯函数以便测试——`handle` 需要真实 CGEvent。
    ///
    /// 只在会话进行中吞键：平时用户按 F5 是他自己的意思，不该被我们截走。
    func shouldSuppress(keyCode: Int64) -> Bool {
        isActive && policy.suppresses(keyCode: keyCode)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统可能因超时或用户输入过快禁用 tap，重新启用。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
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
