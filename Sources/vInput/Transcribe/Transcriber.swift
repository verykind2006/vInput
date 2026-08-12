import Foundation

enum TranscribeError: Error, Equatable {
    /// 模型尚未下载或加载完成。
    case modelNotReady
    /// 底层引擎报错。
    case engineFailed(String)
    /// 输入音频过短，不值得转写。
    case audioTooShort
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
