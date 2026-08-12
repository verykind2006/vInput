import AVFoundation
import Testing
@testable import vInput

@Suite("SystemMicSource 重采样")
struct SystemMicSourceTests {
    /// 生成一个指定采样率的正弦波 buffer，模拟麦克风输入。
    private func makeBuffer(sampleRate: Double, seconds: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            channel[index] = Float(sin(2 * .pi * 440 * Double(index) / sampleRate))
        }
        return buffer
    }

    private func targetFormat() throws -> AVAudioFormat {
        try #require(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioFormat.sampleRate,
                channels: 1,
                interleaved: false
            )
        )
    }

    @Test("48 kHz 输入重采样到 16 kHz 后样本数约为三分之一")
    func downsamplesFrom48k() throws {
        let input = makeBuffer(sampleRate: 48_000, seconds: 1)
        let target = try targetFormat()
        let converter = try #require(AVAudioConverter(from: input.format, to: target))

        let output = try #require(
            SystemMicSource.resample(input, using: converter, to: target)
        )

        // 转换器有内部延迟，允许 5% 偏差。
        #expect(abs(output.count - 16_000) < 800)
    }

    @Test("44.1 kHz 输入同样能转换")
    func downsamplesFrom44k() throws {
        let input = makeBuffer(sampleRate: 44_100, seconds: 1)
        let target = try targetFormat()
        let converter = try #require(AVAudioConverter(from: input.format, to: target))

        let output = try #require(
            SystemMicSource.resample(input, using: converter, to: target)
        )

        #expect(abs(output.count - 16_000) < 800)
    }

    @Test("输出样本落在合法取值范围内")
    func outputStaysInRange() throws {
        let input = makeBuffer(sampleRate: 48_000, seconds: 0.5)
        let target = try targetFormat()
        let converter = try #require(AVAudioConverter(from: input.format, to: target))

        let output = try #require(
            SystemMicSource.resample(input, using: converter, to: target)
        )

        #expect(output.allSatisfy { $0 >= -1.01 && $0 <= 1.01 })
    }

    @Test("空 buffer 返回空数组而非 nil")
    func emptyBufferYieldsEmptyArray() throws {
        let target = try targetFormat()
        let input = makeBuffer(sampleRate: 48_000, seconds: 1)
        input.frameLength = 0
        let converter = try #require(AVAudioConverter(from: input.format, to: target))

        let output = try #require(
            SystemMicSource.resample(input, using: converter, to: target)
        )

        #expect(output.isEmpty)
    }
}
