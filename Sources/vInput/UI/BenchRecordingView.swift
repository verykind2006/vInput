import SwiftUI

/// 基准集录制窗口的内容。
///
/// 全部配色写死成白底黑字，不跟随系统深色模式：用户的原话是「灰色的字看得
/// 更加模糊」「白底黑字，这样我看得很清楚」。这里用 `.secondary` /
/// `.tertiary` 那套语义色是错的——它们正是那个「灰」。唯一的例外是录音中的
/// 红色，那是要一眼看出来的状态。
struct BenchRecordingView: View {
    let model: AppModel

    /// 标准文本字号。用户要照着它朗读，这是整个界面的主角。
    private let scriptFontSize: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            script
            Divider()
            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        // 录音中给整个窗口镶一道红边。用户在一两米外照读，按钮上的文字变化
        // 未必看得清，整块边框的颜色变化则一眼可辨。
        .overlay {
            if model.benchIsRecording {
                Rectangle()
                    .strokeBorder(Color.red, lineWidth: 6)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - 顶部：进度、类别、是否已录、录音状态

    private var header: some View {
        HStack(spacing: 14) {
            Text(model.benchSession?.progressText ?? "—")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black)

            if let category = model.benchSession?.current?.category {
                tag(category.displayName, background: Color.black.opacity(0.08))
            }

            // 已录状态读的是文件系统，@Observable 跟踪不到它。但本视图同时
            // 读了 benchIsRecording，录完那一刻状态翻转会重画整个 body，
            // 这个标记会跟着刷新。
            if model.benchSession?.currentIsRecorded == true {
                tag("已录", background: Color.green.opacity(0.25))
            } else {
                tag("未录", background: Color.black.opacity(0.08))
            }

            Spacer(minLength: 8)
            recordingIndicator
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var recordingIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.benchIsRecording ? Color.red : Color.black.opacity(0.25))
                .frame(width: 14, height: 14)
            Text(model.benchIsRecording ? "正在录音" : "未在录音")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(model.benchIsRecording ? Color.red : Color.black)
        }
    }

    private func tag(_ text: String, background: Color) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
    }

    // MARK: - 正文：标准文本

    /// 标准文本区。
    ///
    /// **一个字都不能少**：用户照着它读，截断了就录不出对得上参考答案的
    /// 音频（基准集里最长一条 64 字）。因此不设 lineLimit，并套一层
    /// ScrollView——窗口被拉小也只是要滚一下，永远不会把字裁掉。
    private var script: some View {
        Text(model.benchSession?.current?.text ?? "没有可录的条目")
            .font(.system(size: scriptFontSize, weight: .regular))
            .foregroundStyle(Color.black)
            .multilineTextAlignment(.center)
            .lineSpacing(10)
            // 窗口被拉小时宁可把字缩小，也不能截断——截断了就读不全。
            // 720×420 下最长的一条（64 字）约占三行，缩放不会真的发生。
            .minimumScaleFactor(0.5)
            .textSelection(.enabled)
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(Color.white)
    }

    // MARK: - 底部：按钮

    private var controls: some View {
        HStack(spacing: 14) {
            // 录音途中不许换条：写盘时取的是「当前条」，中途翻页会把这段
            // 音频存到另一条的名下，而且不会有任何报错。
            Button("← 上一条") { model.benchSession?.retreat() }
                .disabled(model.benchIsRecording)

            Button("下一条 →") { model.benchSession?.advance() }
                .disabled(model.benchIsRecording)

            Spacer(minLength: 8)

            Button(model.benchIsRecording ? "■ 结束录音" : "● 开始录音") {
                model.toggleBenchRecording()
            }
            .buttonStyle(.borderedProminent)
            .tint(model.benchIsRecording ? Color.red : Color.accentColor)
        }
        .font(.system(size: 17, weight: .medium))
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

private extension BenchCategory {
    /// 界面上的中文名。留在视图这边而不是加到 `BenchCategory` 上：
    /// 类别本身是数据模型的一部分，只有这个窗口需要把它显示给人看。
    var displayName: String {
        switch self {
        case .technical: "技术术语"
        case .punctuation: "长句标点"
        case .homophone: "同音陷阱"
        case .colloquial: "口语日常"
        // 这一类不进 manifest.json、录音界面永远列不到它（见 BenchCategory.digits）。
        // 写在这里只是为了让这个 switch 保持穷尽。
        case .digits: "数字金额"
        }
    }
}
