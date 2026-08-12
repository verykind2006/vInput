import SwiftUI

/// HUD 的内容。
///
/// **不含任何可点击控件**——面板不抢焦点，鼠标事件不会送达，
/// 放按钮只会造成「点了没反应」的困惑。所有操作靠键盘。
struct HUDView: View {
    let model: HUDViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            transcript
            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(model.durationText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            WaveformView(bars: model.bars)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if model.confirmedLines.isEmpty && model.unconfirmedText.isEmpty {
            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(height: 22 * CGFloat(HUDViewModel.maxLines), alignment: .topLeading)
        } else {
            // 已确认用正常颜色、未确认用半透明：没有这个区分的话，
            // 文本会时不时整段跳变，观感如同故障。
            (Text(model.confirmedLines.joined())
                .foregroundStyle(.primary)
             + Text(model.unconfirmedText)
                .foregroundStyle(.secondary.opacity(0.6)))
                .font(.callout)
                .frame(
                    height: 22 * CGFloat(HUDViewModel.maxLines),
                    alignment: .topLeading
                )
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label("⌥D 完成", systemImage: "checkmark.circle")
            Label("Esc 取消", systemImage: "xmark.circle")
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .labelStyle(.titleOnly)
    }

    private var statusColor: Color {
        switch model.phase {
        case .idle: .secondary
        case .listening: .red
        case .transcribing, .injecting: .orange
        }
    }
}
