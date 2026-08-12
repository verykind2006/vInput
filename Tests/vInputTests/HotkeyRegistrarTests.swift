import Testing
@testable import vInput

@Suite("HotkeyRegistrar")
@MainActor
struct HotkeyRegistrarTests {
    @Test("注册后可通过 ID 找回处理器")
    func lookupAfterRegister() {
        let table = HotkeyCallbackTable()
        var fired = 0
        let id = table.register { fired += 1 }

        table.dispatch(id)

        #expect(fired == 1)
    }

    @Test("注销后不再触发")
    func noDispatchAfterUnregister() {
        let table = HotkeyCallbackTable()
        var fired = 0
        let id = table.register { fired += 1 }

        table.unregister(id)
        table.dispatch(id)

        #expect(fired == 0)
    }

    @Test("未知 ID 不会崩溃")
    func unknownIDIsSafe() {
        let table = HotkeyCallbackTable()
        table.dispatch(9_999)   // 不抛错即通过
    }

    @Test("多个处理器互不干扰")
    func multipleHandlersAreIndependent() {
        let table = HotkeyCallbackTable()
        var first = 0
        var second = 0
        let idA = table.register { first += 1 }
        let idB = table.register { second += 1 }

        table.dispatch(idA)
        table.dispatch(idA)
        table.dispatch(idB)

        #expect(first == 2)
        #expect(second == 1)
    }

    @Test("每次注册分配不同的 ID")
    func idsAreUnique() {
        let table = HotkeyCallbackTable()
        let idA = table.register {}
        let idB = table.register {}
        #expect(idA != idB)
    }

    @Test("注销一个不影响另一个")
    func unregisterIsolatesHandlers() {
        let table = HotkeyCallbackTable()
        var first = 0
        var second = 0
        let idA = table.register { first += 1 }
        let idB = table.register { second += 1 }

        table.unregister(idA)
        table.dispatch(idA)
        table.dispatch(idB)

        #expect(first == 0)
        #expect(second == 1)
    }
}
