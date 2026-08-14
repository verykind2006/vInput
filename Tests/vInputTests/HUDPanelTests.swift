import Foundation
import Testing
@testable import vInput

@Suite("HUDPanel 定位")
struct HUDPanelTests {
    @Test("水平居中于屏幕")
    func centersHorizontally() {
        let screen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let size = CGSize(width: 420, height: 160)

        let origin = HUDPanel.originFor(screenFrame: screen, panelSize: size)

        // 预先算好期望值再比较：Swift Testing 1902（Swift 6.3.3 工具链）在
        // #expect 内联对 CGFloat 做除法表达式时会误报失败——两侧打印值明明
        // 相同却判不等，换成 Double 或预先赋值给 CGFloat 常量都能规避。
        let expectedX: CGFloat = (1_920 - 420) / 2
        #expect(origin.x == expectedX)
    }

    @Test("距屏幕底边固定距离")
    func sitsAboveBottomEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let size = CGSize(width: 420, height: 160)

        let origin = HUDPanel.originFor(screenFrame: screen, panelSize: size)

        // AppKit 坐标系原点在左下角
        #expect(origin.y == HUDPanel.bottomMargin)
    }

    @Test("多显示器下相对所在屏幕定位而非全局坐标")
    func respectsScreenOrigin() {
        // 第二块屏在主屏右侧
        let screen = CGRect(x: 1_920, y: 0, width: 2_560, height: 1_440)
        let size = CGSize(width: 420, height: 160)

        let origin = HUDPanel.originFor(screenFrame: screen, panelSize: size)

        // 同上：规避 #expect 对 CGFloat 内联除法表达式的误判。
        let expectedX: CGFloat = 1_920 + (2_560 - 420) / 2
        #expect(origin.x == expectedX)
        #expect(origin.y == HUDPanel.bottomMargin)
    }

    @Test("屏幕比面板窄时不出现负坐标")
    func clampsOnNarrowScreen() {
        let screen = CGRect(x: 0, y: 0, width: 320, height: 480)
        let size = CGSize(width: 420, height: 160)

        let origin = HUDPanel.originFor(screenFrame: screen, panelSize: size)

        #expect(origin.x >= 0)
    }
}
