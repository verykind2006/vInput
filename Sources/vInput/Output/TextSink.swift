import Foundation

enum TextSinkError: Error, Equatable {
    /// 未获得辅助功能授权，无法发送 CGEvent。
    case accessibilityDenied
    /// CGEvent 创建失败。
    case eventCreationFailed
    /// 目标应用在会话期间发生了变化。
    case targetApplicationChanged(expected: String?, actual: String?)
}

/// 把文本送到当前焦点位置。
///
/// 声明为 @MainActor：所有实现都要操作 AppKit 全局状态
/// （剪贴板、CGEvent、前台应用），且调用方 DictationSession
/// 本身就在主线程。若 protocol 不隔离，@MainActor 的实现类型
/// 无法满足其要求，在 Swift 6 语言模式下会直接编译失败。
@MainActor
protocol TextSink {
    func send(_ text: String) throws
}
