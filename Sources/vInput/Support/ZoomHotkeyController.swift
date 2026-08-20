import Carbon.HIToolbox
import Foundation

/// 缩放热键的注册能力。抽协议以便测试注册时机（与 CancelHotkeyRegistering 同型）。
@MainActor
protocol ZoomHotkeyRegistering: AnyObject {
    func registerZoomKeys(
        increase: @escaping () -> Void,
        decrease: @escaping () -> Void,
        reset: @escaping () -> Void
    ) throws
    func unregisterZoomKeys()
}

/// 用 Carbon 注册 ⌘=（键帽上的 ⌘＋，不带 shift）、⌘-、⌘0。
///
/// `kVK_ANSI_*` 是**物理键位**码：非 ANSI 布局（如 AZERTY）上 ⌘= 落在
/// 别的键帽上。Carbon 全局热键天然按键位走，这里只记录这个局限，不做映射。
@MainActor
final class CarbonZoomHotkeyRegistrar: ZoomHotkeyRegistering {
    private let increaseRegistrar = HotkeyRegistrar()
    private let decreaseRegistrar = HotkeyRegistrar()
    private let resetRegistrar = HotkeyRegistrar()

    func registerZoomKeys(
        increase: @escaping () -> Void,
        decrease: @escaping () -> Void,
        reset: @escaping () -> Void
    ) throws {
        // 三个一起成、一起败：部分注册会造成「＋能用－不能用」这种没法解释的状态。
        do {
            try increaseRegistrar.register(
                keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(cmdKey), handler: increase)
            try decreaseRegistrar.register(
                keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(cmdKey), handler: decrease)
            try resetRegistrar.register(
                keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(cmdKey), handler: reset)
        } catch {
            unregisterZoomKeys()
            throw error
        }
    }

    func unregisterZoomKeys() {
        increaseRegistrar.unregister()
        decreaseRegistrar.unregister()
        resetRegistrar.unregister()
    }
}

/// 按会话状态管理缩放热键：**会话进行中（非 idle）时注册**。
///
/// ⌘＋/⌘－ 是各应用的高频缩放键，长期占用等于劫持——注册窗口必须
/// 收窄到用户正对着 HUD 的那几秒（与 CancelHotkeyController 同一条哲学，
/// 只是窗口从 .listening 放宽到整个会话：转写/翻译阶段用户也在看预览文字）。
///
/// 注意「非 idle」≠「HUD 可见」：idle 后 HUD 还会带附注停留几秒
/// （`AppModel.endHUD` 的 linger），那几秒里 ⌘± 已交还前台应用——
/// 这是故意的（用户此刻人已回到自己的应用里），不是漏注册。
@MainActor
final class ZoomHotkeyController {
    var onIncrease: (() -> Void)?
    var onDecrease: (() -> Void)?
    var onReset: (() -> Void)?

    private let registrar: ZoomHotkeyRegistering
    private var isRegistered = false

    init(registrar: ZoomHotkeyRegistering) {
        self.registrar = registrar
    }

    /// 会话状态变化时调用。
    ///
    /// 不向调用方抛错：⌘± 注册失败不该阻断录音，用户只是少了调字号的手段。
    func update(for state: DictationSession.State) {
        if state != .idle {
            guard !isRegistered else { return }
            do {
                try registrar.registerZoomKeys(
                    increase: { [weak self] in self?.onIncrease?() },
                    decrease: { [weak self] in self?.onDecrease?() },
                    reset: { [weak self] in self?.onReset?() }
                )
            } catch {
                AppLogger.shared.log("缩放热键注册失败，本次会话无法用 ⌘± 调字号：\(error)")
            }
            // 失败也置位：避免每次状态推进都重试刷屏。离开会话时注销是幂等的。
            isRegistered = true
        } else {
            guard isRegistered else { return }
            registrar.unregisterZoomKeys()
            isRegistered = false
        }
    }
}
