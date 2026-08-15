import AVFoundation
import Foundation
import WhisperKit

enum BenchRecorderError: Error, Equatable {
    /// 没有样本可写。录了个寂寞，不该产出一个空文件让人以为录好了。
    case noSamples
    /// 音频格式构造失败。
    case formatUnavailable
}

/// 基准集录音的写出与读回。
///
/// **这是开发期工具，不随应用分发。** 原始设计的隐私一节写明「音频不落盘」，
/// 基准集是那条原则的一个明确例外，范围严格限定：只有录制入口会调到这里，
/// 听写主路径一行代码不改。
enum BenchRecorder {
    /// 写成 16 kHz 单声道 Int16 WAV。
    ///
    /// 格式与 `AudioFormat.sampleRate` 一致，也正是 Whisper 的原生输入格式
    /// ——基准集测的应当是模型的差异，不该混进格式转换的差异。
    static func writeWAV(samples: [Float], to url: URL) throws {
        guard !samples.isEmpty else { throw BenchRecorderError.noSamples }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let file = try AVAudioFile(forWriting: url, settings: settings)

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: AudioFormat.sampleRate, channels: 1
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw BenchRecorderError.formatUnavailable
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    /// 读回样本。用 WhisperKit 的读取器，与生产转写走的是同一条路径。
    static func readWAV(from url: URL) throws -> [Float] {
        try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
    }
}
