import ApplicationServices
import CoreGraphics
import Foundation

/// 通过合成键盘事件把文本送进当前焦点输入框。
///
/// 使用 `CGEventKeyboardSetUnicodeString` 而非逐个键码，
/// 因此不依赖当前输入法，中文与 emoji 都能直接送出。
@MainActor
struct TypingSink: TextSink {
    /// 每个事件携带的 UTF-16 单元数。
    /// 太大部分应用会截断，太小则整体变慢。20 是经验上的平衡点。
    var chunkSize: Int = 20

    /// 块之间的间隔。给接收方的事件循环留出处理时间，
    /// 否则终端与部分 Electron 应用会丢字或乱序。
    var interChunkDelay: TimeInterval = 0.004

    /// 可注入，便于测试时绕开真实的权限检查。
    var isAccessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }

    func send(_ text: String) throws {
        guard !text.isEmpty else { return }
        guard isAccessibilityTrusted() else {
            throw TextSinkError.accessibilityDenied
        }

        let units = Array(text.utf16)
        let ranges = Self.chunkRanges(
            unitCount: units.count,
            chunkSize: chunkSize,
            units: units
        )

        for (index, range) in ranges.enumerated() {
            var chunk = Array(units[range])

            guard
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else {
                throw TextSinkError.eventCreationFailed
            }

            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)

            if index < ranges.count - 1 {
                Thread.sleep(forTimeInterval: interChunkDelay)
            }
        }
    }

    // MARK: - 分块

    /// 把 UTF-16 单元序列切成不超过 `chunkSize` 的若干段，
    /// 并保证不在代理对中间切开。
    ///
    /// 抽成 nonisolated 静态纯函数以便单元测试——它不碰任何
    /// 主线程状态，测试无需 @MainActor 隔离即可直接调用。
    nonisolated static func chunkRanges(
        unitCount: Int,
        chunkSize: Int,
        units: [UInt16]
    ) -> [Range<Int>] {
        guard unitCount > 0, chunkSize > 0 else { return [] }

        var ranges: [Range<Int>] = []
        var start = 0
        while start < unitCount {
            var end = min(start + chunkSize, unitCount)
            // 若边界落在高位代理上，把它让给下一块。
            if end < unitCount, isHighSurrogate(units[end - 1]) {
                end -= 1
            }
            // 退化保护：单个代理对本身超过块大小时，至少推进一个单元。
            if end <= start { end = min(start + chunkSize, unitCount) }
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    nonisolated private static func isHighSurrogate(_ unit: UInt16) -> Bool {
        (0xD800...0xDBFF).contains(unit)
    }
}
