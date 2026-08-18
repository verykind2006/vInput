import Foundation

/// 把蓝牙遥控器的音频包装成 `AudioSource`。
///
/// 它不直接持有蓝牙桥——桥的生命周期（连接、重连）比一次听写会话长得多，
/// 由 `RemoteCoordinator` 统一管理。本类型只负责在会话期间接收样本、
/// 归一化、转发。
///
/// ATVV 协商到 codec 0x02 时输出 16 kHz 单声道 Int16 PCM，与
/// `AudioFormat.sampleRate` 一致，**无需重采样**。
@MainActor
final class BluetoothRemoteSource: AudioSource {
    var onFrame: (([Float]) -> Void)?
    var onStop: ((Error?) -> Void)?

    private var isRunning = false

    func start() throws {
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        onStop?(nil)
    }

    // MARK: - 由 RemoteCoordinator 驱动

    /// 蓝牙桥解码出一批样本时调用。
    ///
    /// 未启动时丢弃：桥的音频可能在会话开始前就到达（例如上一轮的尾包），
    /// 混进新会话的缓冲区会让开头多出一段无关音频。
    func deliver(_ samples: [Int16]) {
        guard isRunning else { return }
        onFrame?(AudioFormat.normalize(samples))
    }

    /// 录音期间遥控器断连。
    ///
    /// 以错误结束会话。`DictationSession` 只在 `.listening` 期间响应该错误；
    /// 若已进入转写阶段，音频已完整拿到手，中止反而是在丢字。
    func reportDisconnected() {
        guard isRunning else { return }
        isRunning = false
        onStop?(AudioSourceError.engineFailedToStart("遥控器已断开连接"))
    }
}
