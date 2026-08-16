import AppKit
import SwiftUI

/// 承载基准集录制界面的独立窗口。
///
/// **为什么必须是窗口而不是菜单项**：录制界面原先长在 `MenuBarExtra` 的菜单
/// 里，而菜单里的 `Text` 在 macOS 上渲染成不可交互的说明文字——字号与颜色
/// 都改不动，天生小号灰字。用户要照着标准文本连读 23 条，看不清就读不下去。
///
/// **为什么不是 `NSPanel`**：`HUDPanel` 那种无焦点浮动面板的硬约束是
/// 「不抢焦点」（听写时焦点必须留在别的应用的输入框里，否则文字无处可注）。
/// 录制窗口正相反——用户此刻就在跟它交互，它就该能成为 key window。
/// 两者是不同的东西，不复用。
///
/// **为什么不是 SwiftUI 的 `Window` 场景**：关窗时要停掉正在进行的录音、
/// 重开时要重新建窗，这些生命周期动作在 `Window` 场景里没有干净的接入点，
/// 也没法在单测里驱动。这里只需要一个窗口，`NSWindow` 直接给得了。
@MainActor
final class BenchRecordingWindowController: NSObject, NSWindowDelegate {
    /// 窗口内容区尺寸。够放下 30pt 的标准文本（最长一条 64 字，约三行）
    /// 加上下两条状态/按钮栏。
    static let defaultContentSize = CGSize(width: 720, height: 420)

    /// 窗口关闭时的回调。
    ///
    /// **不可省**：关窗时若还在录音，麦克风会一直开着而界面已经不见了，
    /// 这段音频最终会写到用户看不见的那一条名下。调用方据此收尾。
    var onClose: (() -> Void)?

    /// 当前窗口。对外只读——测试要据此确认「关掉再开建的是新窗口」。
    private(set) var window: NSWindow?

    var isOpen: Bool { window != nil }

    /// 打开窗口；已经开着时只把它带到前台。
    ///
    /// 不重复建窗是有意的：调用方每次进这条路都会新建一个录制会话，
    /// 而重建会把用户从第 15 条弹回第 1 条。
    func show<Content: View>(_ content: Content, title: String = "基准集录制") {
        if let window {
            bringToFront(window)
            return
        }

        let window = makeWindow(title: title)

        let hosting = NSHostingController(rootView: content)
        // 清空 sizingOptions：默认的 .preferredContentSize 会拿 SwiftUI 的
        // 固有尺寸反过来定窗口大小，而正文那层 ScrollView 的固有尺寸很小
        // ——实测窗口一开出来就被压到 contentMinSize（560×352），远小于
        // 建窗时给的 720×420。设成空之后尺寸由下面这行说了算。
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(Self.defaultContentSize)
        window.center()
        self.window = window
        bringToFront(window)
    }

    func close() {
        guard let window else { return }
        window.close()
        // `close()` 对未上屏的窗口不保证发出 windowWillClose（没有窗口服务器的
        // 测试进程里就是如此），这里补一次收尾。两条路都走 finishClose，
        // 重复调用是空操作。
        finishClose()
    }

    func windowWillClose(_ notification: Notification) {
        finishClose()
    }

    private func finishClose() {
        guard window != nil else { return }
        window = nil
        onClose?()
    }

    private func makeWindow(title: String) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.defaultContentSize),
            // 可缩放：用户想把字看得更大时可以拉大窗口，正文区会跟着变宽。
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.delegate = self
        // ARC 下窗口由本控制器持有；保持默认的 true 会造成过度释放。
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: 560, height: 320)
        // 白底黑字是用户的明确要求。系统处于深色模式时，标题栏与按钮会被
        // 染成深色，与正文的纯白背景拼在一起既难看也更难辨认——这里锁死浅色。
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        return window
    }

    /// LSUIElement 应用默认不激活，不先 activate 的话窗口会躲在别的应用
    /// 后面且不接受键盘输入。录制窗口该抢焦点——用户此刻正在跟它交互。
    private func bringToFront(_ window: NSWindow) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
