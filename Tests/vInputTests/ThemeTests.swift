import CoreGraphics
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
        #expect(abs(rects[0].height - 85.7) < 0.1)
    }
}
