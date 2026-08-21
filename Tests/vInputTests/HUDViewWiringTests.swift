import Foundation
import Testing

@testable import vInput

/// HUD 内容视图（`HUDView`）的接线不变量，用**扫源码**的方式钉住。
///
/// 为什么是扫源码：理由与 `MenuPanelViewWiringTests` 一字不差——视图在这个
/// 仓库里跑不起来（`AppModel` 在 `init` 里就要真麦克风、真快捷键、真 CGEvent
/// tap），SwiftUI 的 body 也没有可断言的输出。扫源码证明不了「它长得对」，
/// 只能防住「那一行被顺手删掉」。
///
/// 断言一律先算成 Bool，别把整份源码交给 `#expect`：那样一红就会原样打出
/// 整个文件，变异验证时「没红」和「红了但找不到」就分不开了。
@Suite("HUD 视图接线不变量")
struct HUDViewWiringTests {
    static func hudViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // vInputTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
        return try String(
            contentsOf: root.appendingPathComponent("Sources/vInput/UI/HUDView.swift"),
            encoding: .utf8
        )
    }

    // MARK: - 深色 HUD

    /// HUD 底色是写死的深色，文字颜色必须一起钉死。
    ///
    /// M9 Task 5 把 HUD 底色换成写死的深色 `VITheme.panelBackground`，但正文
    /// 仍是 `.primary` / `.secondary` / `.tertiary`——这三个跟系统外观走。
    /// QA 探针实测：aqua（浅色）外观下 `Color.primary`、`Color.secondary`
    /// 亮度 0.000，而 `VITheme.panelBackground` 亮度 0.115，即**黑字压深底**，
    /// 预览文字、附注、按键提示一起读不出来。
    ///
    /// **为什么开发机上看不见**：作者的机器常年深色模式，浅色模式下才现形；
    /// 菜单面板在 Task 7 撞到并修好了同一个坑（`panelForcesDarkColorScheme`），
    /// HUD 这一份是同批漏网的另一半。
    @Test("HUD 把配色方案钉死成深色")
    func hudForcesDarkColorScheme() throws {
        let source = try Self.hudViewSource()
        let forcesDark = source.contains(#".environment(\.colorScheme, .dark)"#)
        #expect(
            forcesDark,
            """
            HUDView 没有 .environment(\\.colorScheme, .dark)。
            HUD 底色写死深色 VITheme.panelBackground，而正文的
            .primary/.secondary/.tertiary 跟系统外观走——浅色（aqua）外观下
            实测文字亮度 0.000 压在亮度 0.115 的底色上，预览文字/附注/按键
            提示全部读不出来。开发机常年深色模式，这个缺陷在自己机器上
            永远看不见。
            """
        )
    }
}
