import AVFoundation
import Foundation

/// 从系统默认输入设备采集音频，并统一转换为 16 kHz 单声道 Float32。
@MainActor
final class SystemMicSource: AudioSource {
    var onFrame: (([Float]) -> Void)?
    var onStop: ((Error?) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isRunning = false

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioFormat.sampleRate,
        channels: 1,
        interleaved: false
    )!

    func start() throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            // 无可用输入设备时 AVAudioEngine 会返回采样率 0 的格式。
            throw AudioSourceError.unsupportedInputFormat(sampleRate: inputFormat.sampleRate)
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioSourceError.unsupportedInputFormat(sampleRate: inputFormat.sampleRate)
        }
        self.converter = converter

        // tap 回调运行在音频线程，不能从那里访问本类型的 @MainActor
        // 属性。因此把目标格式先取到局部常量再捕获。
        let format = targetFormat
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            guard let converted = SystemMicSource.resample(
                buffer, using: converter, to: format
            ) else { return }
            Task { @MainActor [weak self] in
                self?.onFrame?(converted)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioSourceError.engineFailedToStart(error.localizedDescription)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
        onStop?(nil)
    }

    // MARK: - 重采样

    /// 把任意格式的 buffer 转换成目标格式，返回浮点样本数组。
    ///
    /// 抽成静态方法是为了能用合成 buffer 单元测试，无需真实麦克风。
    nonisolated static func resample(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> [Float]? {
        guard buffer.frameLength > 0 else { return [] }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        // 输入块只能被消费一次，第二次调用要报 noDataNow 让转换器收尾。
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil else { return nil }
        guard let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
