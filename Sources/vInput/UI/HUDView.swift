import SwiftUI

/// HUD 的内容。
///
/// **不含任何可点击控件**——面板不抢焦点，鼠标事件不会送达，
/// 放按钮只会造成「点了没反应」的困惑。所有操作靠键盘。
struct HUDView: View {
    let model: HUDViewModel

    /// 版式算术（行高/行距/文本框高度）全部搬进了 HUDViewModel 的纯函数——
    /// 视图只画，不算；这样这几条公式能单测（见 HUDFontZoomTests 的不变量测试）。
    private var transcriptHeight: CGFloat {
        HUDViewModel.transcriptHeight(forFontSize: model.fontSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            transcriptBox
            if let notice = model.notice { noticeRow(notice) }
            footer
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 480)
        .background(VITheme.panelBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(VITheme.hairline, lineWidth: 1)
        )
        // HUD 底色是写死的深色 VITheme.panelBackground，而正文用的
        // `.primary` / `.secondary` / `.tertiary` 会跟着系统外观走——浅色
        // 模式下不钉死的话，预览文字就是黑字压深底（实测 aqua 外观下
        // `.primary`/`.secondary` 亮度 0.000，底色亮度 0.115），几乎读不出来。
        // 而开发机常年深色模式，这种缺陷在自己机器上永远看不见。
        // 放在修饰链最外层：environment 往下传，这样 background/overlay
        // 连同整棵子树都被覆盖。菜单面板同款（MenuPanelView.swift）。
        .environment(\.colorScheme, .dark)
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
            WaveformView(bars: model.bars, tint: model.phase == .listening ? VITheme.accent : .secondary)
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
                .fill(VITheme.contentBackground)

            transcriptText
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(height: transcriptHeight)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(VITheme.hairline, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var transcriptText: some View {
        if model.confirmedLines.isEmpty && model.unconfirmedText.isEmpty {
            Text(placeholder)
                .font(.system(size: model.fontSize))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            // 已确认用正常颜色、未确认用半透明：没有这个区分的话，
            // 文本会时不时整段跳变，观感如同故障。
            (Text(model.confirmedLines.joined(separator: "\n"))
                .foregroundStyle(.primary)
             + Text(model.unconfirmedText)
                .foregroundStyle(.secondary))
                .font(.system(size: model.fontSize))
                .lineSpacing(HUDViewModel.lineSpacing(forFontSize: model.fontSize))
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
        case .transcribing, .correcting, .translating, .injecting: "正在整理…"
        case .idle: ""
        }
    }

    // MARK: - 附注

    /// 一行附注，出现在文本框与按键提示之间。
    ///
    /// 位置刻意不放在顶部状态条里：那一行已经挤了状态、时长与波形，而附注
    /// 出现的时刻（会话末尾）恰恰是波形停下、用户视线该被拉过来的时刻。
    private func noticeRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - 底部按键提示

    private var footer: some View {
        HStack(spacing: 16) {
            keyHint("⌥D", "完成")
            keyHint("esc", "取消")
            Spacer(minLength: 0)
            keyHint("⌘＋/－", "字号")
            // ⌘0 早就注册了（ZoomHotkeyController.onReset），但一直没地方告诉用户——
            // 调过头之后最想要的恰恰是这个键。
            keyHint("⌘0", "复位")
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

    // 琥珀橙=正在收音的品牌信号；处理中波形停走+灰点即足够，双色告警反而抢戏——
    // 旧版 listening=红、处理中=橙，两种警示色并列容易让人误读成异常状态。
    private var statusColor: Color {
        switch model.phase {
        case .idle: .secondary
        case .listening: VITheme.accent
        case .transcribing, .correcting, .translating, .injecting: .secondary
        }
    }
}
