#!/usr/bin/env swift
// App 图标渲染：深色渐变圆角方块 + 琥珀橙渐变 V mark。
//
// 几何数照抄 Sources/vInput/UI/Theme.swift 的 VMark.bars（56 单位设计稿：
// x 2/13/24.5/36/47，宽 7，高 48/36/24/36/48），配色照抄同文件的 VITheme
// （琥珀渐变 accentGradientTop/Bottom + 瓦片深色渐变 iconTileTop/Bottom）。
// 两处**不共享代码**——本脚本独立于 SPM 包之外运行（`swift
// scripts/render-icon.swift <目录>`，跑在包外，不能 import vInput），
// 是刻意的重复，不是疏漏。改 Theme.swift 的 VMark/VITheme 必须同步改这里；
// 反过来改这里的数字也要去 Theme.swift 对一遍。几何数的同步义务有机器
// 守卫——Tests/vInputTests/ThemeTests.swift 的 vMarkGeometryMatchesIconScript()
// 会解析本文件的 barsIn56 并与 VMark.bars 逐项核对，改漏一个数字它会红；
// 配色目前没有等价的机器守卫，只能靠人核对。
//
// 用法：swift scripts/render-icon.swift <iconset 目录>
// 产出 iconutil 要求的十个档位 PNG（icon_16x16.png … icon_512x512@2x.png）。
import AppKit

// 与 Theme.swift 的 VMark.bars 逐项对应（56 单位、y 向下为正）。
let barsIn56: [CGRect] = [
    CGRect(x: 2, y: 4, width: 7, height: 48),
    CGRect(x: 13, y: 16, width: 7, height: 36),
    CGRect(x: 24.5, y: 28, width: 7, height: 24),
    CGRect(x: 36, y: 16, width: 7, height: 36),
    CGRect(x: 47, y: 4, width: 7, height: 48),
]

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let side = CGFloat(pixels)
    // macOS 图标习惯：内容占画布约 80%，四周留安全边距，四角透明。
    let tile = CGRect(x: side * 0.1, y: side * 0.1, width: side * 0.8, height: side * 0.8)
    let radius = tile.width * 0.2246
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    // 深色渐变底 #2A2A2E → #131315，与 VITheme.iconTileTop/iconTileBottom 同值。
    NSGradient(
        starting: NSColor(red: 0.165, green: 0.165, blue: 0.180, alpha: 1),
        ending: NSColor(red: 0.075, green: 0.075, blue: 0.082, alpha: 1)
    )!.draw(in: tilePath, angle: -70)

    // V mark：占 tile 宽 60%，居中；柱子是圆角矩形，圆角半径 = 柱宽一半
    // （与 StatusIcon.swift、VMarkShape 的画法一致）。
    let markSide = tile.width * 0.60
    let mark = CGRect(
        x: tile.midX - markSide / 2, y: tile.midY - markSide / 2,
        width: markSide, height: markSide)
    let markPath = NSBezierPath()
    for b in barsIn56 {
        // 56 单位几何 y 向下，这里的绘制坐标系 y 向上：翻转 y。
        let r = CGRect(
            x: mark.minX + b.minX / 56 * mark.width,
            y: mark.minY + (56 - b.maxY) / 56 * mark.height,
            width: b.width / 56 * mark.width,
            height: b.height / 56 * mark.height)
        markPath.append(NSBezierPath(roundedRect: r, xRadius: r.width / 2, yRadius: r.width / 2))
    }
    // 琥珀橙渐变 #FFB340 → #FF8A00，与 VITheme.accentGradientTop/Bottom 同值。
    NSGradient(
        starting: NSColor(red: 1.0, green: 0.702, blue: 0.251, alpha: 1),
        ending: NSColor(red: 1.0, green: 0.541, blue: 0.0, alpha: 1)
    )!.draw(in: markPath, angle: -70)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("用法: swift scripts/render-icon.swift <iconset 目录>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// iconutil 要求的十个档位，文件名必须精确匹配。
let specs: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for spec in specs {
    let rep = render(pixels: spec.pixels)
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: outDir.appendingPathComponent("\(spec.name).png"))
}
print("已渲染 \(specs.count) 档 → \(outDir.path)")
