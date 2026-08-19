import Testing
@testable import vInput

@Suite("HUDViewModel")
struct HUDViewModelTests {

    // MARK: - 时长格式化

    @Test("时长格式化为分:秒")
    func formatsDuration() {
        #expect(HUDViewModel.formatDuration(0) == "0:00")
        #expect(HUDViewModel.formatDuration(7) == "0:07")
        #expect(HUDViewModel.formatDuration(59) == "0:59")
        #expect(HUDViewModel.formatDuration(60) == "1:00")
        #expect(HUDViewModel.formatDuration(125) == "2:05")
    }

    @Test("负数时长按零处理")
    func negativeDurationIsZero() {
        #expect(HUDViewModel.formatDuration(-5) == "0:00")
    }

    // MARK: - 文本截断

    @Test("短文本原样保留")
    func shortTextUnchanged() {
        let lines = HUDViewModel.tailLines("一行文字", maxLines: 4, charsPerLine: 20)
        #expect(lines == ["一行文字"])
    }

    @Test("长文本按每行字数折行")
    func wrapsLongText() {
        let text = String(repeating: "字", count: 45)
        let lines = HUDViewModel.tailLines(text, maxLines: 4, charsPerLine: 20)

        #expect(lines.count == 3)
        #expect(lines[0].count == 20)
        #expect(lines[2].count == 5)
    }

    @Test("超过上限时只保留末尾若干行")
    func keepsOnlyTailLines() {
        let text = String(repeating: "字", count: 200)   // 10 行
        let lines = HUDViewModel.tailLines(text, maxLines: 4, charsPerLine: 20)

        #expect(lines.count == 4)
    }

    @Test("空文本产出空数组")
    func emptyTextYieldsNoLines() {
        #expect(HUDViewModel.tailLines("", maxLines: 4, charsPerLine: 20).isEmpty)
    }

    // MARK: - 波形采样

    @Test("能量数据降采样到指定条数")
    func downsamplesEnergy() {
        let energy = (0..<100).map { Float($0) / 100 }
        let bars = HUDViewModel.waveformBars(from: energy, barCount: 10)
        #expect(bars.count == 10)
    }

    @Test("能量少于条数时前面补零")
    func padsWhenEnergyIsShort() {
        let bars = HUDViewModel.waveformBars(from: [0.5, 0.8], barCount: 5)

        #expect(bars.count == 5)
        #expect(bars[0] == 0)
        #expect(bars[4] == 0.8)
    }

    @Test("空能量产出全零")
    func emptyEnergyYieldsZeros() {
        let bars = HUDViewModel.waveformBars(from: [], barCount: 5)
        #expect(bars == [0, 0, 0, 0, 0])
    }

    @Test("波形值被夹在 0…1")
    func clampsBars() {
        let bars = HUDViewModel.waveformBars(from: [-0.5, 2.0], barCount: 2)
        #expect(bars.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    // MARK: - 状态文案

    @Test("各阶段的状态文案")
    func statusLabels() {
        #expect(HUDViewModel.statusLabel(for: .listening, previewDegraded: false) == "正在聆听")
        #expect(HUDViewModel.statusLabel(for: .transcribing, previewDegraded: false) == "正在转写")
        #expect(HUDViewModel.statusLabel(for: .correcting, previewDegraded: false) == "正在校正")
        // 翻译与校正分开显示：两者都是数秒量级的等待，共用一句文案会让用户
        // 以为卡在校正上。**呈现细节归 Task 11**，这里只钉住「有自己的一句话」。
        #expect(HUDViewModel.statusLabel(for: .translating, previewDegraded: false) == "正在翻译")
        #expect(HUDViewModel.statusLabel(for: .injecting, previewDegraded: false) == "正在输入")
    }

    @Test("预览降级时状态文案给出提示")
    func degradedLabel() {
        #expect(HUDViewModel.statusLabel(for: .listening, previewDegraded: true) == "正在聆听（预览已暂停）")
    }
}
