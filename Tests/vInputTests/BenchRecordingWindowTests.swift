import SwiftUI
import Testing

@testable import vInput

/// 录制窗口的开关生命周期。
///
/// 渲染出来长什么样测不了，也不打算测。这里守的是三件出过事就很难查的事：
/// 关掉之后引用要放掉、重开要是新窗口、关窗要能通知调用方停录音。
@MainActor
@Suite("基准集录制窗口")
struct BenchRecordingWindowTests {
    private func makeController() -> BenchRecordingWindowController {
        BenchRecordingWindowController()
    }

    @Test("打开前没有窗口")
    func startsClosed() {
        #expect(makeController().isOpen == false)
    }

    @Test("打开后窗口存在")
    func opens() {
        let controller = makeController()
        controller.show(Text("标准文本"))
        #expect(controller.isOpen)
        controller.close()
    }

    @Test("关闭后放掉窗口引用")
    func closes() {
        let controller = makeController()
        controller.show(Text("标准文本"))
        controller.close()
        #expect(controller.isOpen == false)
        #expect(controller.window == nil)
    }

    /// 用户关掉再点菜单重开是常规操作，必须能开出来——而且是新的一扇，
    /// 不能拿已经 close 过的那个窗口对象接着用。
    @Test("重开建的是新窗口")
    func reopensWithFreshWindow() {
        let controller = makeController()
        controller.show(Text("第一次"))
        let first = controller.window
        controller.close()

        controller.show(Text("第二次"))
        #expect(controller.isOpen)
        #expect(controller.window !== first)
        controller.close()
    }

    /// 关窗必须通知调用方：还在录音时不停下来的话，麦克风开着而界面已经
    /// 不见了，那段音频会写到用户看不见的那一条名下。
    @Test("关闭时通知调用方收尾")
    func notifiesOnClose() {
        let controller = makeController()
        var closedCount = 0
        controller.onClose = { closedCount += 1 }

        controller.show(Text("标准文本"))
        #expect(closedCount == 0)

        controller.close()
        #expect(closedCount == 1)

        // 再关一次是空操作——close() 与 windowWillClose 两条路都会走到收尾，
        // 重复回调会把录音开关误切回去。
        controller.close()
        #expect(closedCount == 1)
    }

    @Test("已经开着时重复调用不换窗口")
    func showTwiceKeepsSameWindow() {
        let controller = makeController()
        controller.show(Text("第一次"))
        let first = controller.window
        controller.show(Text("第二次"))
        #expect(controller.window === first)
        controller.close()
    }
}
