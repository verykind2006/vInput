import AVFoundation
import CoreML
import Foundation
import WhisperKit

/// 实现 WhisperKit 的 `AudioProcessing`，但音频由外部推入而非自行采集。
///
/// 存在的理由：`AudioStreamTranscriber` 通过该协议取音频，默认实现
/// (`AudioProcessor`) 会自己打开麦克风。我们需要它消费 `AudioSource`
/// 产出的帧——这样 M3 接入蓝牙遥控器时，流式预览无需任何改动即可工作。
///
/// 不能通过继承 `AudioProcessor` 实现：该类虽为 `open`，但除 `padOrTrim`
/// 外其方法均为 `public` 而非 `open`，跨模块无法重写。
///
/// 线程安全：`AudioSource` 在主线程推入，`AudioStreamTranscriber` 在其
/// 自身 actor 上读取，因此内部状态用锁保护。
final class SourceBackedAudioProcessor: AudioProcessing, @unchecked Sendable {
    private let lock = NSLock()
    private var samples = ContiguousArray<Float>()
    private var energies: [Float] = []

    var relativeEnergyWindow: Int = 20

    var audioSamples: ContiguousArray<Float> {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    var relativeEnergy: [Float] {
        lock.lock(); defer { lock.unlock() }
        return energies
    }

    // MARK: - 外部投喂

    /// 每个能量值必须恰好对应 100ms 音频。
    ///
    /// 这不是我们的选择，是 WhisperKit 的硬性契约——`isVoiceDetected`
    /// 里写着「Each energy value corresponds to 1 buffer length (100ms of
    /// audio), hence we divide by 0.1」，并据此把时长换算成要检查的能量
    /// 个数。按来帧长度（约 85ms）记录会让它的静音判断窗口算错。
    static let energyBlockSamples = Int(AudioFormat.sampleRate * 0.1)

    /// 尚未凑满一个 100ms 块的残余样本。
    private var pendingForEnergy: [Float] = []

    /// 由 `AudioSource` 的回调推入一批样本。
    ///
    /// 来帧长度由音频源决定（`SystemMicSource` 约 85ms），与能量分块
    /// 无关——样本原样累积，能量按固定 100ms 结算。
    func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }

        lock.lock()
        samples.append(contentsOf: chunk)

        pendingForEnergy.append(contentsOf: chunk)
        while pendingForEnergy.count >= Self.energyBlockSamples {
            let block = Array(pendingForEnergy.prefix(Self.energyBlockSamples))
            pendingForEnergy.removeFirst(Self.energyBlockSamples)
            // 复用 WhisperKit 的能量算法：AudioStreamTranscriber 用
            // relativeEnergy 配合 silenceThreshold 做静音判断，
            // 自己另写一套归一化会让它的判断失准。
            energies.append(AudioProcessor.calculateRelativeEnergy(of: block, relativeTo: nil))
        }
        lock.unlock()
    }

    /// 本次会话的能量统计，用于诊断真实麦克风的音量水平。
    ///
    /// 存在的理由：静音阈值默认 0.3，而 TTS 合成音与真人对着麦克风说话
    /// 的响度差很多。没有这组数据就只能猜为什么预览迟迟不出字。
    func energySummary() -> (count: Int, median: Float, max: Float, aboveThreshold: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !energies.isEmpty else { return (0, 0, 0, 0) }
        let sorted = energies.sorted()
        return (
            count: energies.count,
            median: sorted[sorted.count / 2],
            max: sorted[sorted.count - 1],
            aboveThreshold: energies.filter { $0 > 0.3 }.count
        )
    }

    /// 会话结束时清空，为下一次录音做准备。
    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        energies.removeAll(keepingCapacity: true)
        pendingForEnergy.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    // MARK: - AudioProcessing 必需成员

    func purgeAudioSamples(keepingLast keep: Int) {
        lock.lock(); defer { lock.unlock() }
        guard samples.count > keep else { return }
        samples.removeFirst(samples.count - keep)
    }

    // 以下生命周期方法在本实现里是空操作：音频由 AudioSource 驱动，
    // 不由本对象采集。保留空实现以满足协议。
    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {}
    func pauseRecording() {}
    func stopRecording() {}
    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {}

    func startStreamingRecordingLive(
        inputDeviceID: DeviceID?
    ) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        // 不支持该模式——AudioStreamTranscriber 走的是 startRecordingLive 路径。
        var continuation: AsyncThrowingStream<[Float], Error>.Continuation!
        let stream = AsyncThrowingStream<[Float], Error> { continuation = $0 }
        continuation.finish()
        return (stream, continuation)
    }

    func padOrTrim(
        fromArray audioArray: [Float],
        startAt startIndex: Int,
        toLength frameLength: Int
    ) -> (any AudioProcessorOutputType)? {
        AudioProcessor.padOrTrimAudio(
            fromArray: audioArray,
            startAt: startIndex,
            toLength: frameLength,
            saveSegment: false
        )
    }

    // MARK: - 静态成员，全部转发给 WhisperKit 的现成实现

    static func loadAudio(
        fromPath audioFilePath: String,
        channelMode: ChannelMode,
        startTime: Double?,
        endTime: Double?,
        maxReadFrameSize: AVAudioFrameCount?
    ) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(
            fromPath: audioFilePath,
            channelMode: channelMode,
            startTime: startTime,
            endTime: endTime,
            maxReadFrameSize: maxReadFrameSize
        )
    }

    static func loadAudio(
        at audioPaths: [String],
        channelMode: ChannelMode
    ) async -> [Result<[Float], Swift.Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    static func padOrTrimAudio(
        fromArray audioArray: [Float],
        startAt startIndex: Int,
        toLength frameLength: Int,
        saveSegment: Bool
    ) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(
            fromArray: audioArray,
            startAt: startIndex,
            toLength: frameLength,
            saveSegment: saveSegment
        )
    }
}
