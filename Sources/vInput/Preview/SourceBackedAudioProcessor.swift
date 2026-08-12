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

    /// 由 `AudioSource` 的回调推入一批样本。
    func append(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }

        // 复用 WhisperKit 的能量算法。AudioStreamTranscriber 用
        // relativeEnergy 配合 silenceThreshold(0.3) 做静音判断，
        // 自己另写一套归一化会让它的判断失准。
        let relative = AudioProcessor.calculateRelativeEnergy(of: chunk, relativeTo: nil)

        lock.lock()
        samples.append(contentsOf: chunk)
        energies.append(relative)
        lock.unlock()
    }

    /// 会话结束时清空，为下一次录音做准备。
    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        energies.removeAll(keepingCapacity: true)
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
