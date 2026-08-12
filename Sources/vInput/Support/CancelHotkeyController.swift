import Carbon.HIToolbox
import Foundation

/// 取消热键的注册能力。抽成协议以便测试注册时机。
@MainActor
protocol CancelHotkeyRegistering: AnyObject {
    func registerCancelKey(handler: @escaping () -> Void) throws
    func unregisterCancelKey()
}

/// 用 Carbon 注册 `Esc` 作为取消键。
@MainActor
final class EscHotkeyRegistrar: CancelHotkeyRegistering {
    private let registrar = HotkeyRegistrar()

    func registerCancelKey(handler: @escaping () -> Void) throws {
        // 无修饰键的 Esc。仅在录音期间注册，见 CancelHotkeyController。
        try registrar.register(keyCode: UInt32(kVK_Escape), modifiers: 0, handler: handler)
    }

    func unregisterCancelKey() {
        registrar.unregister()
    }
}

/// 按会话状态管理取消热键的注册与注销。
///
/// `Esc` 是高频键，长期占用会干扰其他应用——因此**只在录音期间注册**，
/// 一离开 `.listening` 立即注销，影响范围限于说话的那几秒。
@MainActor
final class CancelHotkeyController {
    var onCancel: (() -> Void)?

    private let registrar: CancelHotkeyRegistering
    private var isRegistered = false

    init(registrar: CancelHotkeyRegistering) {
        self.registrar = registrar
    }

    /// 会话状态变化时调用。
    ///
    /// 不向调用方抛错：`Esc` 注册失败不该阻断录音，⌥D 仍能正常结束会话。
    func update(for state: DictationSession.State) {
        if state == .listening {
            guard !isRegistered else { return }
            do {
                try registrar.registerCancelKey { [weak self] in
                    self?.onCancel?()
                }
            } catch {
                AppLogger.shared.log("取消热键注册失败，本次录音无法用 Esc 取消：\(error)")
            }
            // 失败也置位：否则每次状态变化都会重试并刷屏日志。
            // 离开 listening 时仍会调用 unregisterCancelKey()，那是幂等的。
            isRegistered = true
        } else {
            guard isRegistered else { return }
            registrar.unregisterCancelKey()
            isRegistered = false
        }
    }
}
