import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import vInput

/// VMark 是三处共用的品牌图形（菜单栏、面板头、App 图标脚本照抄同组数）。
/// 这些测试钉的是「V 剪影」这个形状本身：对称、中间最矮、往两边递增。
struct ThemeTests {
    @Test func vMarkHasFiveBars() {
        #expect(VMark.bars.count == 5)
    }

    /// V 形：两端最高、中间最矮，高度向中间单调递减。
    /// 钉字面量而非互相比较——互相比较的断言对「整体等比改错」不敏感。
    @Test func vMarkHeightsFormV() {
        let h = VMark.bars.map(\.height)
        #expect(abs(h[0] - 0.857) < 0.001)
        #expect(abs(h[1] - 0.643) < 0.001)
        #expect(abs(h[2] - 0.429) < 0.001)
        #expect(h[0] > h[1] && h[1] > h[2])
    }

    /// 左右镜像：第 i 根与第 4-i 根同高同宽，x 关于 0.5 对称。
    @Test func vMarkIsSymmetric() {
        let b = VMark.bars
        for i in 0..<2 {
            let j = 4 - i
            #expect(abs(b[i].height - b[j].height) < 0.001)
            #expect(abs(b[i].width - b[j].width) < 0.001)
            #expect(abs((b[i].midX + b[j].midX) - 1.0) < 0.001)
        }
    }

    /// 底边对齐（V 是站在同一条基线上的）：maxY 全相等。
    @Test func vMarkBarsShareBaseline() {
        let maxYs = VMark.bars.map(\.maxY)
        for y in maxYs { #expect(abs(y - maxYs[0]) < 0.001) }
    }

    /// 缩放到目标矩形：归一化几何 × 边长 + 原点偏移。
    @Test func vMarkScalesToRect() {
        let rects = VMark.rects(in: CGRect(x: 10, y: 20, width: 100, height: 100))
        #expect(rects.count == 5)
        #expect(abs(rects[0].origin.x - (10 + 0.0357 * 100)) < 0.1)
        #expect(abs(rects[0].origin.y - (20 + (4.0 / 56) * 100)) < 0.1)
        #expect(abs(rects[0].height - 85.7) < 0.1)
    }

    // MARK: - workingBars（「处理中」波形变体）

    @Test func workingBarsHasFiveBars() {
        #expect(VMark.workingBars.count == 5)
    }

    /// 中-高-低-高-中：第 1/3 根（index 1、3）最高，中间（index 2）最矮，
    /// 两端（index 0、4）居中。钉字面量，不互相比较。
    @Test func workingBarsHeightsAreCenterDip() {
        let h = VMark.workingBars.map(\.height)
        #expect(abs(h[0] - 0.393) < 0.001)
        #expect(abs(h[1] - 0.679) < 0.001)
        #expect(abs(h[2] - 0.286) < 0.001)
        #expect(h[1] > h[0])
        #expect(h[0] > h[2])
    }

    /// 左右镜像：与 vMarkIsSymmetric 同样的判据，套在 workingBars 上。
    @Test func workingBarsIsSymmetric() {
        let b = VMark.workingBars
        for i in 0..<2 {
            let j = 4 - i
            #expect(abs(b[i].height - b[j].height) < 0.001)
            #expect(abs(b[i].width - b[j].width) < 0.001)
            #expect(abs((b[i].midX + b[j].midX) - 1.0) < 0.001)
        }
    }

    /// 「垂直居中」是这个变体的定义性质：每根柱子的中点都落在 0.5。
    @Test func workingBarsAreVerticallyCentered() {
        for bar in VMark.workingBars {
            #expect(abs(bar.midY - 0.5) < 0.001)
        }
    }

    // MARK: - rects(_:in:) 参数化

    /// `rects` 必须真的按传入的几何缩放，不能悄悄退回 `bars`——
    /// 传 `workingBars` 进去，结果要是 workingBars 缩放后的值。
    @Test func rectsScalesGivenBarsNotDefault() {
        let rects = VMark.rects(VMark.workingBars, in: CGRect(x: 10, y: 20, width: 100, height: 100))
        #expect(rects.count == 5)
        #expect(abs(rects[0].height - (22.0 / 56) * 100) < 0.1)
    }

    // MARK: - scripts/render-icon.swift 几何同步（机器守卫，不是注释承诺）

    /// `scripts/render-icon.swift` 跑在 SPM 包之外（`swift scripts/render-icon.swift
    /// <目录>`），不能 `import vInput`，只能手抄一份 `VMark.bars`（56 单位、
    /// 未归一化）。这条测试是唯一防漂移的机器：抄错/漏改一个数字，光靠注释
    /// 承诺没人会红——菜单栏图标与 App 图标会悄悄长得不一样，且不会有任何
    /// 编译错误或测试失败提示这件事，直到有人拿两张图标目测对比。
    ///
    /// 判据是**把两边都换算成同一单位后逐项比较数值**，不是「文件里有没有
    /// 出现这几个数字」那种字符串包含检查——后者对「数字换了位置但仍在文件
    /// 里」这类改法是瞎的。
    @Test func vMarkGeometryMatchesIconScript() throws {
        let source = try Self.renderIconSource()

        let scriptBars: [(x: Double, y: Double, width: Double, height: Double)]
        do {
            scriptBars = try Self.parseBarsIn56(from: source)
        } catch {
            // 解析本身失败（锚点没找到/数组没收尾），跟"几何数字对不上"是两件
            // 完全不同的事，绝不能混着报——见下面 parseBarsIn56 里的详细说明。
            Issue.record("解析 scripts/render-icon.swift 的 barsIn56 失败：\(error)")
            return
        }

        guard scriptBars.count == VMark.bars.count else {
            Issue.record(
                """
                scripts/render-icon.swift 里 barsIn56 解出 \(scriptBars.count) 条，
                Theme.swift 的 VMark.bars 有 \(VMark.bars.count) 条。这可能是真的
                几何改动（加/删了一根柱子），也可能是脚本排版变了导致解析漏掉了
                某几条——两种都有可能、分不清之前，**不是几何漂移的确证**：先去
                scripts/render-icon.swift 里手数一遍 barsIn56 实际有几条，再判断
                是该改数据还是改这条测试的解析器。数目已经对不上、位置多半错位，
                这里不再逐根柱子比对（比了也是噪音，会指认根本不存在的柱子）。
                """
            )
            return
        }

        for i in 0..<scriptBars.count {
            let script = scriptBars[i]
            let theme = VMark.bars[i]
            // 脚本里是 56 单位的绝对数，Theme.swift 是归一化到 0…1 的分数，
            // 换算成同一单位（除以 56）才能比。
            let matches =
                abs(script.x / 56 - theme.minX) < 1e-9
                    && abs(script.y / 56 - theme.minY) < 1e-9
                    && abs(script.width / 56 - theme.width) < 1e-9
                    && abs(script.height / 56 - theme.height) < 1e-9
            #expect(
                matches,
                """
                第 \(i) 根柱子的几何对不上：
                render-icon.swift（56 单位）= \(script)
                VMark.bars（归一化，×56 还原）= \
                (x: \(theme.minX * 56), y: \(theme.minY * 56), \
                width: \(theme.width * 56), height: \(theme.height * 56))
                两处数字已经漂移——菜单栏图标与 App 图标会长得不一样。改了
                Theme.swift 的 VMark.bars 之后，记得同步
                scripts/render-icon.swift 里的 barsIn56，反之亦然。
                """
            )
        }
    }

    // MARK: - scripts/render-icon.swift 配色同步（同一套机器守卫，扩到颜色上）

    /// 几何有机器守卫之后，颜色曾经只剩一句注释「照抄 VITheme」，没人核对——
    /// 复核实测过：把脚本里的琥珀渐变改成绿色，旧版这条测试文件照样全绿。
    /// 这里核对四个颜色：`VITheme.iconTileTop/iconTileBottom`（瓦片深色渐变）
    /// 与 `VITheme.accentGradientTop/accentGradientBottom`（琥珀渐变），按它们
    /// 在 render-icon.swift 源码里出现的顺序（瓦片渐变先画、V mark 渐变后画）
    /// 逐一比对 RGB 分量。
    @Test @MainActor func vMarkColorsMatchIconScript() throws {
        let source = try Self.renderIconSource()

        let scriptColors: [(r: Double, g: Double, b: Double)]
        do {
            scriptColors = try Self.parseNSColors(from: source)
        } catch {
            Issue.record("解析 scripts/render-icon.swift 的 NSColor 字面量失败：\(error)")
            return
        }

        // 源码里的出现顺序：瓦片渐变起 → 瓦片渐变止 → V mark 渐变起 → V mark 渐变止。
        let themeColors: [(name: String, color: Color)] = [
            ("iconTileTop", VITheme.iconTileTop),
            ("iconTileBottom", VITheme.iconTileBottom),
            ("accentGradientTop", VITheme.accentGradientTop),
            ("accentGradientBottom", VITheme.accentGradientBottom),
        ]

        guard scriptColors.count == themeColors.count else {
            Issue.record(
                """
                render-icon.swift 里解出 \(scriptColors.count) 个
                NSColor(red:green:blue:alpha:) 字面量，预期 \(themeColors.count) 个
                （瓦片渐变两端 + V mark 渐变两端）。可能是脚本加/删了一处渐变色，
                也可能是格式变了导致解析漏掉——先去脚本里手数一遍，再判断是该
                改数据还是改这条测试的解析器；这里不再逐个颜色比对（数目对不上，
                位置多半错位）。
                """
            )
            return
        }

        for (i, expected) in themeColors.enumerated() {
            let script = scriptColors[i]
            let (r, g, b) = Self.rgbComponents(of: expected.color)
            // 容差 1e-6：实测 `Color → NSColor(.deviceRGB)` 桥接的最大误差是
            // 4.3e-08（四个颜色逐个量的），留 20 倍余量。
            //
            // **原来写的 0.01 宽了二十三万倍，而且同一个文件里就有碰撞**：
            // `VITheme.contentBackground` 是 (0.165, 0.165, 0.176)、
            // `iconTileTop` 是 (0.165, 0.165, 0.180)，蓝色分量只差 0.004——
            // 正好在旧容差内。抄错成相邻那个常量，这条测试照样绿，
            // 而它存在的理由恰恰是抓这一类。
            let matches = abs(script.r - r) < 1e-6 && abs(script.g - g) < 1e-6 && abs(script.b - b) < 1e-6
            #expect(
                matches,
                """
                第 \(i) 个颜色（对应 VITheme.\(expected.name)）对不上：
                render-icon.swift = (r: \(script.r), g: \(script.g), b: \(script.b))
                VITheme.\(expected.name) = (r: \(r), g: \(g), b: \(b))
                两处颜色已经漂移——App 图标会和 HUD/面板/菜单栏图标用的颜色不一致。
                改了 Theme.swift 的 VITheme 之后，记得同步
                scripts/render-icon.swift 里对应的 NSColor 字面量，反之亦然。
                """
            )
        }
    }

    @MainActor
    private static func rgbComponents(of color: Color) -> (r: Double, g: Double, b: Double) {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color)
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }

    private static func renderIconSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // vInputTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
        return try String(
            contentsOf: root.appendingPathComponent("scripts/render-icon.swift"),
            encoding: .utf8
        )
    }

    private struct SourceParseFailure: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    /// 定位 `barsIn56` 数组、解析出每根柱子的 (x, y, width, height)。
    ///
    /// 锚点故意用正则而不是整段字面量字符串：早先用
    /// `"let barsIn56: [CGRect] = ["` 精确字面量匹配，只要脚本里这行的空格、
    /// 类型注解写法稍有不同（哪怕语义完全不变），匹配就会失败，而失败信息
    /// 只会说「数目对不上」——读的人会去找根本不存在的几何漂移。改成正则
    /// `let\s+barsIn56\b[^=]*=\s*\[` 之后：
    /// - `\s+` 容忍空白变化；
    /// - `[^=]*` 吃掉 `barsIn56` 与 `=` 之间的任何字符，**包括类型注解自带
    ///   的方括号**。第一版写的是 `[^=\[]*`，吃不过方括号，于是
    ///   `let barsIn56: [CGRect] = [` 这种最常见的写法会误报「锚点失效」；
    ///   当时的处置是去脚本里写一条「声明不许带类型注解」的禁令——**用一条
    ///   新的口头约束去还旧的口头约束，方向还反了**（测试为脚本服务，
    ///   不是倒过来）。放宽一个字符即可，三种写法都认（实测）；
    /// - 找不到锚点、或找不到收尾的 `]`，都视为**解析失败**而不是「柱子数
    ///   量变了」，调用方要把这两类失败分开报告。
    ///
    /// 数组体内逐条 `CGRect(...)` 用另一条正则解析，`CGRect\(` 之后补了
    /// `\s*`——不补的话，光是在 `CGRect(` 后面换一行（纯排版，语义不变）
    /// 就会让这一条解析失败、总数少一条，连带把后面每一根柱子的下标都错位，
    /// 报出一串「第 N 根柱子对不上」的假指控（复核实测过）。
    private static func parseBarsIn56(
        from source: String
    ) throws -> [(x: Double, y: Double, width: Double, height: Double)] {
        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)

        // `[^=]*` 而不是 `[^=\[]*`：后者认不出 `let barsIn56: [CGRect] = [`
        // ——类型注解自带的方括号会把锚点截断。第一版为此在脚本里写了一条
        // 「声明不许带类型注解」的禁令，那是**用一条新的口头约束去还旧的
        // 口头约束**，方向还反了（测试是为脚本服务的，不是倒过来）。
        // 放宽一个字符即可，三种写法都认，真漂移照样抓得住。
        let anchorPattern = #"let\s+barsIn56\b[^=]*=\s*\["#
        let anchorRegex = try NSRegularExpression(pattern: anchorPattern)
        guard let anchorMatch = anchorRegex.firstMatch(in: source, range: fullRange) else {
            throw SourceParseFailure(
                reason: """
                没能定位到 barsIn56 数组的声明（锚点 "\(anchorPattern)" 没匹配上）。
                大概率是脚本被重排版了（改了变量名、加回了类型注解），不是几何
                被删空——去检查/更新这条测试的解析锚点，不要去动
                render-icon.swift 里的坐标数字。
                """
            )
        }

        let arrayBodyStart = anchorMatch.range.location + anchorMatch.range.length
        let searchRange = NSRange(location: arrayBodyStart, length: nsSource.length - arrayBodyStart)
        let closeRange = nsSource.range(of: "]", options: [], range: searchRange)
        guard closeRange.location != NSNotFound else {
            throw SourceParseFailure(
                reason: "找到了 barsIn56 数组开头，但没找到收尾的 \"]\"——脚本可能被截断了，不是几何漂移。"
            )
        }

        let body = nsSource.substring(with: NSRange(location: arrayBodyStart, length: closeRange.location - arrayBodyStart))
        let itemPattern = #"CGRect\(\s*x:\s*([\d.]+),\s*y:\s*([\d.]+),\s*width:\s*([\d.]+),\s*height:\s*([\d.]+)\s*\)"#
        let itemRegex = try NSRegularExpression(pattern: itemPattern)
        let nsBody = body as NSString
        let matches = itemRegex.matches(in: body, range: NSRange(location: 0, length: nsBody.length))

        return matches.map { match in
            let x = Double(nsBody.substring(with: match.range(at: 1)))!
            let y = Double(nsBody.substring(with: match.range(at: 2)))!
            let width = Double(nsBody.substring(with: match.range(at: 3)))!
            let height = Double(nsBody.substring(with: match.range(at: 4)))!
            return (x, y, width, height)
        }
    }

    /// 解析脚本全文里所有 `NSColor(red:green:blue:alpha:)` 字面量，按出现
    /// 顺序返回。不像 `parseBarsIn56` 那样先框定一个数组范围——脚本里这四处
    /// 颜色分散在两个 `NSGradient(...)` 调用里，没有一个共同的外层数组可框，
    /// 直接按源码顺序解析即可（顺序本身就是调用方要核对的东西之一）。
    private static func parseNSColors(from source: String) throws -> [(r: Double, g: Double, b: Double)] {
        let pattern = #"NSColor\(\s*red:\s*([\d.]+),\s*green:\s*([\d.]+),\s*blue:\s*([\d.]+),\s*alpha:\s*([\d.]+)\s*\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsSource = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
        return matches.map { match in
            let r = Double(nsSource.substring(with: match.range(at: 1)))!
            let g = Double(nsSource.substring(with: match.range(at: 2)))!
            let b = Double(nsSource.substring(with: match.range(at: 3)))!
            return (r, g, b)
        }
    }
}
