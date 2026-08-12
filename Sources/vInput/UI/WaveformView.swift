import SwiftUI

/// 音量波形。回答的是「麦克风到底有没有收到我的声音」——
/// 看不见任何东西时这是最真实的焦虑。
struct WaveformView: View {
    let bars: [Float]

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2
    private let maxHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(.secondary)
                    .frame(
                        width: barWidth,
                        // 留 2pt 底座，静音时也能看出这里是波形而非空白
                        height: max(2, CGFloat(value) * maxHeight)
                    )
            }
        }
        .frame(height: maxHeight)
        .animation(.linear(duration: 0.05), value: bars)
    }
}
