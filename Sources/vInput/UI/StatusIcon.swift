import AppKit
import SwiftUI

/// 菜单栏图标：V 字声波 mark 的五种状态形态。
enum StatusIcon {
    /// 与 `AppModel` 解耦的图标档位。**穷尽 switch 映射，加档必过编译。**
    enum State: Equatable, CaseIterable {
        case idle, listening, working, error, loadingModel
    }

    nonisolated static func state(loadingModelName: String?, phase: AppModel.Phase) -> State {
        if loadingModelName != nil { return .loadingModel }
        return switch phase {
        case .idle: .idle
        case .listening: .listening
        case .working: .working
        case .error: .error
        }
    }

    /// 模板图交给系统着色（自动适应深浅菜单栏）；听写中的琥珀橙与出错的
    /// 红点是「必须一眼可辨」的信号色，只能用非模板彩图。
    /// 非模板图的已知代价：菜单栏深浅切换时不重绘——下一次状态变化会刷新，
    /// 而听写/出错本身就是短暂状态，可接受。
    nonisolated static func isTemplate(_ state: State) -> Bool {
        switch state {
        case .idle, .working, .loadingModel: true
        case .listening, .error: false
        }
    }

    /// 在角标区域先挖空一个比角标略大的透明洞，再画角标本体。
    ///
    /// 不这样做的话：半透明角标叠在不透明柱子上时，sourceOver 合成得到
    /// alpha = badgeAlpha + barAlpha*(1-badgeAlpha) ≈ 1.0——模板图只看 alpha，
    /// 这部分会和柱子融成一片，角标只剩不压柱子的那一小段月牙可见。
    /// 用 QA 复核里的探针实测过：柱子×角标重叠处 alpha 挖空前 1.0、挖空后 0.451
    /// （背景区两种做法都是 0.45，符合预期）。
    private static func drawBadge(_ badgeRect: CGRect, color: NSColor) {
        let knockoutRect = badgeRect.insetBy(dx: -1.5, dy: -1.5)
        let context = NSGraphicsContext.current
        context?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        NSBezierPath(ovalIn: knockoutRect).fill()
        context?.compositingOperation = .sourceOver
        color.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()
    }

    @MainActor
    static func image(for state: State) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            // 缩放走 VMark.rects(_:in:)，不各写一遍（Task 1 QA 复核后泛化的初衷）。
            let bars = VMark.rects(
                state == .working ? VMark.workingBars : VMark.bars, in: rect)
            let barColor: NSColor = switch state {
            // #FF9500，与 VITheme.accent 同一个值：SwiftUI Color → NSColor 桥接
            // 在同 target、macOS 14+ 下可用，避免和 Theme.swift 的单一色源脱节。
            case .listening: NSColor(VITheme.accent)
            // 出错是彩图，柱子按当前外观取实色（见 isTemplate 注释）。
            case .error: NSColor.secondaryLabelColor
            case .idle, .working, .loadingModel: NSColor.black  // 模板图只看 alpha
            }
            barColor.setFill()
            for bar in bars {
                NSBezierPath(roundedRect: bar, xRadius: bar.width / 2, yRadius: bar.width / 2).fill()
            }
            if state == .error {
                drawBadge(CGRect(x: rect.maxX - 7.5, y: rect.minY, width: 7, height: 7), color: .systemRed)
            }
            if state == .loadingModel {
                // 模板图里半透明角标 = 淡一档的同色（模板按 alpha 着色）。
                drawBadge(CGRect(x: rect.maxX - 6.5, y: rect.minY, width: 6, height: 6), color: NSColor.black.withAlphaComponent(0.45))
            }
            return true
        }
        image.isTemplate = isTemplate(state)
        return image
    }
}

/// 菜单栏那个图标的 SwiftUI 外壳。
///
/// **必须是一个真正的 `View`，不能把这几行直接写在 `MenuBarExtra` 的 label
/// 闭包里。** `Image` 是叶子视图、没有自己的 body，所以写在闭包里时，
/// `model.phase` 这两处读取发生在 **Scene 的 body 求值期间**；Scene 通常
/// 只在启动时求值一次，观察系统推不动它——图标从此定格在启动那一刻的状态。
///
/// 实测（2026-08-21，用户真机 + 连拍 6 帧覆盖 5.4 秒）：会话已经进
/// `.listening`，菜单栏图标全程仍是空闲档的白色模板图，一次都没变成琥珀橙。
/// **这不只是好不好看**：琥珀橙是「正在录音」唯一始终可见的信号，而这个
/// 应用可以用遥控器隔着房间启动——图标不变色，人就不知道自己正在被录。
///
/// 包成 View 之后，属性读取落在 View 的 body 里，观察系统正常接管。
struct StatusIconLabel: View {
    let model: AppModel

    var body: some View {
        Image(nsImage: StatusIcon.image(for: StatusIcon.state(
            loadingModelName: model.loadingModelName,
            phase: model.phase)))
    }
}
