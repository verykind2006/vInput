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
@MainActor
final class RemoteKeySuppressor {
    /// 需要吞掉的键码。
    ///
    /// **F5 是真机实测得出的，不是推断。** 会话期间的按键日志显示语音键
    /// 产生 `keyCode=96`（F5）。这也说得通：F5 在 macOS 上是系统听写键，
    /// 遥控器把语音键映射到它是自然的选择。
    ///
    /// 只列实测到的键。多抑制一个键就多吞掉一次用户的真实按键——录音期间
    /// 想翻页是完全正常的操作。会话期间所有按键都记日志，若日后发现遗漏
    /// 可据此补充。
    private(set) var suppressedKeyCodes: Set<Int64> = [
        Int64(kVK_F5),
    ]

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
    func beginSuppressing() {
        if eventTap == nil { start() }
        isActive = true
    }

    /// 语音会话结束，恢复正常。
    func endSuppressing() {
        isActive = false
    }

    /// 是否该吞掉这个键。抽成纯函数以便测试——`handle` 需要真实 CGEvent。
    ///
    /// 只在会话进行中吞键：平时用户按 F5 是他自己的意思，不该被我们截走。
    func shouldSuppress(keyCode: Int64) -> Bool {
        isActive && suppressedKeyCodes.contains(keyCode)
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
            AppLogger.shared.log(
                "会话期间按键 keyCode=\(keyCode) 抑制=\(suppressedKeyCodes.contains(keyCode))"
            )
        }

        guard shouldSuppress(keyCode: keyCode) else {
            return Unmanaged.passUnretained(event)
        }
        // 返回 nil 即吞掉该事件，不再投递给任何应用
        return nil
    }
}
