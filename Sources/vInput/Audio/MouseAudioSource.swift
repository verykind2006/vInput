import Foundation

/// 把蓝牙鼠标的音频包装成 `AudioSource`。
///
/// 照 `BluetoothRemoteSource` 的样子写：它不持有蓝牙桥——桥的生命周期
/// （连接、重连）比一次听写会话长得多，由 `MouseBluetoothBridge` 与
/// `MouseCoordinator` 管。本类型只负责在会话期间收包、解码、归一化、转发。
///
/// **与遥控器那条路唯一的差别是多一步解码。** 鼠标送的是 SBC 码流
/// （16 kHz / 单声道 / bitpool 12，每包 128 字节 = 4 个 32 字节帧），
/// 解出来就是 16 kHz 单声道 Int16 PCM，与 `AudioFormat.sampleRate` 一致，
/// **无需重采样**。解码器是 `SBCDecoder`（移植自 FFmpeg n8.1，
/// 298496 样本与 ffmpeg 零容差逐样本吻合）。
@MainActor
final class MouseAudioSource: AudioSource {
    var onFrame: (([Float]) -> Void)?
    var onStop: ((Error?) -> Void)?

    /// 本次会话解出的样本总数。真机验收要靠它对时长——
    /// 16000 样本 = 1 秒，日志里有这个数就能判断「录到的是不是那句话」。
    private(set) var decodedSampleCount = 0
    /// 本次会话解码失败的包数。
    private(set) var decodeFailureCount = 0

    private var isRunning = false
    private let decoder = SBCDecoder()

    /// 解码失败最多记多少行日志。
    ///
    /// 一秒 31 个包，码流一旦错位就是每包一行——不限流会把用户日常那条
    /// 日志冲掉，而用户正是要把它发回来看的。头几行足以看清是什么错。
    private static let failureLogLimit = 5

    func start() throws {
        guard !isRunning else { return }
        // 每次会话重置解码器：上一轮结尾可能留着半帧（丢包或会话被截断），
        // 带进新会话会让开头那几帧错位解成噪音。
        decoder.reset()
        decodedSampleCount = 0
        decodeFailureCount = 0
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        onStop?(nil)
    }

    // MARK: - 由 MouseCoordinator 驱动

    /// 蓝牙桥收到一个音频包时调用，载荷是裸 SBC 字节。
    ///
    /// 未启动时丢弃：桥的音频可能在会话开始前或结束后到达（会话被时长上限
    /// 截断、或结束控制帧丢包），混进新会话的缓冲区会让开头多出一段无关
    /// 音频。**这一层的丢弃是第二道**——第一道在
    /// `MouseVoiceSession.acceptsAudio`，只有听写会话才会走到这里。
    func deliver(_ packet: Data) {
        guard isRunning else { return }
        do {
            let samples = try decoder.decode(packet)
            guard !samples.isEmpty else { return }
            decodedSampleCount += samples.count
            onFrame?(AudioFormat.normalize(samples))
        } catch {
            // **坏帧之后不猜着重新同步。** 往前找下一个 0x9C 看着更健壮，
            // 实际是猜——0x9C 也可能只是音频数据里的一个字节，跟着它走会
            // 解出一段能播放的噪音，而噪音会被转写成一句像样的中文。
            // 直接丢掉解码器里攒的半帧，从下一个包重新对齐：BLE 每包正好
            // 4 个整帧，丢一包只丢 32 ms，对齐关系不受影响。
            decoder.reset()
            decodeFailureCount += 1
            if decodeFailureCount <= Self.failureLogLimit {
                AppLogger.shared.log("鼠标音频解码失败（第 \(decodeFailureCount) 次）：\(error)")
            }
        }
    }

    /// 录音期间鼠标断连。
    ///
    /// 以错误结束会话。判据与 `BluetoothRemoteSource.reportDisconnected`
    /// 相同：`DictationSession` 只在 `.listening` 期间响应该错误，
    /// 已进入转写阶段时音频已完整拿到手，中止反而是在丢字。
    func reportDisconnected() {
        guard isRunning else { return }
        isRunning = false
        onStop?(AudioSourceError.engineFailedToStart("蓝牙鼠标已断开连接"))
    }
}
