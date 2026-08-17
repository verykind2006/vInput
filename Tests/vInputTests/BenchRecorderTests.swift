import AVFoundation
import Foundation
import Testing

@testable import vInput

@Suite("基准集录音写出")
struct BenchRecorderTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
    }

    /// 写出的必须是 Whisper 能直接吃的格式：16 kHz 单声道。
    /// 格式不对的话，基准集测出来的是格式转换的差异，不是模型的差异。
    @Test("写出 16 kHz 单声道 WAV")
    func writesExpectedFormat() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = [Float](repeating: 0.1, count: 16_000)
        try BenchRecorder.writeWAV(samples: samples, to: url)

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == AudioFormat.sampleRate)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == 16_000)
    }

    /// 读回来的样本要和写进去的一致，否则基准集本身就失真了。
    @Test("样本往返一致")
    func samplesRoundTrip() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let samples: [Float] = (0..<1000).map { Float(sin(Double($0) * 0.1)) * 0.5 }
        try BenchRecorder.writeWAV(samples: samples, to: url)

        let readBack = try BenchRecorder.readWAV(from: url)
        #expect(readBack.count == samples.count)
        // Int16 量化后有精度损失，比对到千分之一即可
        for (index, expected) in samples.enumerated() {
            #expect(abs(readBack[index] - expected) < 0.001, "第 \(index) 个样本偏差过大")
        }
    }

    @Test("空样本不写出文件")
    func emptySamplesThrow() {
        let url = temporaryURL()
        #expect(throws: BenchRecorderError.self) {
            try BenchRecorder.writeWAV(samples: [], to: url)
        }
    }
}
