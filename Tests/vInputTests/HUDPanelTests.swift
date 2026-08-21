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

    // MARK: - resize 后重新贴回 Dock 上方（QA 复核，探针实测）

    /// 用**扫源码**钉住订阅本身，跟 `AppModelWiringTests` 同一个理由：
    /// `NSHostingController` 默认 `sizingOptions = .standardBounds`，
    /// 内容变高（⌘＋ 调大字号、或附注行出现）时面板会自己 resize，但 AppKit
    /// 保持左上角不动、面板往下长，`bottomMargin` 被吃掉。真机探针实测：
    /// 15pt→bottomGap 120，20pt→84，24pt→**56**——这台机器 Dock 占底部 92pt，
    /// 从第 5 次 ⌘＋ 起 footer（就是刚加的「⌘＋/－ 字号」那一行）开始被压。
    ///
    /// 这个 bug 早于本轮字号功能：`noticeRow` 出现时同样会让面板长高
    /// （bottomGap→约 96），只是刚好擦过 92pt 没被发现。
    static func hudPanelSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // vInputTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
        return try String(
            contentsOf: root.appendingPathComponent("Sources/vInput/UI/HUDPanel.swift"),
            encoding: .utf8
        )
    }

    @Test("makePanel 订阅了面板自身的 resize 通知")
    func subscribesToOwnResizeNotification() throws {
        let source = try Self.hudPanelSource()
        #expect(
            source.contains("resizeObserver = NotificationCenter.default.addObserver("),
            """
            HUDPanel.makePanel() 里没有订阅 resize 通知。
            少了它的话，⌘＋ 把字号调到 24pt 时面板会往下长而不回摆原点，
            这台机器 Dock 占底部 92pt、bottomGap 会从 120 掉到 56，
            footer（「⌘＋/－ 字号」那一行）被 Dock 压住。
            """
        )
        #expect(
            source.contains("NSWindow.didResizeNotification"),
            "订阅的通知名不是 NSWindow.didResizeNotification，检查有没有走错通知。"
        )
        // 作用域必须钉住：`object: nil` 会收到**任何**窗口的 resize，而本仓库
        // 确实还有第二个窗口（BenchRecordingWindow），那样会把它一并拖到 HUD
        // 的位置上。这一行原本落在断言之外——正是本仓库反复栽的「判据看着在
        // 检查什么、其实没检查」。
        #expect(
            source.contains("object: panel"),
            "resize 订阅没有限定 object: panel，会收到其他窗口（如 BenchRecordingWindow）的 resize。"
        )
    }

    // MARK: - HUD 不受「隐藏应用」影响（QA 复核，探针实测）

    /// 应用被隐藏时不许把 HUD 一起藏掉。
    ///
    /// `hidesOnDeactivate = false` 只挡「失去活跃状态」，挡不住**显式**的
    /// 隐藏——探针实测两次（复刻 `makePanel()` 全部样式）：`canHide` 默认 true
    /// 时 hide 之后 `isVisible` 从 true 变 false；对照组 `canHide = false`
    /// 则 hide 之后仍可见。
    ///
    /// **这条测试的理由在 R-1 里换过一次，不是历史包袱。** 原来的理由是
    /// `dismissMenuPanel()` 以 `NSApp.hide(nil)` 结尾；那个调用已经删了
    /// （它会连菜单栏状态项一起藏掉，用户点不到「结束听写」）。现在的理由与
    /// 本仓库的代码无关，且用户随时按得到：任意应用的「隐藏其他」（⌘⌥H）
    /// 会隐藏包括 vInput 在内的所有其他应用——用户在编辑器里口述到一半按下
    /// 它，没有这一行的话 HUD 当场消失，而这条路径上没有补救：
    ///
    /// - 会话进 `.transcribing`，`AppModel` 的重开闸门是 `wasIdle` 不满足、
    ///   `endHUD()` 在有附注那一支也只排计时器不 `show()` → **「本次未校正」
    ///   等末尾附注一个字都到不了用户眼前**，而上面那套 `showGeneration`
    ///   机制存在的理由就是保住这条提示。
    /// - 反过来靠 `show()` 撤销隐藏的话，撤销隐藏会抢回前台，注入前
    ///   `TargetAppGuard.verify` 抛 `targetApplicationChanged`。
    @Test("HUD 面板不被「隐藏应用」藏掉")
    func panelOptsOutOfAppHide() throws {
        let source = try Self.hudPanelSource()
        let optsOut = source.contains("panel.canHide = false")
        #expect(
            optsOut,
            """
            HUDPanel.makePanel() 里没有 panel.canHide = false。
            应用一被隐藏（用户在别的应用里按「隐藏其他」⌘⌥H 就会发生），
            HUD 会被一起 orderOut（hidesOnDeactivate = false 挡不住显式 hide，
            探针实测）：口述到一半 HUD 消失，末尾附注（「本次未校正」等）
            一个字都到不了用户眼前。
            """
        )
    }

    @Test("resizeObserver 在 deinit 里被摘掉")
    func removesResizeObserverOnDeinit() throws {
        let source = try Self.hudPanelSource()
        #expect(
            source.contains("NotificationCenter.default.removeObserver(resizeObserver)"),
            "deinit 里没有摘掉 resizeObserver，面板释放后订阅会一直留在通知中心里。"
        )
    }
}
