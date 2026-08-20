import Foundation
import Observation

/// HUD 的展示逻辑。
///
/// 全部计算做成 `nonisolated static` 纯函数，视图只负责画——
/// 这样展示逻辑可以完整单测，而 SwiftUI 视图本身无需测试。
@MainActor
@Observable
final class HUDViewModel {
    /// 文本区固定行数，超出后只显示末尾若干行。
    static let maxLines = 4
    /// 波形柱数。
    static let barCount = 24

    // MARK: - 字号缩放（M9，用户要求 ⌘＋/⌘－ 可调）

    static let minFontSize: CGFloat = 12
    static let maxFontSize: CGFloat = 24
    static let defaultFontSize: CGFloat = 15
    static let fontSizeDefaultsKey = "hud.previewFontSize"

    private let defaults: UserDefaults
    private(set) var fontSize: CGFloat

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.fontSizeDefaultsKey)
        // 0 兼作「未设置」哨兵：合法值域 12–24 不含 0，写坏成 0 时回默认值是比 clamp(0)=12 更合理的恢复
        self.fontSize = stored == 0 ? Self.defaultFontSize : Self.clampFontSize(CGFloat(stored))
    }

    func increaseFontSize() { setFontSize(fontSize + 1) }
    func decreaseFontSize() { setFontSize(fontSize - 1) }
    func resetFontSize() { setFontSize(Self.defaultFontSize) }

    private func setFontSize(_ raw: CGFloat) {
        fontSize = Self.clampFontSize(raw)
        defaults.set(Double(fontSize), forKey: Self.fontSizeDefaultsKey)
    }

    var phase: DictationSession.State = .idle
    var preview: PreviewText = .empty
    var elapsed: TimeInterval = 0
    /// 音量能量。**与 `preview` 分开**：文本来自流式转写的状态回调
    /// （1–2 秒一次），而波形要 20 fps 才不卡顿，由计时器直接从
    /// `SourceBackedAudioProcessor` 读取。
    var energy: [Float] = []
    /// 预览落后实时超过阈值后置位，文本停止更新但音量与时长照常。
    var previewDegraded = false
    /// 一行附注：通知发不出去时的退路提示、「本次未校正」等。nil 表示没有。
    ///
    /// **与 `statusText` 分开是必须的**：状态描述的是当前阶段，会随阶段推进
    /// 被覆盖掉；而附注产生的时刻恰恰是会话末尾——面板马上就要关了。
    /// 混在一起的话，用户永远看不到它（`AppModel` 为此让 HUD 多停留几秒）。
    var notice: String?

    var durationText: String { Self.formatDuration(elapsed) }
    var confirmedLines: [String] {
        Self.tailLines(
            preview.confirmed,
            maxLines: Self.maxLines,
            charsPerLine: Self.charsPerLine(forFontSize: fontSize)
        )
    }
    var unconfirmedText: String { preview.unconfirmed }
    var bars: [Float] { Self.waveformBars(from: energy, barCount: Self.barCount) }
    var statusText: String { Self.statusLabel(for: phase, previewDegraded: previewDegraded) }

    // MARK: - 纯函数

    nonisolated static func clampFontSize(_ size: CGFloat) -> CGFloat {
        min(maxFontSize, max(minFontSize, size))
    }

    /// 行高随字号等比（现值 15→26），文本框高度由它 × maxLines 得出。
    nonisolated static func lineHeight(forFontSize size: CGFloat) -> CGFloat {
        (size * 26 / 15).rounded()
    }

    /// 每行字数估算随字号反比（15pt 锚点值=22，恒定积 330）。**刻意向下取整**：
    /// 低估每行字数 → 提前折行 → 永远不会溢出文本框；四舍五入会在 24pt 时
    /// 估出 14 字（13.75），实际装不下。
    nonisolated static func charsPerLine(forFontSize size: CGFloat) -> Int {
        max(1, Int(330 / size))
    }

    nonisolated static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 把文本折行后取末尾若干行。HUD 不可交互，因此不做滚动条。
    nonisolated static func tailLines(
        _ text: String,
        maxLines: Int,
        charsPerLine: Int
    ) -> [String] {
        guard !text.isEmpty, charsPerLine > 0, maxLines > 0 else { return [] }

        var lines: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count == charsPerLine {
                lines.append(current)
                current = ""
            }
        }
        if !current.isEmpty { lines.append(current) }

        return lines.count > maxLines ? Array(lines.suffix(maxLines)) : lines
    }

    /// 把能量序列降采样成固定数量的波形柱，取末尾（最新）的部分。
    nonisolated static func waveformBars(from energy: [Float], barCount: Int) -> [Float] {
        guard barCount > 0 else { return [] }
        guard !energy.isEmpty else { return Array(repeating: 0, count: barCount) }

        let tail = energy.suffix(barCount)
        let clamped = tail.map { min(1, max(0, $0)) }
        // 不足时在前面补零，使波形从右侧生长。
        let padding = Array(repeating: Float(0), count: barCount - clamped.count)
        return padding + clamped
    }

    nonisolated static func statusLabel(
        for phase: DictationSession.State,
        previewDegraded: Bool
    ) -> String {
        let base: String = switch phase {
        case .idle: "就绪"
        case .listening: "正在聆听"
        case .transcribing: "正在转写"
        // 与转写分开显示：校正可能耗时数秒，共用文案会让用户以为程序卡死
        case .correcting: "正在校正"
        // 与校正分开显示，理由同上：翻译同样是数秒量级的等待（M8 第 0 步实测
        // 单条最长 4.9 秒），共用「正在校正」会让用户以为卡在校正上。
        // **本轮只到文案为止**，「正在翻译」在 HUD 上怎么呈现（要不要图标、
        // 要不要进度）是 Task 11 的事。
        case .translating: "正在翻译"
        case .injecting: "正在输入"
        }
        if phase == .listening, previewDegraded {
            return base + "（预览已暂停）"
        }
        return base
    }
}
