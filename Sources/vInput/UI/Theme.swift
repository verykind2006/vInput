import SwiftUI

/// M9 视觉系统的唯一取值处。
/// 设计定稿：docs/superpowers/specs/2026-08-20-m9-ui-modernization-design.md。
/// 改任何颜色只改这里，四块资产（HUD、面板、菜单栏图标、App 图标脚本）跟着走。
enum VITheme {
    /// 琥珀橙 #FF9500——唯一强调色。
    static let accent = Color(red: 1.0, green: 0.584, blue: 0.0)
    /// 大面积渐变的两端 #FFB340 → #FF8A00。
    static let accentGradientTop = Color(red: 1.0, green: 0.702, blue: 0.251)
    static let accentGradientBottom = Color(red: 1.0, green: 0.541, blue: 0.0)
    /// App 图标瓦片专用的深色渐变 #2A2A2E → #131315（`scripts/render-icon.swift`
    /// 照抄这两个值；该脚本跑在 SPM 包之外，不能 import vInput，是手抄不是
    /// 引用——改这里必须同步过去）。
    static let iconTileTop = Color(red: 0.165, green: 0.165, blue: 0.180)
    static let iconTileBottom = Color(red: 0.075, green: 0.075, blue: 0.082)
    /// 面板底 #1D1D1F。
    static let panelBackground = Color(red: 0.114, green: 0.114, blue: 0.122)
    /// 内容块 #2A2A2D。
    static let contentBackground = Color(red: 0.165, green: 0.165, blue: 0.176)
    /// 发丝线描边。
    static let hairline = Color.white.opacity(0.09)
}

/// V 字声波：五根圆角柱排成 V 剪影（V=vInput，声柱=语音）。
///
/// 几何是归一化的（0…1 正方形内的分数坐标），来自设计定稿的 56 单位 SVG
/// （x 2/13/24.5/36/47，宽 7，高 48/36/24/36/48，底对齐 y+h=52）。
/// `scripts/render-icon.swift` **照抄这组数**，两处不共享代码（脚本独立运行），
/// 改这里必须同步改脚本——`ThemeTests.vMarkGeometryMatchesIconScript()` 解析
/// 脚本源码逐项核对两边数值，改漏一处会红，不是只靠注释承诺。
enum VMark {
    /// 归一化 (x, y, w, h)。y 向下为正（与 CGRect 绘制约定一致，绘制时按需翻转）。
    static let bars: [CGRect] = [
        CGRect(x: 2.0 / 56, y: 4.0 / 56, width: 7.0 / 56, height: 48.0 / 56),
        CGRect(x: 13.0 / 56, y: 16.0 / 56, width: 7.0 / 56, height: 36.0 / 56),
        CGRect(x: 24.5 / 56, y: 28.0 / 56, width: 7.0 / 56, height: 24.0 / 56),
        CGRect(x: 36.0 / 56, y: 16.0 / 56, width: 7.0 / 56, height: 36.0 / 56),
        CGRect(x: 47.0 / 56, y: 4.0 / 56, width: 7.0 / 56, height: 48.0 / 56),
    ]

    /// 「处理中」的波形化变体（中-高-低-高-中），垂直居中。
    static let workingBars: [CGRect] = [
        CGRect(x: 2.0 / 56, y: 17.0 / 56, width: 7.0 / 56, height: 22.0 / 56),
        CGRect(x: 13.0 / 56, y: 9.0 / 56, width: 7.0 / 56, height: 38.0 / 56),
        CGRect(x: 24.5 / 56, y: 20.0 / 56, width: 7.0 / 56, height: 16.0 / 56),
        CGRect(x: 36.0 / 56, y: 9.0 / 56, width: 7.0 / 56, height: 38.0 / 56),
        CGRect(x: 47.0 / 56, y: 17.0 / 56, width: 7.0 / 56, height: 22.0 / 56),
    ]

    /// 把一组归一化几何（默认 `bars`，也可传 `workingBars` 或未来的其他变体）
    /// 放进目标矩形。是各向异性拉伸，不做等比缩放：非正方形传入时 x/y 会按
    /// 各自边长独立缩放，不保持长宽比，也不居中裁切——调用方必须传正方形
    /// （本批 M9 调用处全部如此）。
    static func rects(_ bars: [CGRect] = VMark.bars, in rect: CGRect) -> [CGRect] {
        bars.map { bar in
            CGRect(
                x: rect.origin.x + bar.origin.x * rect.width,
                y: rect.origin.y + bar.origin.y * rect.height,
                width: bar.width * rect.width,
                height: bar.height * rect.height
            )
        }
    }
}
