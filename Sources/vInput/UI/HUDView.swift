import SwiftUI

/// HUD 的内容。
///
/// **不含任何可点击控件**——面板不抢焦点，鼠标事件不会送达，
/// 放按钮只会造成「点了没反应」的困惑。所有操作靠键盘。
struct HUDView: View {
    let model: HUDViewModel

    /// 文本框固定高度。固定而非自适应，是为了让面板尺寸在整场会话中
    /// 不变——高度随文字增减会让面板不停跳动，比文字本身更干扰。
    private var transcriptHeight: CGFloat {
        lineHeight * CGFloat(HUDViewModel.maxLines) + 20
    }
    private let lineHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            transcriptBox
            footer
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        )
    }

    // MARK: - 顶部状态条

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(model.statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(model.durationText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            WaveformView(bars: model.bars)
        }
    }

    // MARK: - 预览文本框

    /// 预览文字有自己的框。
    ///
    /// 真机反馈说文字「不在一个清晰的文本框内」看不清楚——原先文字直接
    /// 浮在毛玻璃背景上，与状态、按键提示混在一起，没有视觉边界。
    private var transcriptBox: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))

            transcriptText
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(height: transcriptHeight)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var transcriptText: some View {
        if model.confirmedLines.isEmpty && model.unconfirmedText.isEmpty {
            Text(placeholder)
                .font(.system(size: 15))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            // 已确认用正常颜色、未确认用半透明：没有这个区分的话，
            // 文本会时不时整段跳变，观感如同故障。
            (Text(model.confirmedLines.joined(separator: "\n"))
                .foregroundStyle(.primary)
             + Text(model.unconfirmedText)
                .foregroundStyle(.secondary))
                .font(.system(size: 15))
                .lineSpacing(5)
                .multilineTextAlignment(.leading)
                .lineLimit(HUDViewModel.maxLines)
                // 超出时截掉开头、保留最新——说话是往后走的，
                // 该看到的永远是刚说完的那几句。
                .truncationMode(.head)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .animation(.easeOut(duration: 0.12), value: model.confirmedLines)
        }
    }

    private var placeholder: String {
        switch model.phase {
        case .listening: "开始说话…"
        case .transcribing, .correcting, .injecting: "正在整理…"
        case .idle: ""
        }
    }

    // MARK: - 底部按键提示

    private var footer: some View {
        HStack(spacing: 16) {
            keyHint("⌥D", "完成")
            keyHint("esc", "取消")
            Spacer(minLength: 0)
        }
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                )
            Text(action)
                .font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
    }

    private var statusColor: Color {
        switch model.phase {
        case .idle: .secondary
        case .listening: .red
        case .transcribing, .correcting, .injecting: .orange
        }
    }
}
