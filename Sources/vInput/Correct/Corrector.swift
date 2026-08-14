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
    /// 是否已经能立刻推理。
    ///
    /// **调用方据此决定「这次干脆不校正」，而不是等模型加载完。** 加载
    /// 一次本地模型要几十秒，谁都不该在注入路径上等它（规则二·永不丢字）。
    /// 读这个值本身也必须是立刻返回的，实现里不许顺手去加载。
    var isReady: Bool { get async }

    /// 确保模型已加载。可重复调用，已就绪时立即返回。
    ///
    /// 会一直等到加载完成，**只应在后台预热时调用**，不要放在注入路径上。
    func prepare() async throws

    /// 针对一段转写文本给出替换清单。可能为空（没发现错误）。
    ///
    /// 未就绪时应立即抛 `.modelNotReady`，而不是就地加载模型——
    /// 同上，注入路径不等加载。
    func edits(for text: String) async throws -> [CorrectionEdit]
}

extension Corrector {
    /// 默认视为就绪：不需要加载模型的实现（云端校正、测试替身）天然就绪，
    /// 只有本地模型这类有加载成本的实现才必须覆盖。
    var isReady: Bool { get async { true } }
}
