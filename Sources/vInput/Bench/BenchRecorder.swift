import AVFoundation
import Foundation
import Observation
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

/// 录制会话的进度状态。
///
/// 抽成独立类型而非塞进 `AppModel`：录制是开发期功能，不该让产品代码
/// 的状态机变复杂；而且这样才能不碰麦克风就把导航逻辑测掉。
@MainActor
@Observable
final class BenchRecordingSession {
    private let manifest: BenchManifest
    private(set) var index = 0

    init(manifest: BenchManifest) {
        self.manifest = manifest
    }

    var current: BenchEntry? {
        manifest.entries.indices.contains(index) ? manifest.entries[index] : nil
    }

    var progressText: String { "\(index + 1) / \(manifest.entries.count)" }

    /// 该条是否已经录过。录制界面据此提示用户哪些还没录。
    ///
    /// 读的是文件系统而非存储属性，@Observable 跟踪不到它——它自己变化时
    /// 不会触发重画。这里可以接受：录制窗口的视图同时读了
    /// `AppModel.benchIsRecording`，录完那一刻状态翻转会重画整个 body，
    /// 这个计算属性随之重新求值。
    var currentIsRecorded: Bool {
        guard let current else { return false }
        return FileManager.default.fileExists(
            atPath: BenchManifest.audioURL(for: current).path
        )
    }

    func advance() {
        index = min(index + 1, manifest.entries.count - 1)
    }

    /// 回到上一条。**必须有**：一次性录完二十几段不允许出错是不现实的。
    func retreat() {
        index = max(index - 1, 0)
    }

    func jump(toID id: String) {
        guard let target = manifest.entries.firstIndex(where: { $0.id == id }) else { return }
        index = target
    }
}
