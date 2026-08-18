import Foundation
import Testing

@testable import vInput

/// SBC 解码器的逐样本验收。
///
/// **判据是「与 ffmpeg 的输出逐样本完全相同」，不是「听起来对」。**
/// M7 第一步曾把这条流猜成 IMA ADPCM，解出来的东西按「样本数 ÷ 时长」这类
/// 指标看还挺像回事，实际是噪音。这一步最怕的失败也是静默的：synthesis
/// filterbank 的 proto filter 系数抄错一个，音频不会崩、不会报错，只会发闷。
/// 所以这里不设容差——`SBCDecoder` 是 ffmpeg 定点实现的直译，同样的整数运算
/// 必须得出同样的整数结果。**只要有一个样本不同，就是抄错了。**
///
/// 夹具由 `./scripts/sbc-fixtures.sh` 生成（`<名字>.sbc` + ffmpeg 解出的
/// `<名字>.pcm`）。**跑这些测试不需要 ffmpeg、不需要任何模型**——参考答案
/// 已经在版本库里。真实录音的比对走门控的 `MouseDecodeTests`，那三段是
/// 用户的说话声，不能进版本库。
@Suite("SBC 解码")
struct SBCDecoderTests {
    /// 夹具名 → 期望的帧配置，用来同时验证帧头解析。
    static let fixtures: [(name: String, sampleRate: Int, blocks: Int, subbands: Int,
                           allocation: SBCAllocationMethod, bitpool: UInt8)] = [
        ("dev-16k-16blk-8sb-loudness-bp12", 16_000, 16, 8, .loudness, 12),
        // Loudness 的 offset 表按「采样率 × 子带」索引，四行都要走到。
        // 少一行就等于那一行改错了也不会被发现（本轮变异测试实测过）。
        ("synth-16k-4blk-8sb-loudness-bp20", 16_000, 4, 8, .loudness, 20),
        ("synth-32k-16blk-8sb-loudness-bp24", 32_000, 16, 8, .loudness, 24),
        ("synth-44k-8blk-8sb-loudness-bp26", 44_100, 8, 8, .loudness, 26),
        ("synth-48k-16blk-8sb-loudness-bp28", 48_000, 16, 8, .loudness, 28),
        ("synth-16k-16blk-4sb-loudness-bp12", 16_000, 16, 4, .loudness, 12),
        ("synth-32k-12blk-4sb-loudness-bp10", 32_000, 12, 4, .loudness, 10),
        ("synth-44k-16blk-4sb-loudness-bp14", 44_100, 16, 4, .loudness, 14),
        ("synth-48k-16blk-4sb-loudness-bp16", 48_000, 16, 4, .loudness, 16),
        // SNR 不查 offset 表，4/8 子带各留一条。
        ("synth-16k-8blk-8sb-snr-bp16", 16_000, 8, 8, .snr, 16),
        ("synth-44k-16blk-8sb-snr-bp32", 44_100, 16, 8, .snr, 32),
        ("synth-48k-4blk-4sb-snr-bp24", 48_000, 4, 4, .snr, 24),
        // scale factor 拉满，输出撞 16 位饱和——把 av_clip_int16 那一步测掉。
        ("synth-16k-16blk-8sb-loudness-bp12-clip", 16_000, 16, 8, .loudness, 12),
    ]

    @Test("逐样本吻合 ffmpeg", arguments: fixtures)
    func matchesFFmpeg(
        fixture: (name: String, sampleRate: Int, blocks: Int, subbands: Int,
                  allocation: SBCAllocationMethod, bitpool: UInt8)
    ) throws {
        let stream = try SBCFixtures.stream(fixture.name)
        let reference = try SBCFixtures.referencePCM(fixture.name)

        let decoder = SBCDecoder()
        let decoded = try decoder.decode(stream)

        #expect(decoded.count == reference.count, "\(fixture.name) 样本数不一致")

        // 逐样本比对。不用 #expect(decoded == reference)：那样失败信息是两个
        // 几千元素的数组，看不出错在哪、错多少。
        var mismatches = 0
        var maxError = 0
        var firstMismatch = -1
        for index in 0..<min(decoded.count, reference.count) where decoded[index] != reference[index] {
            mismatches += 1
            maxError = max(maxError, abs(Int(decoded[index]) - Int(reference[index])))
            if firstMismatch < 0 { firstMismatch = index }
        }
        #expect(
            mismatches == 0,
            """
            \(fixture.name)：\(mismatches)/\(reference.count) 个样本与 ffmpeg 不同，\
            最大绝对误差 \(maxError)，首个不同在第 \(firstMismatch) 个样本
            """
        )

        // 帧头必须被读出来而不是假设——固件升级换了配置时要能立刻看出来。
        let info = try #require(decoder.lastFrameInfo)
        #expect(info.sampleRate == fixture.sampleRate)
        #expect(info.blocks == fixture.blocks)
        #expect(info.subbands == fixture.subbands)
        #expect(info.allocation == fixture.allocation)
        #expect(info.bitpool == fixture.bitpool)
        #expect(info.channelMode == .mono)

        // 「每帧多少样本」这件事必须精确，不能靠总数凑。M7 第一步就是在
        // 帧结构上错了一次。
        let frames = stream.count / info.frameLength
        #expect(stream.count % info.frameLength == 0, "\(fixture.name) 码流不是整数帧")
        #expect(decoded.count == frames * fixture.blocks * fixture.subbands)
    }

    @Test("设备帧头 9C 31 0C：16 kHz / 16 blocks / MONO / Loudness / 8 子带 / bitpool 12")
    func parsesDeviceHeader() throws {
        let stream = try SBCFixtures.stream("dev-16k-16blk-8sb-loudness-bp12")
        let info = try SBCDecoder.frameInfo(of: stream)
        #expect(Array(stream.prefix(3)) == [0x9C, 0x31, 0x0C])
        #expect(info.sampleRate == 16_000)
        #expect(info.blocks == 16)
        #expect(info.channelMode == .mono)
        #expect(info.allocation == .loudness)
        #expect(info.subbands == 8)
        #expect(info.bitpool == 12)
        // 4 + 4×8×1/8 + ceil(16×1×12/8) = 32
        #expect(info.frameLength == 32)
        #expect(info.samplesPerFrame == 128)
    }

    /// BLE 每包 128 字节正好 4 帧，但没有任何规范保证它永远整除。
    /// 一次喂一个字节仍要解出完全相同的结果，否则接 `AudioSource` 时
    /// 一旦包边界与帧边界错开就会静默丢音频。
    @Test("按任意字节切分喂入，结果不变")
    func decodesAcrossArbitrarySplits() throws {
        let stream = try SBCFixtures.stream("dev-16k-16blk-8sb-loudness-bp12")
        let oneShot = try SBCDecoder().decode(stream)

        let dripped = SBCDecoder()
        var pieces: [Int16] = []
        for byte in stream {
            pieces += try dripped.decode(Data([byte]))
        }
        #expect(pieces == oneShot)

        // 合成滤波器带状态：同一个解码器连解两遍，第二遍不等于第一遍
        // （尾部记忆不同），reset() 之后才该相等。
        let reused = SBCDecoder()
        let first = try reused.decode(stream)
        let second = try reused.decode(stream)
        #expect(first != second)
        reused.reset()
        #expect(try reused.decode(stream) == first)
    }

    @Test("码流末尾不足一帧时留在缓冲里，不报错也不丢")
    func keepsPartialTail() throws {
        let stream = try SBCFixtures.stream("dev-16k-16blk-8sb-loudness-bp12")
        let decoder = SBCDecoder()
        let head = try decoder.decode(stream.prefix(32 + 7))
        #expect(head.count == 128)
        let rest = try decoder.decode(stream.dropFirst(32 + 7))
        #expect(head + rest == (try SBCDecoder().decode(stream)))
    }

    // MARK: - 拒绝而不是解出噪音
    //
    // 固件升级后配置可能变。**这时正确的行为是报错**：一个只支持 MONO 的
    // 解码器碰上立体声流，照 MONO 解出来的是能播放的噪音——正是本项目
    // 最怕的静默失败。

    @Test("syncword 不对直接拒绝")
    func rejectsBadSyncword() throws {
        var stream = Array(try SBCFixtures.stream("dev-16k-16blk-8sb-loudness-bp12").prefix(32))
        stream[0] = 0x9D
        #expect(throws: SBCDecodeError.badSyncword(0x9D)) {
            _ = try SBCDecoder().decode(Data(stream))
        }
    }

    /// mSBC（0xAD）帧结构与 SBC 不同（隐含头 + 每帧 15 blocks）。
    /// 按 SBC 解会解出噪音，所以单独认出来并报错。
    @Test("mSBC 流报专门的错，而不是当成坏 syncword")
    func rejectsMSBC() throws {
        var stream = Array(try SBCFixtures.stream("dev-16k-16blk-8sb-loudness-bp12").prefix(32))
        stream[0] = 0xAD
        #expect(throws: SBCDecodeError.unsupportedMSBC) {
            _ = try SBCDecoder().decode(Data(stream))
        }
    }

    @Test("CRC 对不上直接拒绝", arguments: [3, 4, 5])
    func rejectsCRCMismatch(corruptedByte: Int) throws {
        var stream = Array(try SBCFixtures.stream("dev-16k-16blk-8sb-loudness-bp12").prefix(32))
        stream[corruptedByte] ^= 0x01
        #expect(throws: (any Error).self) {
            _ = try SBCDecoder().decode(Data(stream))
        }
    }

    @Test("非单声道直接拒绝", arguments: [SBCChannelMode.dualChannel, .stereo, .jointStereo])
    func rejectsNonMono(mode: SBCChannelMode) throws {
        var stream = Array(try SBCFixtures.stream("dev-16k-16blk-8sb-loudness-bp12").prefix(32))
        stream[1] = (stream[1] & ~0x0C) | (mode.rawValue << 2)
        // CRC 覆盖 header[1]，改了配置位 CRC 必然对不上——这里要的是
        // 「先认出配置不支持」，所以错误必须是 unsupportedChannelMode 而不是 CRC。
        #expect(throws: SBCDecodeError.unsupportedChannelMode(mode)) {
            _ = try SBCDecoder().decode(Data(stream))
        }
    }

    @Test("不足 4 字节读不出帧头")
    func rejectsTruncatedHeader() {
        #expect(throws: SBCDecodeError.truncatedHeader(byteCount: 2)) {
            _ = try SBCDecoder.frameInfo(of: Data([0x9C, 0x31]))
        }
    }

    /// 坏帧之后**不自动重新同步**。往前找下一个 `0x9C` 看着更健壮，实际是猜：
    /// `0x9C` 也可能只是音频数据里的一个字节，对上了就解出一整段噪音。
    @Test("解码出错后错误是粘的，reset() 之后才能继续")
    func errorIsStickyUntilReset() throws {
        var bad = Array(try SBCFixtures.stream("dev-16k-16blk-8sb-loudness-bp12").prefix(64))
        bad[0] = 0x9D
        let decoder = SBCDecoder()
        #expect(throws: SBCDecodeError.badSyncword(0x9D)) { _ = try decoder.decode(Data(bad)) }
        // 再喂一次好数据也没用——坏字节还在缓冲区最前面。
        #expect(throws: SBCDecodeError.badSyncword(0x9D)) {
            _ = try decoder.decode(try SBCFixtures.stream("dev-16k-16blk-8sb-loudness-bp12"))
        }
        decoder.reset()
        #expect(try decoder.decode(try SBCFixtures.stream("dev-16k-16blk-8sb-loudness-bp12")).count == 5504)
    }

    @Test("bitpool 超出规范上限直接拒绝")
    func rejectsBitpoolOutOfRange() throws {
        var stream = Array(try SBCFixtures.stream("dev-16k-16blk-8sb-loudness-bp12").prefix(32))
        // MONO / 8 子带的上限是 16 × 8 = 128。
        stream[2] = 129
        #expect(throws: SBCDecodeError.bitpoolOutOfRange(129)) {
            _ = try SBCDecoder().decode(Data(stream))
        }
    }
}

/// 夹具读取。用 `#filePath` 回溯仓库根，不依赖进程的当前工作目录——
/// `swift test` 与 `xcodebuild test` 下的 cwd 不同（M4 期间踩过）。
enum SBCFixtures {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // vInputTests
            .appendingPathComponent("Fixtures/SBC", isDirectory: true)
    }

    static func stream(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("\(name).sbc"))
    }

    /// ffmpeg 解出的参考 PCM（s16le）。
    static func referencePCM(_ name: String) throws -> [Int16] {
        let raw = try Data(contentsOf: directory.appendingPathComponent("\(name).pcm"))
        return stride(from: 0, to: raw.count - 1, by: 2).map {
            Int16(bitPattern: UInt16(raw[$0]) | (UInt16(raw[$0 + 1]) << 8))
        }
    }
}
