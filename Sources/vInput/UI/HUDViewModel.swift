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
    /// 每行大致容纳的字符数，用于折行估算。
    static let charsPerLine = 22
    /// 波形柱数。
    static let barCount = 24

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
        Self.tailLines(preview.confirmed, maxLines: Self.maxLines, charsPerLine: Self.charsPerLine)
    }
    var unconfirmedText: String { preview.unconfirmed }
    var bars: [Float] { Self.waveformBars(from: energy, barCount: Self.barCount) }
    var statusText: String { Self.statusLabel(for: phase, previewDegraded: previewDegraded) }

    // MARK: - 纯函数

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
        case .injecting: "正在输入"
        }
        if phase == .listening, previewDegraded {
            return base + "（预览已暂停）"
        }
        return base
    }
}
