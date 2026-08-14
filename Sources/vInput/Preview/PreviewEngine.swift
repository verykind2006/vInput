import Foundation

/// 推送给 HUD 的一次预览快照。
struct PreviewText: Equatable, Sendable {
    /// 已确认的文本，不会再被改写。
    let confirmed: String
    /// 未确认的文本，后续可能被修正。
    let unconfirmed: String
    /// 归一化到 0…1 的最近能量值，供音量波形使用。
    let energy: [Float]

    static let empty = PreviewText(confirmed: "", unconfirmed: "", energy: [])
}

enum PreviewEngineError: Error, Equatable {
    /// 底层模型尚未就绪。
    case notReady
    /// 流式引擎内部错误。
    case streamFailed(String)
}

/// 边录边转写，产出供 HUD 显示的预览文本。
///
/// 预览是锦上添花：本协议的任何失败都不得影响主转写路径。
/// `DictationSession` 会捕获全部错误、关闭预览、让录音继续。
protocol PreviewEngine: AnyObject, Sendable {
    /// 每产出一次新预览触发。回调在任意线程，调用方需自行调度到主线程。
    var onUpdate: (@Sendable (PreviewText) -> Void)? { get set }

    /// 开始流式转写。
    func start() async throws

    /// 停止流式转写。
    ///
    /// **必须等到底层推理循环真正退出才返回**——调用方会紧接着发起全量
    /// 转写，而两者共享同一套解码器实例，重叠会产生数据竞争。
    func stop() async
}
