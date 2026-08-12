import Foundation

/// 音频源产出的样本格式：16 kHz 单声道 Float32，取值 -1…1。
///
/// 该格式同时是 WhisperKit 的输入格式，也是 ATV Voice 协议
/// 解码后的原生格式（M3 引入蓝牙时无需重采样）。
enum AudioFormat {
    static let sampleRate: Double = 16_000
}

enum AudioSourceError: Error, Equatable {
    /// 输入设备的格式无法转换到目标格式。
    case unsupportedInputFormat(sampleRate: Double)
    /// 用户拒绝了麦克风权限。
    case microphonePermissionDenied
    /// 底层音频引擎启动失败。
    case engineFailedToStart(String)
}

/// 音频采集源。实现者负责把任意来源的音频统一成 16 kHz 单声道 Float32。
///
/// 所有回调都在主线程触发，调用方无需自行调度。
@MainActor
protocol AudioSource: AnyObject {
    /// 每收到一批样本触发一次。
    var onFrame: (([Float]) -> Void)? { get set }
    /// 采集结束时触发。`error` 为 nil 表示正常结束。
    var onStop: ((Error?) -> Void)? { get set }

    func start() throws
    func stop()
}
