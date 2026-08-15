import Foundation

enum TranscribeError: Error, Equatable {
    /// 模型尚未下载或加载完成。
    case modelNotReady
    /// 底层引擎报错。
    case engineFailed(String)
    /// 输入音频过短，不值得转写。
    case audioTooShort
    /// 转写跑通了，但一个字都没解出来。
    ///
    /// **这不是「什么都没发生」，是一次失败。** 此前空结果被当成成功处理：
    /// 音频被丢、HUD 直接关闭、retry 也救不回来，用户说的话彻底消失且
    /// 没有任何线索——正是规则二要防的事。现在它走失败路径：保留音频、
    /// 报错、可重试。
    ///
    /// **注意：`DictationSession.retry()` 目前没有任何 UI 入口**
    /// （全仓搜索只有定义与测试在调它）。所以这条错误现在的作用是
    /// 「让用户知道自己说的话没落地，可以重说一遍」，音频保留是为了
    /// 日后接上重试入口时立刻可用。文案不承诺用户点得到重试。
    case emptyResult
}

/// 错误的中文说明。
///
/// `AppModel` 用 `String(describing:)` 把错误直接放进菜单栏，
/// 不写这个的话用户看到的是「出错：emptyResult」。
extension TranscribeError: CustomStringConvertible {
    var description: String {
        switch self {
        case .modelNotReady: "模型尚未就绪"
        case .engineFailed(let reason): "转写引擎出错：\(reason)"
        case .audioTooShort: "录音太短"
        case .emptyResult: "没有识别到内容"
        }
    }
}

/// 把 16 kHz 单声道浮点音频转换成文本。
protocol Transcriber: Sendable {
    /// 确保模型已加载。可重复调用，已就绪时立即返回。
    func prepare() async throws

    /// 转写整段音频。
    /// - Parameter samples: 16 kHz 单声道，取值 -1…1
    /// - Returns: 去除首尾空白的转写文本，可能为空字符串（静音）
    func transcribe(_ samples: [Float]) async throws -> String
}

/// 能够产出流式预览引擎的转写器。
///
/// 单独成一个协议而非并入 `Transcriber`：`FakeTranscriber` 与未来可能的
/// 云端转写器都不需要这个能力，不该被迫实现它。
protocol PreviewCapable {
    /// 基于当前已加载的模型构造一个预览引擎。
    ///
    /// - Parameter processor: 音频来源，由调用方推入样本
    /// - Returns: 预览引擎；模型尚未加载时返回 nil
    func makePreviewEngine(processor: SourceBackedAudioProcessor) async -> PreviewEngine?
}
