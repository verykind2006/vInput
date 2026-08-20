import AppKit

/// 菜单栏图标：V 字声波 mark 的五种状态形态。
enum StatusIcon {
    /// 与 `AppModel` 解耦的图标档位。**穷尽 switch 映射，加档必过编译。**
    enum State: Equatable, CaseIterable {
        case idle, listening, working, error, loadingModel
    }

    static func state(loadingModelName: String?, phase: AppModel.Phase) -> State {
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
    static func isTemplate(_ state: State) -> Bool {
        switch state {
        case .idle, .working, .loadingModel: true
        case .listening, .error: false
        }
    }

    @MainActor
    static func image(for state: State) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            // 缩放走 VMark.rects(_:in:)，不各写一遍（Task 1 QA 复核后泛化的初衷）。
            let bars = VMark.rects(
                state == .working ? VMark.workingBars : VMark.bars, in: rect)
            let barColor: NSColor = switch state {
            case .listening: NSColor(red: 1.0, green: 0.584, blue: 0.0, alpha: 1)  // #FF9500
            // 出错是彩图，柱子按当前外观取实色（见 isTemplate 注释）。
            case .error: NSColor.secondaryLabelColor
            case .idle, .working, .loadingModel: NSColor.black  // 模板图只看 alpha
            }
            barColor.setFill()
            for bar in bars {
                NSBezierPath(roundedRect: bar, xRadius: bar.width / 2, yRadius: bar.width / 2).fill()
            }
            if state == .error {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: CGRect(x: rect.maxX - 7.5, y: rect.minY, width: 7, height: 7)).fill()
            }
            if state == .loadingModel {
                // 模板图里半透明角标 = 淡一档的同色（模板按 alpha 着色）。
                NSColor.black.withAlphaComponent(0.45).setFill()
                NSBezierPath(ovalIn: CGRect(x: rect.maxX - 6.5, y: rect.minY, width: 6, height: 6)).fill()
            }
            return true
        }
        image.isTemplate = isTemplate(state)
        return image
    }
}
