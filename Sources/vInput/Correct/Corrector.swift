import Foundation

/// 一条替换：把转写中的 `original` 换成 `replacement`。
struct CorrectionEdit: Equatable, Sendable {
    let original: String
    let replacement: String
}

enum CorrectorError: Error, Equatable {
    /// 模型尚未加载。
    case modelNotReady
    /// 底层引擎报错。
    case engineFailed(String)
    /// 推理超时。
    case timedOut
}

/// 找出转写中听错的字词，给出替换清单。
///
/// **实现只负责提出建议，不负责判断建议是否安全**——那是
/// `CorrectionGate` 的职责，且它位于本 protocol 之外，
/// 任何实现（本地、将来的云端）共用同一道闸门。
protocol Corrector: Sendable {
    /// 确保模型已加载。可重复调用，已就绪时立即返回。
    func prepare() async throws

    /// 针对一段转写文本给出替换清单。可能为空（没发现错误）。
    func edits(for text: String) async throws -> [CorrectionEdit]
}
