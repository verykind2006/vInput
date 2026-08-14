import Carbon.HIToolbox
import Testing
@testable import vInput

/// 两个热键共存的回归测试。
///
/// 真机日志实测过一个 bug：M2 加了 Esc 取消键之后，出现两个
/// `HotkeyRegistrar` 实例，各自调用 `InstallEventHandler`，第二个必然
/// 返回 `eventHandlerAlreadyInstalledErr`（-9866），Esc 取消静默失效。
///
/// 修复是把 Carbon 事件处理器改为全进程只装一次。
@Suite("热键共存")
@MainActor
struct HotkeyCoexistenceTests {
    @Test("两个 registrar 同时注册不同热键都能成功")
    func twoRegistrarsCoexist() throws {
        let first = HotkeyRegistrar()
        let second = HotkeyRegistrar()
        defer { first.unregister(); second.unregister() }

        // ⌥D：主快捷键
        try first.register(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey)) {}
        // Esc：取消键。修复前这一句会抛 handlerInstallFailed(-9866)
        try second.register(keyCode: UInt32(kVK_Escape), modifiers: 0) {}
    }

    @Test("注销其中一个不影响另一个继续工作")
    func unregisterOneKeepsOtherAlive() throws {
        let first = HotkeyRegistrar()
        let second = HotkeyRegistrar()
        defer { first.unregister(); second.unregister() }

        try first.register(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey)) {}
        try second.register(keyCode: UInt32(kVK_Escape), modifiers: 0) {}

        // Esc 只在录音期间注册，每次会话都会注销再注册。
        // 若注销时把共用的事件处理器一并移除，下次就再也装不回来。
        second.unregister()
        try second.register(keyCode: UInt32(kVK_Escape), modifiers: 0) {}
    }

    @Test("同一个 registrar 反复注册注销不累积失败")
    func repeatedCyclesSucceed() throws {
        let registrar = HotkeyRegistrar()
        defer { registrar.unregister() }

        // 模拟多轮录音：每轮进 listening 注册、离开时注销
        for _ in 0..<5 {
            try registrar.register(keyCode: UInt32(kVK_Escape), modifiers: 0) {}
            registrar.unregister()
        }
        try registrar.register(keyCode: UInt32(kVK_Escape), modifiers: 0) {}
    }
}
