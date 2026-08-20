import AppKit
import SwiftUI

/// 承载 HUD 的无焦点浮动面板。
///
/// **不抢焦点是硬约束。** 用户在别的应用里说话，焦点必须始终留在那个
/// 输入框上，否则文字无处可注。因此：
/// - `.nonactivatingPanel` 样式，点击不激活本应用
/// - 视图里不放任何可点击控件（鼠标事件根本不会送达）
@MainActor
final class HUDPanel {
    /// 面板底边距屏幕底部的距离。
    ///
    /// `nonisolated`：这是个纯常量，`originFor` 与测试都要在非主线程
    /// 上下文引用它，留在 `@MainActor` 隔离域内会触发 Swift 6 隔离警告。
    nonisolated static let bottomMargin: CGFloat = 120

    private var panel: NSPanel?
    private let model: HUDViewModel

    /// resize 通知的订阅凭证。`nonisolated(unsafe)`：只在 deinit（nonisolated）
    /// 里读，与 `RemoteKeySuppressor.tapHandle` 同一个理由——那时已经没有
    /// 别的引用会并发碰它。
    private nonisolated(unsafe) var resizeObserver: NSObjectProtocol?

    init(model: HUDViewModel) {
        self.model = model
    }

    /// **面板必须活得比它的 resize 订阅短。** 没有这个 `deinit`，通知中心会
    /// 一直攥着已经没人用的 observer token，回调里的 `[weak self]` 虽然不会
    /// 崩，但订阅本身永远不会摘掉。
    deinit {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
    }

    /// 计算面板在给定屏幕上的原点。抽成静态纯函数以便单测。
    ///
    /// AppKit 坐标系原点在左下角，故 y 直接取边距。
    nonisolated static func originFor(screenFrame: CGRect, panelSize: CGSize) -> CGPoint {
        let x = screenFrame.origin.x + max(0, (screenFrame.width - panelSize.width) / 2)
        let y = screenFrame.origin.y + bottomMargin
        return CGPoint(x: x, y: y)
    }

    /// 每次 `show()` 递增。淡出的收尾回调拿着自己那一代的号码，回来时对不上
    /// 就不再 `orderOut`。
    ///
    /// **不加这个的话，兜底提示会刚亮起就被上一刻的淡出关掉。** 实际时序
    /// （`DictationSession.finish()`）：
    ///
    /// 1. `transition(to: .idle)` → `AppModel.endHUD()`（此时 `notice` 还是
    ///    nil）→ `hide()`，排下一个 0.2 秒后的 `orderOut`；
    /// 2. 之后才 `await rescue?.rescue(...)`，通知那侧一次往返只要几十毫秒；
    /// 3. `showHUDNotice` → `show()`。
    ///
    /// 第 1 步排的 `orderOut` 大概率落在第 3 步之后，最好的情况也是肉眼可见
    /// 的一次闪烁。而这条提示恰恰是通知不可用时**唯一**告诉用户「文字没进去、
    /// 已复制到剪贴板」的途径——它自己无声失效，正是 M6 要根治的那类问题。
    private var showGeneration = 0

    func show() {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }

        showGeneration &+= 1
        reposition(panel)
        // orderFrontRegardless 而非 makeKeyAndOrderFront：
        // 后者会抢焦点，导致文字注入失败。
        panel.orderFrontRegardless()
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        let generation = showGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            // 淡出期间又 show() 过就作废：那 0.2 秒里冒出来的新内容比这次
            // 隐藏更新，关掉它等于把刚显示的东西吞了。
            guard let self, self.showGeneration == generation else { return }
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingController(rootView: HUDView(model: model))
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // 在所有 Space 与全屏应用之上显示——用户可能在全屏编辑器里口述。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true

        // NSHostingController 默认 sizingOptions = .standardBounds，内容变高时面板会
        // 自己 resize——但 AppKit 保持**左上角**不动，面板是往下长的，bottomMargin
        // 被吃掉（24pt 时 120→56，而 Dock 占了底部 92pt，会压住 footer）。
        // 只要尺寸变了就把原点重摆一次；⌘± 与附注行两条路径都走这里。
        // 这个 bug 早于本次改动——`noticeRow` 出现时同样会让面板长高（约 96），
        // 只是刚好擦过 92pt 没被发现；修在这里而不是各自的调用方，一次堵死两条路径。
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let panel = note.object as? NSWindow else { return }
                self.realign(panel)
            }
        }

        return panel
    }

    private func reposition(_ panel: NSPanel) {
        panel.layoutIfNeeded()
        let size = panel.contentViewController?.view.fittingSize ?? CGSize(width: 420, height: 160)
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let origin = Self.originFor(screenFrame: screen, panelSize: size)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    /// 只动原点、不动尺寸——`setFrameOrigin` 不会再触发 didResize，无递归。
    private func realign(_ panel: NSWindow) {
        let screen = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        panel.setFrameOrigin(Self.originFor(screenFrame: screen, panelSize: panel.frame.size))
    }
}
