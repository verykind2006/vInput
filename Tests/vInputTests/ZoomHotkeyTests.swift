import Foundation
import Testing

@testable import vInput

@MainActor
private final class FakeZoomRegistrar: ZoomHotkeyRegistering {
    var registered = false
    var registerCount = 0
    var increase: (() -> Void)?
    var decrease: (() -> Void)?
    var reset: (() -> Void)?

    func registerZoomKeys(
        increase: @escaping () -> Void,
        decrease: @escaping () -> Void,
        reset: @escaping () -> Void
    ) throws {
        registered = true
        registerCount += 1
        self.increase = increase
        self.decrease = decrease
        self.reset = reset
    }

    func unregisterZoomKeys() { registered = false }
}

@MainActor
private final class ThrowingZoomRegistrar: ZoomHotkeyRegistering {
    func registerZoomKeys(
        increase: @escaping () -> Void,
        decrease: @escaping () -> Void,
        reset: @escaping () -> Void
    ) throws { throw HotkeyError.registrationFailed(-1) }
    func unregisterZoomKeys() {}
}

/// ⌘±/⌘0 仅在 HUD 可见（会话非 idle）时注册——平时不碰别的应用的缩放键。
@MainActor
struct ZoomHotkeyTests {
    @Test func registersWhenSessionActiveOnly() {
        let registrar = FakeZoomRegistrar()
        let controller = ZoomHotkeyController(registrar: registrar)
        #expect(!registrar.registered)

        controller.update(for: .listening)
        #expect(registrar.registered)

        // 会话中段的状态推进不反复注册。
        controller.update(for: .transcribing)
        controller.update(for: .injecting)
        #expect(registrar.registerCount == 1)

        controller.update(for: .idle)
        #expect(!registrar.registered)
    }

    /// `.transcribing`/`.correcting`/`.translating`/`.injecting` 单独进来
    /// （不经过 `.listening`，例如「重试上次转写」那条路径）也要注册——
    /// 判据是「非 idle」而不是「等于 listening」。
    @Test func registersOnNonListeningNonIdleStateAlone() {
        let registrar = FakeZoomRegistrar()
        let controller = ZoomHotkeyController(registrar: registrar)
        controller.update(for: .transcribing)
        #expect(registrar.registered)
    }

    @Test func forwardsAllThreeKeys() {
        let registrar = FakeZoomRegistrar()
        let controller = ZoomHotkeyController(registrar: registrar)
        var log: [String] = []
        controller.onIncrease = { log.append("+") }
        controller.onDecrease = { log.append("-") }
        controller.onReset = { log.append("0") }

        controller.update(for: .listening)
        registrar.increase?()
        registrar.decrease?()
        registrar.reset?()
        #expect(log == ["+", "-", "0"])
    }

    /// 注册失败不阻断录音（与 Esc 同一条哲学）：不抛、只失去缩放。
    @Test func registrationFailureIsSwallowed() {
        let controller = ZoomHotkeyController(registrar: ThrowingZoomRegistrar())
        controller.update(for: .listening)  // 不 crash 即可
        controller.update(for: .idle)
    }

    /// AppModel 的接线只能靠扫源码钉住（见 AppModelWiringTests 的说明：
    /// AppModel 起不来单测）——那只能证明「那三行还在」，证明不了「接对了
    /// 之后真的会让字号变化」。这里照抄 AppModel.bootstrap 里那三行接线，
    /// 用真的 HUDViewModel 走一遍：按住 registrar 回调 → fontSize 15→16→15
    /// →15（reset）。「接上了」与「值对了」两件事都要过。
    @Test func onIncreaseChainMovesRealHUDFontSize() {
        let name = "zoom-hotkey-wiring-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let hudModel = HUDViewModel(defaults: defaults)
        let registrar = FakeZoomRegistrar()
        let controller = ZoomHotkeyController(registrar: registrar)

        // 与 AppModel.bootstrap() 里 zoomHotkeys.onIncrease/onDecrease/onReset
        // 的接线逐字一致。
        controller.onIncrease = { [weak hudModel] in hudModel?.increaseFontSize() }
        controller.onDecrease = { [weak hudModel] in hudModel?.decreaseFontSize() }
        controller.onReset = { [weak hudModel] in hudModel?.resetFontSize() }

        #expect(hudModel.fontSize == 15)
        controller.update(for: .listening)
        registrar.increase?()
        #expect(hudModel.fontSize == 16)
        registrar.decrease?()
        #expect(hudModel.fontSize == 15)
        registrar.decrease?()
        registrar.reset?()
        #expect(hudModel.fontSize == 15)
    }
}
