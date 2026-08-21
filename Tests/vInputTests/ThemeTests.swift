import CoreGraphics
import Foundation
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
        let scriptBars = try Self.parseBarsIn56(from: source)

        #expect(
            scriptBars.count == VMark.bars.count,
            """
            scripts/render-icon.swift 里 barsIn56 解出 \(scriptBars.count) 条，
            Theme.swift 的 VMark.bars 有 \(VMark.bars.count) 条——数目对不上，
            要么脚本的数组被改动过，要么这条测试的解析锚点失效了。
            """
        )

        for i in 0..<min(scriptBars.count, VMark.bars.count) {
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

    /// 只在 `let barsIn56 = [...]` 这个数组字面量的范围内找 `CGRect(x:…)`，
    /// 不扫全文件——脚本里另有两处 `CGRect(...)`（tile、mark），参数是
    /// `side * 0.1` 这类表达式而非数字字面量，本来就匹配不上这条纯数字
    /// 正则，但把搜索范围收在数组内更明确，也不依赖这个巧合。
    private static func parseBarsIn56(
        from source: String
    ) throws -> [(x: Double, y: Double, width: Double, height: Double)] {
        // 精确锚到「= [」之后：只搜 "let barsIn56" 会连类型注解 `[CGRect]`
        // 里那个 `]` 一起框进来，导致下面找「第一个 ]」时提前收口，一条都
        // 解不出来（已实测踩过）。
        guard let arrayStart = source.range(of: "let barsIn56: [CGRect] = [") else {
            struct ArrayNotFound: Error {}
            throw ArrayNotFound()
        }
        guard let arrayEnd = source.range(of: "]", range: arrayStart.upperBound..<source.endIndex) else {
            struct ArrayNotClosed: Error {}
            throw ArrayNotClosed()
        }
        let arraySlice = String(source[arrayStart.upperBound..<arrayEnd.upperBound])

        let pattern = #"CGRect\(x:\s*([\d.]+),\s*y:\s*([\d.]+),\s*width:\s*([\d.]+),\s*height:\s*([\d.]+)\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let nsSlice = arraySlice as NSString
        let matches = regex.matches(in: arraySlice, range: NSRange(location: 0, length: nsSlice.length))

        return matches.map { match in
            let x = Double(nsSlice.substring(with: match.range(at: 1)))!
            let y = Double(nsSlice.substring(with: match.range(at: 2)))!
            let width = Double(nsSlice.substring(with: match.range(at: 3)))!
            let height = Double(nsSlice.substring(with: match.range(at: 4)))!
            return (x, y, width, height)
        }
    }
}
