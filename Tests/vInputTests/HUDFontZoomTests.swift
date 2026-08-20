import Foundation
import Testing
@testable import vInput

/// 字号缩放：范围 12–24、步进 1、默认 15、持久化、行高/行宽估算等比换算。
@MainActor
struct HUDFontZoomTests {
    /// 每条用例独立的 UserDefaults，互不污染、不碰真实偏好。
    private func makeDefaults() -> UserDefaults {
        let name = "hud-font-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsToFifteen() {
        #expect(HUDViewModel(defaults: makeDefaults()).fontSize == 15)
    }

    @Test func clampStopsAtBounds() {
        // 钉字面量：12/24 是设计定稿里的数，不引用常量（会对变异自适应）。
        #expect(HUDViewModel.clampFontSize(11) == 12)
        #expect(HUDViewModel.clampFontSize(25) == 24)
        #expect(HUDViewModel.clampFontSize(18) == 18)
    }

    @Test func stepAndReset() {
        let model = HUDViewModel(defaults: makeDefaults())
        model.increaseFontSize()
        #expect(model.fontSize == 16)
        model.resetFontSize()
        #expect(model.fontSize == 15)
        for _ in 0..<20 { model.decreaseFontSize() }
        #expect(model.fontSize == 12)
    }

    @Test func persistsAcrossInstances() {
        let defaults = makeDefaults()
        let first = HUDViewModel(defaults: defaults)
        first.increaseFontSize()
        first.increaseFontSize()   // 17
        let second = HUDViewModel(defaults: defaults)
        #expect(second.fontSize == 17)
    }

    /// 存储里被写坏成越界值时，读回来要钳位而不是照单全收。
    @Test func clampsCorruptStoredValue() {
        let defaults = makeDefaults()
        defaults.set(99.0, forKey: HUDViewModel.fontSizeDefaultsKey)
        #expect(HUDViewModel(defaults: defaults).fontSize == 24)
    }

    /// 行高等比：现值 15pt→26pt，两端取整。钉三个字面量点。
    @Test func lineHeightScales() {
        #expect(HUDViewModel.lineHeight(forFontSize: 15) == 26)
        #expect(HUDViewModel.lineHeight(forFontSize: 12) == 21)
        #expect(HUDViewModel.lineHeight(forFontSize: 24) == 42)
    }

    /// 行宽估算等比：现值 15pt→22 字（15×22=330 恒定积）。字号大→每行字少。
    @Test func charsPerLineScales() {
        #expect(HUDViewModel.charsPerLine(forFontSize: 15) == 22)
        #expect(HUDViewModel.charsPerLine(forFontSize: 24) == 13)
        #expect(HUDViewModel.charsPerLine(forFontSize: 12) == 27)
    }

    /// 接线测试：`confirmedLines` 必须真的用上动态字号折行，而不是仍读
    /// 静态的 `Self.charsPerLine`（22）。20 个汉字在 24pt（每行 13 字）
    /// 要折成 2 行，在 15pt（每行 22 字）仍是 1 行。
    @Test func confirmedLinesUsesDynamicFontSize() {
        let model = HUDViewModel(defaults: makeDefaults())
        let text = String(repeating: "字", count: 20)
        model.preview = PreviewText(confirmed: text, unconfirmed: "", energy: [])

        model.fontSize = 24
        #expect(model.confirmedLines.count == 2)

        model.fontSize = 15
        #expect(model.confirmedLines.count == 1)
    }
}
