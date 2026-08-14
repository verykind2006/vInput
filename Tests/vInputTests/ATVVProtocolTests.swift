import Foundation
import Testing
@testable import vInput

@Suite("ATVV 协议")
struct ATVVProtocolTests {

    // MARK: - 能力协商

    @Test("只接受 16 kHz")
    func acceptsOnly16k() {
        #expect(ATVVProtocol.supportsAudio(sampleRate: 16_000))
        #expect(!ATVVProtocol.supportsAudio(sampleRate: 8_000))
        #expect(!ATVVProtocol.supportsAudio(sampleRate: 48_000))
    }

    @Test("v1.0 及以上的开麦命令不带 codec 字节")
    func microphoneOpenForV1() {
        #expect(ATVVProtocol.microphoneOpen(version: 0x0100, codec: 0x02) == Data([0x0C, 0x00]))
    }

    @Test("v1.0 以下的开麦命令带 codec 字节")
    func microphoneOpenForLegacy() {
        #expect(ATVVProtocol.microphoneOpen(version: 0x0001, codec: 0x02) == Data([0x0C, 0x00, 0x02]))
    }

    @Test("MIC_EXTEND 仅在 v1.0 及以上可用")
    func extendOnlyForV1() {
        #expect(ATVVProtocol.microphoneExtend(version: 0x0100, sessionID: 7) == Data([0x0E, 7]))
        #expect(ATVVProtocol.microphoneExtend(version: 0x0001, sessionID: 7) == nil)
    }

    // MARK: - 能力解析

    @Test("解析 v1.0 能力报文，codec 0x02 对应 16 kHz")
    func parsesV1Capabilities() throws {
        // 0x0B 头 + 版本 0x0100 + codecs 0x02 + interaction 0x03 + frameSize 0x0078(120)
        let data = Data([0x0B, 0x01, 0x00, 0x02, 0x03, 0x00, 0x78])
        let caps = try #require(ATVVCapabilities.parse(data))

        #expect(caps.version == 0x0100)
        #expect(caps.selectedCodec == 0x02)
        #expect(caps.sampleRate == 16_000)
        #expect(caps.frameSize == 120)
    }

    @Test("codec 仅支持 0x01 时降为 8 kHz")
    func fallsBackTo8k() throws {
        let data = Data([0x0B, 0x01, 0x00, 0x01, 0x03, 0x00, 0x78])
        let caps = try #require(ATVVCapabilities.parse(data))

        #expect(caps.selectedCodec == 0x01)
        #expect(caps.sampleRate == 8_000)
    }

    @Test("帧长为 0 时取默认值 120")
    func defaultsFrameSize() throws {
        let data = Data([0x0B, 0x01, 0x00, 0x02, 0x03, 0x00, 0x00])
        let caps = try #require(ATVVCapabilities.parse(data))
        #expect(caps.frameSize == 120)
    }

    @Test("非能力报文返回 nil")
    func rejectsWrongHeader() {
        #expect(ATVVCapabilities.parse(Data([0x0A, 0x01, 0x00, 0x02, 0x03, 0x00, 0x78])) == nil)
    }

    @Test("过短的报文返回 nil")
    func rejectsShortData() {
        #expect(ATVVCapabilities.parse(Data([0x0B, 0x01])) == nil)
    }

    // MARK: - IMA ADPCM 解码

    @Test("每个字节解出两个样本")
    func decodesTwoSamplesPerByte() {
        let decoder = IMAADPCMDecoder()
        let samples = decoder.decode(Data([0x00, 0x00, 0x00]))
        #expect(samples.count == 6)
    }

    @Test("全零输入产出静音")
    func zeroInputYieldsNearSilence() {
        let decoder = IMAADPCMDecoder()
        let samples = decoder.decode(Data(repeating: 0, count: 64))
        // nibble 0 的步进最小，预测器应停留在极小的幅度内
        #expect(samples.allSatisfy { abs(Int($0)) < 100 })
    }

    @Test("解码器有状态：同样的输入在不同状态下产出不同结果")
    func decoderIsStateful() {
        let decoder = IMAADPCMDecoder()
        let first = decoder.decode(Data([0x77, 0x77, 0x77, 0x77]))
        let second = decoder.decode(Data([0x77, 0x77, 0x77, 0x77]))
        // IMA ADPCM 是差分编码，预测器会持续累积
        #expect(first != second)
    }

    @Test("reset 后回到初始状态")
    func resetRestoresInitialState() {
        let decoder = IMAADPCMDecoder()
        let first = decoder.decode(Data([0x55, 0x55, 0x55, 0x55]))

        decoder.reset()
        let afterReset = decoder.decode(Data([0x55, 0x55, 0x55, 0x55]))

        #expect(first == afterReset)
    }

    @Test("输出不越界")
    func outputStaysInInt16Range() {
        let decoder = IMAADPCMDecoder()
        // 0x77 是步进最大的 nibble 组合，用它把预测器推到极限
        let samples = decoder.decode(Data(repeating: 0x77, count: 512))
        #expect(samples.allSatisfy { $0 >= -32_768 && $0 <= 32_767 })
    }

    // MARK: - 帧累积

    @Test("凑满帧长才产出")
    func accumulatesUntilFrameSize() {
        var accumulator = FrameAccumulator()

        #expect(accumulator.append(Data(repeating: 1, count: 50), frameSize: 120).isEmpty)

        let frames = accumulator.append(Data(repeating: 1, count: 70), frameSize: 120)
        #expect(frames.count == 1)
        #expect(frames[0].count == 120)
    }

    @Test("一次推入多帧全部产出，余数留待下次")
    func emitsMultipleFrames() {
        var accumulator = FrameAccumulator()
        let frames = accumulator.append(Data(repeating: 1, count: 250), frameSize: 120)

        #expect(frames.count == 2)
        #expect(accumulator.pending.count == 10)
    }

    @Test("reset 清空残余")
    func resetClearsPending() {
        var accumulator = FrameAccumulator()
        _ = accumulator.append(Data(repeating: 1, count: 50), frameSize: 120)
        accumulator.reset()
        #expect(accumulator.pending.isEmpty)
    }
}
