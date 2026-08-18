//  移植自 FFmpeg 的 SBC 解码器（LGPL-2.1-or-later）
//  https://github.com/FFmpeg/FFmpeg  tag n8.1
//    libavcodec/sbcdec.c        帧解包、反量化、synthesis filterbank
//    libavcodec/sbcdec_data.h   proto filter 与 synmatrix 系数表
//    libavcodec/sbc.c           CRC-8 与位分配（ff_sbc_crc8 / ff_sbc_calculate_bits）
//    libavcodec/sbc.h           常量（SBCDEC_FIXED_EXTRA_BITS 等）
//  上游版权：Aurelien Jacobs / Intel / Nokia / Marcel Holtmann /
//            Henryk Ploetz / Brad Midgley
//
//  **许可证**：上游是 LGPL-2.1-or-later，本仓库是 GPL-3.0-only。
//  LGPL-2.1-or-later 允许按 LGPL-3.0 使用，LGPL-3.0 又允许并入 GPL-3.0 作品，
//  因此本文件在本仓库内按 GPL-3.0-only 分发。上游版权与许可证声明保留在此。
//
//  对齐的版本：本机 ffmpeg 8.1.1（Homebrew），即上游 n8.1。选这个 tag 是因为
//  逐样本判据的参考答案就是这个二进制解出来的。n7.1 → n8.1 之间 sbcdec.c 的
//  改动只有给乘加加上 `(unsigned)` 强转（消除有符号溢出的未定义行为），
//  数值结果不变。
//
//  相对上游的适配：
//  1. C → Swift 直译。定点运算全部用 `&*`／`&+`（32 位回绕），与上游
//     `(int)((unsigned)a * b + ...)` 的位模式逐位相同——补码下有符号与
//     无符号的乘加结果位模式一致，所以这不是「近似」，是等价。
//  2. **只支持单声道。** DUAL_CHANNEL / STEREO / JOINT_STEREO 与 mSBC 直接
//     报错，不走上游那几条分支（见 `SBCDecodeError`）。理由见下面的注释。
//  3. 上游按「一次一帧」被 libavcodec 的分帧器喂；这里自带 `pending` 缓冲，
//     可以按任意字节切分喂入（BLE 每包 128 字节正好 4 帧，但没有规范保证
//     它永远整除）。
//  4. 系数表原样抄上游的十六进制字面量，移位（SS4/SS8/SN4/SN8）留在代码里做，
//     方便与上游文件逐行对照。**这张表不能凭印象写**：写错了不会崩、不会
//     报错，只会解出「能听但发闷」的音频。
//
//  不要重写或「顺手优化」——判据是与 ffmpeg 逐样本相同（`SBCDecoderTests`），
//  任何看似等价的改写都可能悄悄改掉一个舍入。

import Foundation

/// SBC 的声道模式。取值即帧头 `header[1]` 的 bit3–2。
enum SBCChannelMode: UInt8, Sendable, CaseIterable {
    case mono = 0
    case dualChannel = 1
    case stereo = 2
    case jointStereo = 3
}

/// SBC 的位分配方式。取值即帧头 `header[1]` 的 bit1。
enum SBCAllocationMethod: UInt8, Sendable, CaseIterable {
    case loudness = 0
    case snr = 1
}

/// 一帧 SBC 的配置。**全部从帧头读出来，没有一项是假设的。**
///
/// 鼠标固件现在发的是 16 kHz / 16 blocks / MONO / Loudness / 8 子带 /
/// bitpool 12（帧头 `9C 31 0C`）。固件升级后这些都可能变——那时该报错，
/// 而不是照旧配置解出噪音。
struct SBCFrameInfo: Equatable, Sendable {
    let sampleRate: Int
    let blocks: Int
    let channelMode: SBCChannelMode
    let allocation: SBCAllocationMethod
    let subbands: Int
    let bitpool: UInt8

    var channels: Int { channelMode == .mono ? 1 : 2 }

    /// 每帧的样本数（每声道）。16 blocks × 8 子带 = 128 个样本 = 16 kHz 下 8 ms。
    var samplesPerFrame: Int { blocks * subbands }

    /// 帧长（字节）。规范里的公式，MONO/DUAL 分支：
    /// `4 + 4 × 子带数 × 声道数 / 8 + ceil(blocks × 声道数 × bitpool / 8)`。
    /// 设备配置代进去是 `4 + 4 + 24 = 32`，与真机抓包一致。
    var frameLength: Int {
        4 + (4 * subbands * channels) / 8 + (blocks * channels * Int(bitpool) + 7) / 8
    }
}

enum SBCDecodeError: Error, Equatable {
    /// 不足一个帧头（4 字节），读不出配置。只有 `frameInfo(of:)` 会抛它——
    /// `decode(_:)` 把不足一帧的尾巴留在缓冲里，那是正常情况不是错误。
    case truncatedHeader(byteCount: Int)
    /// 第一个字节既不是 SBC 的 0x9C 也不是 mSBC 的 0xAD。
    case badSyncword(UInt8)
    /// mSBC（0xAD）：帧结构不同（隐含头、每帧固定 15 blocks），按 SBC 解是噪音。
    case unsupportedMSBC
    /// 只实现了单声道。见文件头「适配 2」。
    case unsupportedChannelMode(SBCChannelMode)
    /// bitpool 超出规范上限（MONO/DUAL 是 16 × 子带数）。
    case bitpoolOutOfRange(UInt8)
    /// 帧头 CRC-8 对不上：这一帧被截断或损坏了。
    case crcMismatch(expected: UInt8, actual: UInt8)
}

/// 裸 SBC 码流 → 16 位 PCM。
///
/// **合成滤波器带跨帧状态**（`v` 与 `offset`），所以同一条流必须用同一个
/// 实例按顺序解；换一条流要先 `reset()`。
///
/// 用法：
/// ```swift
/// let decoder = SBCDecoder()
/// let pcm = try decoder.decode(packet)   // 可按任意字节切分反复喂
/// ```
final class SBCDecoder {
    /// 最近一帧的配置。解完至少一帧后才非 nil。
    private(set) var lastFrameInfo: SBCFrameInfo?

    /// 上一次喂进来但不足一整帧的尾巴。
    private var pending = Data()

    /// 合成滤波器带的历史。上游 `struct sbc_decoder_state`：`V[2][170]`。
    /// 只做单声道，所以只留一路。
    private var v = [Int32](repeating: 0, count: 170)
    private var offset = [Int](repeating: 0, count: 16)

    /// 反量化后的子带样本，`[blocks][subbands]`。复用同一块内存避免每帧重分配。
    private var subbandSamples = [Int32](repeating: 0, count: 16 * 8)

    init() {
        reset()
    }

    /// 清掉滤波器带历史与未解完的尾巴。开始一段新的录音时必须调用。
    func reset() {
        lastFrameInfo = nil
        pending.removeAll(keepingCapacity: true)
        for index in v.indices { v[index] = 0 }
        // 上游 sbc_decode_init：offset[i] = 10 * i + 10
        for index in offset.indices { offset[index] = 10 * index + 10 }
    }

    /// 解一段码流。不足一整帧的尾巴留在内部缓冲里，下次接着解。
    ///
    /// - Throws: `SBCDecodeError`。**遇到不认识的配置或坏帧就抛错，不猜。**
    ///
    /// 抛错后出错的字节**仍留在缓冲里**，再调一次会抛同一个错——想继续必须
    /// 先 `reset()`。这是刻意的：坏帧之后自动往前找下一个 `0x9C` 重新同步，
    /// 看起来更「健壮」，实际是在猜——`0x9C` 也可能只是音频数据里的一个字节，
    /// 对上了就会解出一整段噪音。**丢包该怎么处理是接 `AudioSource` 那一步
    /// 的策略问题**（重同步？丢弃整段？补静音？），不该由解码器偷偷决定。
    func decode(_ data: some DataProtocol) throws -> [Int16] {
        pending.append(contentsOf: data)

        var output: [Int16] = []
        var cursor = 0
        let bytes = [UInt8](pending)

        while cursor + 4 <= bytes.count {
            let info = try Self.parseHeader(bytes, at: cursor)
            let length = info.frameLength
            guard cursor + length <= bytes.count else { break }

            try decodeFrame(bytes, at: cursor, info: info, into: &output)
            lastFrameInfo = info
            cursor += length
        }

        pending = Data(bytes[cursor...])
        return output
    }

    /// 只读帧头，不解音频。用来在接入前确认设备发的是什么配置。
    static func frameInfo(of data: some DataProtocol) throws -> SBCFrameInfo {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else {
            throw SBCDecodeError.truncatedHeader(byteCount: bytes.count)
        }
        return try parseHeader(bytes, at: 0)
    }

    // MARK: - 帧头

    private static func parseHeader(_ bytes: [UInt8], at start: Int) throws -> SBCFrameInfo {
        let syncword = bytes[start]
        guard syncword != 0xAD else { throw SBCDecodeError.unsupportedMSBC }
        guard syncword == 0x9C else { throw SBCDecodeError.badSyncword(syncword) }

        let b1 = bytes[start + 1]
        let sampleRates = [16_000, 32_000, 44_100, 48_000]
        let sampleRate = sampleRates[Int((b1 >> 6) & 0x03)]
        let blocks = 4 * Int((b1 >> 4) & 0x03) + 4
        // rawValue 一定在 0...3，强解包安全。
        let mode = SBCChannelMode(rawValue: (b1 >> 2) & 0x03)!
        let allocation = SBCAllocationMethod(rawValue: (b1 >> 1) & 0x01)!
        let subbands = (b1 & 0x01) != 0 ? 8 : 4
        let bitpool = bytes[start + 2]

        // **声道模式先于 CRC 校验。** CRC 覆盖 header[1]，配置位一变 CRC 必然
        // 也对不上；如果先报 CRC 错，日志里看到的是「码流损坏」，而真相是
        // 「固件换成立体声了」——这两件事该分得开。
        guard mode == .mono else { throw SBCDecodeError.unsupportedChannelMode(mode) }

        // 规范：MONO/DUAL 的 bitpool 上限是 16 × 子带数。
        guard Int(bitpool) <= 16 * subbands else { throw SBCDecodeError.bitpoolOutOfRange(bitpool) }

        return SBCFrameInfo(
            sampleRate: sampleRate, blocks: blocks, channelMode: mode,
            allocation: allocation, subbands: subbands, bitpool: bitpool
        )
    }

    // MARK: - 解一帧（上游 sbc_unpack_frame + sbc_synthesize_audio）

    private func decodeFrame(
        _ bytes: [UInt8], at start: Int, info: SBCFrameInfo, into output: inout [Int16]
    ) throws {
        let subbands = info.subbands
        let blocks = info.blocks

        // CRC 覆盖 header[1]、header[2] 与全部 scale factor 位（单声道无 joint 位）。
        var crcBuffer = [UInt8](repeating: 0, count: 11)
        crcBuffer[0] = bytes[start + 1]
        crcBuffer[1] = bytes[start + 2]
        var crcPos = 16

        var consumed = 32
        var scaleFactor = [Int](repeating: 0, count: 8)
        for sb in 0..<subbands {
            let value = Int((bytes[start + (consumed >> 3)] >> (4 - UInt8(consumed & 0x7))) & 0x0F)
            scaleFactor[sb] = value
            crcBuffer[crcPos >> 3] |= UInt8(value) << (4 - UInt8(crcPos & 0x7))
            consumed += 4
            crcPos += 4
        }

        let crc = Self.crc8(crcBuffer, bitCount: crcPos)
        guard crc == bytes[start + 3] else {
            throw SBCDecodeError.crcMismatch(expected: bytes[start + 3], actual: crc)
        }

        let bits = Self.calculateBits(info: info, scaleFactor: scaleFactor)
        var levels = [UInt64](repeating: 0, count: 8)
        for sb in 0..<subbands { levels[sb] = (1 << UInt64(bits[sb])) - 1 }

        // 反量化。上游 SBCDEC_FIXED_EXTRA_BITS = 2：给合成滤波器带多留两位精度。
        for blk in 0..<blocks {
            for sb in 0..<subbands {
                guard levels[sb] != 0 else {
                    subbandSamples[blk * 8 + sb] = 0
                    continue
                }
                let shift = UInt64(scaleFactor[sb] + 1 + Self.fixedExtraBits)

                var audioSample: UInt64 = 0
                for bit in 0..<bits[sb] {
                    if (bytes[start + (consumed >> 3)] >> (7 - UInt8(consumed & 0x7))) & 0x01 != 0 {
                        audioSample |= 1 << UInt64(bits[sb] - bit - 1)
                    }
                    consumed += 1
                }

                let scaled = (((audioSample << 1) | 1) << shift) / levels[sb]
                subbandSamples[blk * 8 + sb] =
                    Int32(truncatingIfNeeded: scaled) &- Int32(truncatingIfNeeded: UInt64(1) << shift)
            }
        }

        // 合成滤波器带。
        output.reserveCapacity(output.count + blocks * subbands)
        for blk in 0..<blocks {
            if subbands == 8 {
                synthesizeEight(blk, into: &output)
            } else {
                synthesizeFour(blk, into: &output)
            }
        }
    }

    // MARK: - 合成滤波器带（上游 sbc_synthesize_eight / sbc_synthesize_four）

    private func synthesizeEight(_ blk: Int, into output: inout [Int16]) {
        let base = blk * 8
        for i in 0..<16 {
            offset[i] -= 1
            if offset[i] < 0 {
                offset[i] = 159
                for j in 0..<9 { v[160 + j] = v[j] }
            }
            var accumulator: Int32 = 0
            for j in 0..<8 {
                accumulator = accumulator &+ (Self.synmatrix8[i][j] &* subbandSamples[base + j])
            }
            v[offset[i]] = accumulator >> 15
        }

        for i in 0..<8 {
            let k = (i + 8) & 0xF
            let idx = i * 5
            var accumulator: Int32 = 0
            for j in 0..<5 {
                accumulator = accumulator &+ (v[offset[i] + 2 * j] &* Self.proto8m0[idx + j])
                accumulator = accumulator &+ (v[offset[k] + 2 * j + 1] &* Self.proto8m1[idx + j])
            }
            output.append(Int16(clamping: accumulator >> 15))
        }
    }

    private func synthesizeFour(_ blk: Int, into output: inout [Int16]) {
        let base = blk * 8
        for i in 0..<8 {
            offset[i] -= 1
            if offset[i] < 0 {
                offset[i] = 79
                for j in 0..<9 { v[80 + j] = v[j] }
            }
            var accumulator: Int32 = 0
            for j in 0..<4 {
                accumulator = accumulator &+ (Self.synmatrix4[i][j] &* subbandSamples[base + j])
            }
            v[offset[i]] = accumulator >> 15
        }

        for i in 0..<4 {
            let k = (i + 4) & 0xF
            let idx = i * 5
            var accumulator: Int32 = 0
            for j in 0..<5 {
                accumulator = accumulator &+ (v[offset[i] + 2 * j] &* Self.proto4m0[idx + j])
                accumulator = accumulator &+ (v[offset[k] + 2 * j + 1] &* Self.proto4m1[idx + j])
            }
            output.append(Int16(clamping: accumulator >> 15))
        }
    }

    // MARK: - CRC-8（上游 ff_sbc_crc8 + AV_CRC_8_EBU）

    /// 多项式 0x1D、初值 0x0F、不反转，按**位**算——覆盖长度不是 8 的整数倍
    /// （单声道 8 子带是 16 + 32 = 48 位，正好整除；4 子带就只有 32 位 + 半字节）。
    static func crc8(_ buffer: [UInt8], bitCount: Int) -> UInt8 {
        var crc: UInt8 = 0x0F
        for index in 0..<bitCount {
            let bit = (buffer[index >> 3] >> (7 - UInt8(index & 7))) & 1
            let msb = (crc >> 7) & 1
            crc = crc << 1
            if msb != bit { crc ^= 0x1D }
        }
        return crc
    }

    // MARK: - 位分配（上游 ff_sbc_calculate_bits，MONO/DUAL 分支）

    private static let fixedExtraBits = 2

    /// A2DP 规范 Appendix B, page 69。
    private static let offset4: [[Int]] = [
        [-1, 0, 0, 0],
        [-2, 0, 0, 1],
        [-2, 0, 0, 1],
        [-2, 0, 0, 1],
    ]

    /// A2DP 规范 Appendix B, page 69。
    private static let offset8: [[Int]] = [
        [-2, 0, 0, 0, 0, 0, 0, 1],
        [-3, 0, 0, 0, 0, 0, 1, 2],
        [-4, 0, 0, 0, 0, 0, 1, 2],
        [-4, 0, 0, 0, 0, 0, 1, 2],
    ]

    /// 直译自规范的位分配。**逐行照抄，不要「化简」**——`bitneed` 的正负分支、
    /// `bitslice` 的收敛条件都是规范写死的，改一处就与编码器对不上。
    static func calculateBits(info: SBCFrameInfo, scaleFactor: [Int]) -> [Int] {
        let subbands = info.subbands
        let frequencyIndex = [16_000, 32_000, 44_100, 48_000].firstIndex(of: info.sampleRate)!
        let bitpool = Int(info.bitpool)

        var bitneed = [Int](repeating: 0, count: 8)
        var maxBitneed = 0
        if info.allocation == .snr {
            for sb in 0..<subbands {
                bitneed[sb] = scaleFactor[sb]
                maxBitneed = max(maxBitneed, bitneed[sb])
            }
        } else {
            let offsets = subbands == 4 ? offset4[frequencyIndex] : offset8[frequencyIndex]
            for sb in 0..<subbands {
                if scaleFactor[sb] == 0 {
                    bitneed[sb] = -5
                } else {
                    let loudness = scaleFactor[sb] - offsets[sb]
                    bitneed[sb] = loudness > 0 ? loudness / 2 : loudness
                }
                maxBitneed = max(maxBitneed, bitneed[sb])
            }
        }

        var bitcount = 0
        var slicecount = 0
        var bitslice = maxBitneed + 1
        repeat {
            bitslice -= 1
            bitcount += slicecount
            slicecount = 0
            for sb in 0..<subbands {
                if bitneed[sb] > bitslice + 1 && bitneed[sb] < bitslice + 16 {
                    slicecount += 1
                } else if bitneed[sb] == bitslice + 1 {
                    slicecount += 2
                }
            }
        } while bitcount + slicecount < bitpool

        if bitcount + slicecount == bitpool {
            bitcount += slicecount
            bitslice -= 1
        }

        var bits = [Int](repeating: 0, count: 8)
        for sb in 0..<subbands {
            if bitneed[sb] < bitslice + 2 {
                bits[sb] = 0
            } else {
                bits[sb] = min(bitneed[sb] - bitslice, 16)
            }
        }

        var sb = 0
        while bitcount < bitpool && sb < subbands {
            if bits[sb] >= 2 && bits[sb] < 16 {
                bits[sb] += 1
                bitcount += 1
            } else if bitneed[sb] == bitslice + 1 && bitpool > bitcount + 1 {
                bits[sb] = 2
                bitcount += 2
            }
            sb += 1
        }

        sb = 0
        while bitcount < bitpool && sb < subbands {
            if bits[sb] < 16 {
                bits[sb] += 1
                bitcount += 1
            }
            sb += 1
        }

        return bits
    }

    // MARK: - 系数表（上游 libavcodec/sbcdec_data.h，逐个字面量照抄）
    //
    // **这张表不能凭印象写。** 上游用宏做移位：
    //   SS4(v) = (int32_t)v >> 12
    //   SS8(v) = (int32_t)v >> 14
    //   SN4(v) = SN8(v) = (int32_t)v >> (11 + 1 + SBCDEC_FIXED_EXTRA_BITS) = >> 14
    // 这里保留原始十六进制、把移位放在代码里，是为了能与上游文件逐行对照。

    private static let proto4m0: [Int32] = [
        0x00000000, 0xffa6982f, 0xfba93848, 0x0456c7b8,
        0x005967d1, 0xfffb9ac7, 0xff589157, 0xf9c2a8d8,
        0x027c1434, 0x0019118b, 0xfff3c74c, 0xff137330,
        0xf81b8d70, 0x00ec1b8b, 0xfff0b71a, 0xffe99b00,
        0xfef84470, 0xf6fb4370, 0xffcdc351, 0xffe01dc7,
    ].map { Int32(bitPattern: $0) >> 12 }

    private static let proto4m1: [Int32] = [
        0xffe090ce, 0xff2c0475, 0xf694f800, 0xff2c0475,
        0xffe090ce, 0xffe01dc7, 0xffcdc351, 0xf6fb4370,
        0xfef84470, 0xffe99b00, 0xfff0b71a, 0x00ec1b8b,
        0xf81b8d70, 0xff137330, 0xfff3c74c, 0x0019118b,
        0x027c1434, 0xf9c2a8d8, 0xff589157, 0xfffb9ac7,
    ].map { Int32(bitPattern: $0) >> 12 }

    private static let proto8m0: [Int32] = [
        0x00000000, 0xfe8d1970, 0xee979f00, 0x11686100,
        0x0172e690, 0xfff5bd1a, 0xfdf1c8d4, 0xeac182c0,
        0x0d9daee0, 0x00e530da, 0xffe9811d, 0xfd52986c,
        0xe7054ca0, 0x0a00d410, 0x006c1de4, 0xffdba705,
        0xfcbc98e8, 0xe3889d20, 0x06af2308, 0x000bb7db,
        0xffca00ed, 0xfc3fbb68, 0xe071bc00, 0x03bf7948,
        0xffc4e05c, 0xffb54b3b, 0xfbedadc0, 0xdde26200,
        0x0142291c, 0xff960e94, 0xff9f3e17, 0xfbd8f358,
        0xdbf79400, 0xff405e01, 0xff7d4914, 0xff8b1a31,
        0xfc1417b8, 0xdac7bb40, 0xfdbb828c, 0xff762170,
    ].map { Int32(bitPattern: $0) >> 14 }

    private static let proto8m1: [Int32] = [
        0xff7c272c, 0xfcb02620, 0xda612700, 0xfcb02620,
        0xff7c272c, 0xff762170, 0xfdbb828c, 0xdac7bb40,
        0xfc1417b8, 0xff8b1a31, 0xff7d4914, 0xff405e01,
        0xdbf79400, 0xfbd8f358, 0xff9f3e17, 0xff960e94,
        0x0142291c, 0xdde26200, 0xfbedadc0, 0xffb54b3b,
        0xffc4e05c, 0x03bf7948, 0xe071bc00, 0xfc3fbb68,
        0xffca00ed, 0x000bb7db, 0x06af2308, 0xe3889d20,
        0xfcbc98e8, 0xffdba705, 0x006c1de4, 0x0a00d410,
        0xe7054ca0, 0xfd52986c, 0xffe9811d, 0x00e530da,
        0x0d9daee0, 0xeac182c0, 0xfdf1c8d4, 0xfff5bd1a,
    ].map { Int32(bitPattern: $0) >> 14 }

    private static let synmatrix4: [[Int32]] = [
        [0x05a82798, 0xfa57d868, 0xfa57d868, 0x05a82798],
        [0x030fbc54, 0xf89be510, 0x07641af0, 0xfcf043ac],
        [0x00000000, 0x00000000, 0x00000000, 0x00000000],
        [0xfcf043ac, 0x07641af0, 0xf89be510, 0x030fbc54],
        [0xfa57d868, 0x05a82798, 0x05a82798, 0xfa57d868],
        [0xf89be510, 0xfcf043ac, 0x030fbc54, 0x07641af0],
        [0xf8000000, 0xf8000000, 0xf8000000, 0xf8000000],
        [0xf89be510, 0xfcf043ac, 0x030fbc54, 0x07641af0],
    ].map { $0.map { Int32(bitPattern: $0) >> 14 } }

    private static let synmatrix8: [[Int32]] = [
        [0x05a82798, 0xfa57d868, 0xfa57d868, 0x05a82798,
         0x05a82798, 0xfa57d868, 0xfa57d868, 0x05a82798],
        [0x0471ced0, 0xf8275a10, 0x018f8b84, 0x06a6d988,
         0xf9592678, 0xfe70747c, 0x07d8a5f0, 0xfb8e3130],
        [0x030fbc54, 0xf89be510, 0x07641af0, 0xfcf043ac,
         0xfcf043ac, 0x07641af0, 0xf89be510, 0x030fbc54],
        [0x018f8b84, 0xfb8e3130, 0x06a6d988, 0xf8275a10,
         0x07d8a5f0, 0xf9592678, 0x0471ced0, 0xfe70747c],
        [0x00000000, 0x00000000, 0x00000000, 0x00000000,
         0x00000000, 0x00000000, 0x00000000, 0x00000000],
        [0xfe70747c, 0x0471ced0, 0xf9592678, 0x07d8a5f0,
         0xf8275a10, 0x06a6d988, 0xfb8e3130, 0x018f8b84],
        [0xfcf043ac, 0x07641af0, 0xf89be510, 0x030fbc54,
         0x030fbc54, 0xf89be510, 0x07641af0, 0xfcf043ac],
        [0xfb8e3130, 0x07d8a5f0, 0xfe70747c, 0xf9592678,
         0x06a6d988, 0x018f8b84, 0xf8275a10, 0x0471ced0],
        [0xfa57d868, 0x05a82798, 0x05a82798, 0xfa57d868,
         0xfa57d868, 0x05a82798, 0x05a82798, 0xfa57d868],
        [0xf9592678, 0x018f8b84, 0x07d8a5f0, 0x0471ced0,
         0xfb8e3130, 0xf8275a10, 0xfe70747c, 0x06a6d988],
        [0xf89be510, 0xfcf043ac, 0x030fbc54, 0x07641af0,
         0x07641af0, 0x030fbc54, 0xfcf043ac, 0xf89be510],
        [0xf8275a10, 0xf9592678, 0xfb8e3130, 0xfe70747c,
         0x018f8b84, 0x0471ced0, 0x06a6d988, 0x07d8a5f0],
        [0xf8000000, 0xf8000000, 0xf8000000, 0xf8000000,
         0xf8000000, 0xf8000000, 0xf8000000, 0xf8000000],
        [0xf8275a10, 0xf9592678, 0xfb8e3130, 0xfe70747c,
         0x018f8b84, 0x0471ced0, 0x06a6d988, 0x07d8a5f0],
        [0xf89be510, 0xfcf043ac, 0x030fbc54, 0x07641af0,
         0x07641af0, 0x030fbc54, 0xfcf043ac, 0xf89be510],
        [0xf9592678, 0x018f8b84, 0x07d8a5f0, 0x0471ced0,
         0xfb8e3130, 0xf8275a10, 0xfe70747c, 0x06a6d988],
    ].map { $0.map { Int32(bitPattern: $0) >> 14 } }
}
