import AppKit
import Foundation
import Testing

@testable import vInput

/// 关掉面板时「把前台让给别人」这件事的不变量（R-1，2026-08-21 用户真机实测）。
///
/// 起因：`dismissMenuPanel()` 原本以 `NSApp.hide(nil)` 结尾。它确实把前台还了
/// 回去（探针实测 +0.05s 生效），但顺带把 LSUIElement 应用的**菜单栏状态项**
/// 一起藏掉——从面板起的听写变成单向路，图标没了，点不到「结束听写」。
///
/// 这一组测试钉两件事：
///
/// - `ForegroundAppTracker` 记的一定不是 vInput 自己（真行为测试，能跑）；
/// - 让位路径上不许再出现 `NSApp.hide`（扫源码，理由见下面那条测试）。
@Suite("关面板时的前台让位")
@MainActor
struct ForegroundHandoffTests {
    /// 另一个真实存在的运行中应用。系统上至少有 Finder 与 loginwindow，
    /// 拿不到就说明测试环境本身不对，直接让测试失败比跳过更好。
    static func someOtherApp() -> NSRunningApplication? {
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.first { $0.processIdentifier != mine }
    }


    @Test("记别人")
    func recordsOtherApplication() throws {
        let tracker = ForegroundAppTracker()
        let other = try #require(Self.someOtherApp(), "测试环境里找不到第二个运行中的应用。")
        tracker.record(other)
        let recorded = tracker.previousApp?.processIdentifier
        #expect(
            recorded == other.processIdentifier,
            "record(别的应用) 之后 previousApp 不是它（是 \(recorded.map(String.init) ?? "nil")）。"
        )
    }

    /// **这条是整个类存在的理由。**
    ///
    /// 记下自己的话，`handBackForeground()` 就是「把前台让给自己」——空操作，
    /// 坏结果与压根不让位一模一样：`TargetAppGuard.capture()` 记下 vInput，
    /// 转写出来的文字注进面板里，等于凭空消失。
    @Test("不记自己")
    func ignoresSelf() {
        let tracker = ForegroundAppTracker()
        tracker.record(.current)
        let recorded = tracker.previousApp?.processIdentifier
        #expect(
            recorded == nil,
            "record(自己) 之后 previousApp 被写成了 \(recorded.map(String.init) ?? "nil")。"
        )
    }

    /// 自己被激活**不能**冲掉已经记住的那个应用。
    ///
    /// 真实时序正是这样：用户在编辑器里 → 点状态项 → vInput 激活（这条通知
    /// 必须被忽略）→ 关面板要还给编辑器。少了这一层过滤，previousApp 在最
    /// 关键的那一刻恰好被覆盖成 vInput。
    @Test("自己被激活不冲掉已记住的应用")
    func selfActivationDoesNotOverwrite() throws {
        let tracker = ForegroundAppTracker()
        let other = try #require(Self.someOtherApp(), "测试环境里找不到第二个运行中的应用。")
        tracker.record(other)
        tracker.record(.current)
        let recorded = tracker.previousApp?.processIdentifier
        #expect(
            recorded == other.processIdentifier,
            "自己被激活之后 previousApp 变成了 \(recorded.map(String.init) ?? "nil")，原来记的那个被冲掉了。"
        )
    }

    /// 没记住任何人时不谎报让位成功。
    ///
    /// `dismissMenuPanel()` 靠这个返回值决定要不要走兜底；谎报 true 的话
    /// 兜底永远不会执行，而这一格恰恰是「前台没让出去」的唯一补救。
    @Test("没记住任何人时 handBackForeground 返回 false")
    func reportsFailureWithoutPreviousApp() {
        let tracker = ForegroundAppTracker()
        let handed = tracker.handBackForeground()
        #expect(handed == false, "previousApp 是 nil 时 handBackForeground() 却报了成功。")
    }

    /// `nil` 不许把已经记住的应用抹掉。
    ///
    /// 通知的 userInfo 取不到应用时会传 nil 进来（系统偶发，也可能是 key
    /// 改名）。抹掉的后果与记成自己一样：让位无处可还。
    @Test("nil 不抹掉已记住的应用")
    func nilDoesNotClear() throws {
        let tracker = ForegroundAppTracker()
        let other = try #require(Self.someOtherApp(), "测试环境里找不到第二个运行中的应用。")
        tracker.record(other)
        tracker.record(nil)
        let recorded = tracker.previousApp?.processIdentifier
        #expect(
            recorded == other.processIdentifier,
            "record(nil) 把 previousApp 抹成了 \(recorded.map(String.init) ?? "nil")。"
        )
    }

    // MARK: - 让位路径上不许再出现 NSApp.hide（扫源码）

    /// `NSApp.hide` 不许回到 `ModalPanels.swift`。
    ///
    /// 扫源码是因为真跑一次 `hide` 需要一个真的菜单栏状态项和一双眼睛：
    /// 探针实测里 `NSStatusItem.isVisible`、承载窗口的 `isVisible` 在应用被
    /// hide 之后**照样报 true**（它们表达的是「程序希望它在」，不是「用户
    /// 看得见」），所以这件事在进程内没有可断言的量。
    ///
    /// 它又正是以后重构会顺手写回来的那一行（「让位不就是 hide 一下吗」），
    /// 而写回来的表现是用户点不到「结束听写」——一条自动化测试都不会红。
    @Test("dismissMenuPanel 不再藏整个应用")
    func dismissDoesNotHideTheApp() throws {
        let source = try MenuPanelViewWiringTests.codeOnly(
            MenuPanelViewWiringTests.source("Sources/vInput/App/ModalPanels.swift"))
        let hides = source.contains("NSApp.hide(") || source.contains("NSApplication.shared.hide(")
        #expect(
            !hides,
            """
            ModalPanels.swift 里又出现了 NSApp.hide。
            LSUIElement 应用被 hide 会连菜单栏状态项一起藏掉：从面板点「开始
            听写」之后图标消失，用户点不到「结束听写」（R-1，用户真机实测）。
            让位要用 ForegroundAppTracker.handBackForeground()。
            """
        )
    }

    /// **不许对任何窗口下手。**
    ///
    /// 这条路径误判过两次，两次的表现都是「从面板点开始听写，菜单栏图标就
    /// 没了」（用户真机实测两轮）：
    ///
    /// 1. `key.close()` —— 以为是 SwiftUI 宿主窗口被释放（
    ///    `isReleasedWhenClosed` 默认 true）；
    /// 2. 改成 `key.orderOut(nil)` —— **症状一模一样**。
    ///
    /// 事后量到的事实推翻了这两种解释：状态项根本没被销毁（辅助功能接口
    /// 报个数 1、位置 882、尺寸 36×24），只是画不出来。也就是说
    /// `NSApp.keyWindow` 拿到的多半不是面板窗口，而是 `NSStatusItem` 按钮
    /// 挂着的那个窗口——它同样没有标题栏，穿得过任何按 `.titled` 做的过滤。
    ///
    /// 所以这里不再挑「该关哪个窗口」，一个都不碰：`.window` 样式的
    /// MenuBarExtra 面板失去 key 状态时自己会关，而让位（激活别的应用）
    /// 恰好造成这一点。
    @Test("dismissMenuPanel 不对任何窗口下手")
    func dismissTouchesNoWindow() throws {
        let source = try MenuPanelViewWiringTests.codeOnly(
            MenuPanelViewWiringTests.source("Sources/vInput/App/ModalPanels.swift"))
        for forbidden in ["key.close()", "key.orderOut(", ".close()", ".orderOut("] {
            let touches = source.contains(forbidden)
            #expect(
                !touches,
                """
                ModalPanels.swift 里又出现了 \(forbidden)。
                这条路径误判过两次：close() 与 orderOut() 症状一模一样，
                因为 NSApp.keyWindow 拿到的多半是状态项自己的窗口（同样没有
                标题栏），关它就是把菜单栏图标藏掉。面板不需要我们去关——
                让位激活别的应用之后它自己会关。
                """
            )
        }
    }

    /// 让位这一步必须真的在 `dismissMenuPanel()` 里。
    ///
    /// 只关窗口是不够的：LSUIElement 应用在面板关闭后仍可能是活跃应用，
    /// 那时 `TargetAppGuard.capture()` 记下的是 vInput 自己。
    @Test("dismissMenuPanel 会把前台还回去")
    func dismissHandsBackForeground() throws {
        let source = try MenuPanelViewWiringTests.codeOnly(
            MenuPanelViewWiringTests.source("Sources/vInput/App/ModalPanels.swift"))
        let handsBack = source.contains("ForegroundAppTracker.shared.handBackForeground()")
        #expect(
            handsBack,
            """
            dismissMenuPanel() 里没有 ForegroundAppTracker.shared.handBackForeground()。
            只关窗口不让位的话，vInput 仍是活跃应用，TargetAppGuard 记下的
            目标就是它自己，转写出来的文字会注进面板里。
            """
        )
    }

    /// 追踪器必须在启动时接上。
    ///
    /// 不接的话 `previousApp` 永远是 nil，`handBackForeground()` 永远返回
    /// false——而这一条在别处看不出来：编译过、单测全绿、面板照常打开。
    @Test("ForegroundAppTracker 在启动时接上")
    func trackerIsStartedAtLaunch() throws {
        let source = try MenuPanelViewWiringTests.codeOnly(
            MenuPanelViewWiringTests.source("Sources/vInput/App/vInputApp.swift"))
        let started = source.contains("ForegroundAppTracker.shared.start()")
        #expect(
            started,
            """
            AppDelegate.applicationDidFinishLaunching 里没有
            ForegroundAppTracker.shared.start()。不启动它 previousApp 永远是
            nil，关面板时无处可还——而编译、单测、面板打开全都照常。
            """
        )
    }
}
