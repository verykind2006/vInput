import Foundation

/// 音频源产出的样本格式：16 kHz 单声道 Float32，取值 -1…1。
///
/// 该格式同时是 WhisperKit 的输入格式，也是 ATV Voice 协议
/// 解码后的原生格式（M3 引入蓝牙时无需重采样）。
enum AudioFormat {
    static let sampleRate: Double = 16_000

    /// Int16 PCM → Float，取值范围 -1…1。
    ///
    /// 除以 32768 而非 32767：Int16 的负半轴比正半轴多一个值，
    /// 用 32768 才能保证 -32768 恰好映射到 -1 且不溢出。
    ///
    /// **放在这里而不是某个源里**：M7 接入蓝牙鼠标时出现了第二个 Int16
    /// 来源（SBC 解码器的输出），两处各写一份归一化早晚会漂移，而漂移的
    /// 表现是「某个源的音量莫名不同」——最难被察觉的那一档。这条 -1…1 的
    /// 约定本来就是 `AudioFormat` 定义的，实现跟着约定走。
    nonisolated static func normalize(_ samples: [Int16]) -> [Float] {
        samples.map { Float($0) / 32_768 }
    }
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
