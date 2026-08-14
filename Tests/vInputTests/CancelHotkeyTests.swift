import Testing
@testable import vInput

/// 记录注册/注销调用的替身。
@MainActor
final class SpyHotkeyRegistrar: CancelHotkeyRegistering {
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var handler: (() -> Void)?
    var registerError: Error?

    func registerCancelKey(handler: @escaping () -> Void) throws {
        registerCount += 1
        if let registerError { throw registerError }
        self.handler = handler
    }

    func unregisterCancelKey() {
        unregisterCount += 1
        handler = nil
    }
}

@Suite("CancelHotkey 生命周期")
@MainActor
struct CancelHotkeyTests {
    @Test("进入 listening 时注册")
    func registersWhenListening() {
        let spy = SpyHotkeyRegistrar()
        let controller = CancelHotkeyController(registrar: spy)

        controller.update(for: .listening)

        #expect(spy.registerCount == 1)
    }

    @Test("离开 listening 时注销")
    func unregistersWhenLeavingListening() {
        let spy = SpyHotkeyRegistrar()
        let controller = CancelHotkeyController(registrar: spy)

        controller.update(for: .listening)
        controller.update(for: .transcribing)

        #expect(spy.unregisterCount == 1)
    }

    @Test("重复进入 listening 不重复注册")
    func doesNotRegisterTwice() {
        let spy = SpyHotkeyRegistrar()
        let controller = CancelHotkeyController(registrar: spy)

        controller.update(for: .listening)
        controller.update(for: .listening)

        #expect(spy.registerCount == 1)
    }

    @Test("idle 状态下不注册")
    func idleDoesNotRegister() {
        let spy = SpyHotkeyRegistrar()
        let controller = CancelHotkeyController(registrar: spy)

        controller.update(for: .idle)

        #expect(spy.registerCount == 0)
    }

    @Test("注册失败不抛给调用方，只记录")
    func registrationFailureIsSwallowed() {
        let spy = SpyHotkeyRegistrar()
        spy.registerError = HotkeyError.registrationFailed(-1)
        let controller = CancelHotkeyController(registrar: spy)

        // Esc 注册失败不该阻断录音——⌥D 仍能正常结束会话
        controller.update(for: .listening)

        #expect(spy.registerCount == 1)
    }

    @Test("注册失败后离开 listening 仍会尝试注销")
    func cleansUpAfterFailedRegistration() {
        let spy = SpyHotkeyRegistrar()
        spy.registerError = HotkeyError.registrationFailed(-1)
        let controller = CancelHotkeyController(registrar: spy)

        controller.update(for: .listening)
        controller.update(for: .idle)

        #expect(spy.unregisterCount == 1)
    }

    @Test("触发时调用取消回调")
    func firesCancelHandler() {
        let spy = SpyHotkeyRegistrar()
        var cancelled = false
        let controller = CancelHotkeyController(registrar: spy)
        controller.onCancel = { cancelled = true }

        controller.update(for: .listening)
        spy.handler?()

        #expect(cancelled)
    }
}
