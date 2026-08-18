import Foundation
import Testing

@testable import vInput

/// 蓝牙鼠标音频流的离线解码验收。默认跳过，由标记文件启用：
///
/// ```bash
/// ./scripts/mouse-decode.sh
/// ```
///
/// **判据是「转写出通顺中文」而不是任何中间指标。** M7 第一步曾把这条流
/// 猜成 IMA ADPCM（依据是静音段大量重复的 `55 55 75` 半字节），照那个假设
/// 解出来的样本 55–62% 撞满量程、直流偏置 +13000——那种流听上去是噪音，
/// 但如果只看「样本数 ÷ 时长 ≈ 7000」这类数字，很容易误判成「采样率有点怪
/// 但方向对了」。只有把 PCM 喂给生产转写器才能一眼分辨。
///
/// **门控用标记文件而非环境变量**：`xcodebuild test` 不把父进程环境传给测试
/// 运行器，实测会让整个套件被静默跳过而仍报 TEST SUCCEEDED（M4 期间踩过）。
/// 与 `BenchRunnerTests` 保持同一种门控方式，少一个需要记住的差异。
///
/// **必须串行**：并发跑多个 Core ML 实例会报
/// `ANE op async execution has timed out`。
///
/// ── M7 第三步起，这里同时验两件事 ──────────────────────────────────
/// 1. **生产的 `SBCDecoder` 解同一份裸码流，必须与 ffmpeg 的 WAV 逐样本
///    完全相同。** 这是比转写更硬的判据：合成滤波器带的系数抄错一个，
///    音频只会「能听但发闷」，转写多半照样出得来「测试」——听不出、
///    也测不出。逐样本比对一个字节都藏不住。
/// 2. 喂给转写器的 PCM 来自 **`SBCDecoder`**，不是 ffmpeg 的 WAV。
///    要验的是产品这条路，不是 ffmpeg 那条路。
///
/// 不装 ffmpeg 也能跑的那一份逐样本判据在 `SBCDecoderTests`（夹具已进
/// 版本库）。这里的三段是用户的说话声，`MouseDecode/` 整个在 .gitignore
/// 里，所以只能门控着跑。
@Suite("鼠标音频离线解码", .enabled(if: MouseDecodeGate.isEnabled), .serialized)
struct MouseDecodeTests {
    @Test("Swift 解码器逐样本吻合 ffmpeg，且解出的 PCM 仍能转写")
    func transcribeDecodedSessions() async throws {
        let config = try MouseDecodeGate.config()

        // 与 `BenchRunnerTests` 同一条理由：不接受「不指定模型」。
        // modelFolder 为 nil 时 WhisperKitTranscriber 会落到 modelName 的默认值
        // "base"，联网下载一个产品从不使用的模型（应用默认是 turbo）。
        let modelFolder = config.modelFolder

        // **直接用生产的 WhisperKitTranscriber，不复刻任何解码参数。**
        // 本项目在「复刻一份看起来一样的管线」上栽过两次（Bench.swift 的
        // shim 与生产差了 skipSpecialTokens、promptTokens 两个参数）。
        let transcriber = WhisperKitTranscriber(modelFolder: modelFolder)
        try await transcriber.prepare()

        var lines: [String] = []
        for candidate in config.candidates {
            let wavURL = URL(fileURLWithPath: candidate.wavPath)
            let sbcURL = URL(fileURLWithPath: candidate.sbcPath)
            guard FileManager.default.fileExists(atPath: wavURL.path),
                  FileManager.default.fileExists(atPath: sbcURL.path)
            else {
                lines.append("⬜ \(candidate.label) 文件不存在：\(candidate.sbcPath)")
                continue
            }

            // **产品这条路**：裸 SBC 码流 → 生产的 Swift 解码器 → Int16 PCM。
            let decoder = SBCDecoder()
            let decoded = try decoder.decode(try Data(contentsOf: sbcURL))
            let info = try #require(decoder.lastFrameInfo)

            // **标尺这条路**：同一份码流经 ffmpeg 解出的 WAV。
            // 直接读 WAV 的 data 块拿 Int16，不走 BenchRecorder.readWAV——
            // 那条路返回的是 Float，比对前多一次转换，等于把「差一个整数」
            // 的证据丢掉了。
            let reference = try MouseDecodeWAV.readInt16(from: wavURL)

            var mismatches = 0
            var maxError = 0
            for index in 0..<min(decoded.count, reference.count)
            where decoded[index] != reference[index] {
                mismatches += 1
                maxError = max(maxError, abs(Int(decoded[index]) - Int(reference[index])))
            }
            #expect(decoded.count == reference.count, "\(candidate.label) 样本数与 ffmpeg 不一致")
            #expect(
                mismatches == 0,
                "\(candidate.label)：\(mismatches) 个样本与 ffmpeg 不同，最大绝对误差 \(maxError)"
            )

            // 每帧 128 样本这件事要精确，不能靠总数凑。
            let frameCount = try Data(contentsOf: sbcURL).count / info.frameLength
            #expect(decoded.count == frameCount * info.samplesPerFrame)

            // 归一化用生产的 AudioFormat.normalize，不另写一份。
            // 本项目在「复刻一份看起来一样的管线」上栽过两次。
            let samples = AudioFormat.normalize(decoded)

            // 反算采样率：解出的样本数 ÷ 控制帧时间戳算出的时长。这是独立于
            // 码流头部的一道校验——头里写 16 kHz 而反算出 7 kHz，说明帧结构
            // 拆错了。两者对上才说明「一帧多少样本」这件事没搞错。
            let derivedRate = candidate.durationSeconds > 0
                ? Double(samples.count) / candidate.durationSeconds
                : 0

            // 单条失败不许中断整轮：生产转写器对过短的音频直接抛
            // `.audioTooShort`（`Transcriber.swift:33`），而抓包里那两段
            // 「误触」只有 0.1–0.4 秒，必然命中。第一次跑就是被它整轮打断的，
            // 三段主语音一条都没转出来。
            let text: String
            do {
                text = try await transcriber.transcribe(samples)
            } catch {
                text = "转写失败：\(error)"
            }
            lines.append("""
                \(candidate.label)
                   帧头=\(info.sampleRate)Hz/\(info.blocks)blocks/\(info.subbands)子带/\
                bitpool \(info.bitpool)  帧长=\(info.frameLength)B  每帧样本=\(info.samplesPerFrame)
                   样本=\(samples.count)  控制帧时长=\(String(format: "%.3f", candidate.durationSeconds))s  \
                反算采样率=\(String(format: "%.0f", derivedRate))Hz
                   与 ffmpeg 比对：\(mismatches == 0 ? "逐样本完全相同" : "\(mismatches) 个不同，最大误差 \(maxError)")\
                （参考 \(reference.count) 样本）
                   转写：\(text.isEmpty ? "（空）" : text)
                """)
        }

        var report = "# 鼠标音频离线解码报告\n"
        report += "时间：\(BenchRunGate.timestampForDisplay(Date()))\n"
        report += "模型：\(BenchRunGate.modelShortName(modelFolder))\n"
        report += "代码：\(BenchRunGate.codeVersion())\n"
        report += "抓包：\(config.logPath)\n\n"
        report += lines.joined(separator: "\n") + "\n"

        try report.write(
            to: URL(fileURLWithPath: config.reportPath), atomically: true, encoding: .utf8
        )
        print(report)
        print("报告：\(config.reportPath)")

        // 至少要有一条候选真的被转写了，否则这轮什么都没验证。
        try #require(!lines.isEmpty, "候选列表是空的——mouse-decode.sh 没产出任何 WAV")
    }
}

/// 离线解码实验的门控与配置。配置由 `scripts/mouse-decode.sh` 生成。
enum MouseDecodeGate {
    struct Candidate: Codable {
        /// 人能读的参数说明，直接进报告。
        let label: String
        /// 裸 SBC 码流。生产的 `SBCDecoder` 解这份。
        let sbcPath: String
        /// ffmpeg 解出的 WAV，逐样本比对时当参考答案。
        let wavPath: String
        /// 由控制帧时间戳算出的这段语音的时长，用来反算采样率。
        let durationSeconds: Double
    }

    struct Config: Codable {
        /// Whisper 模型目录的绝对路径。脚本总是解析出具体模型，见 default-model.sh。
        let modelFolder: String
        let logPath: String
        let reportPath: String
        let candidates: [Candidate]
    }

    static var markerURL: URL {
        BenchManifest.repositoryRoot.appendingPathComponent("MouseDecode/.run-config.json")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    static func config() throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: markerURL))
    }
}

/// 只为这个门控测试用的最小 WAV 读取：拿 16 位 PCM 的原始整数样本。
///
/// 生产的 `BenchRecorder.readWAV` 返回 `[Float]`，够转写用，但拿来做
/// 逐样本比对就不行了——Int16 → Float 那一步会把「差一个整数」这个
/// 证据抹掉。这里要的正是那个整数。
enum MouseDecodeWAV {
    struct MalformedWAV: Error { let reason: String }

    static func readInt16(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        guard data.count > 12,
              data[0..<4].elementsEqual("RIFF".utf8),
              data[8..<12].elementsEqual("WAVE".utf8)
        else { throw MalformedWAV(reason: "不是 RIFF/WAVE：\(url.lastPathComponent)") }

        // 逐块跳过。ffmpeg 会在 fmt 与 data 之间插一个 LIST/INFO 块记录
        // 编码器版本——按固定 44 字节偏移读会正好读进那块的内容。
        var cursor = 12
        while cursor + 8 <= data.count {
            let identifier = data[cursor..<(cursor + 4)]
            let size = Int(data[cursor + 4]) | Int(data[cursor + 5]) << 8
                | Int(data[cursor + 6]) << 16 | Int(data[cursor + 7]) << 24
            let body = cursor + 8
            if identifier.elementsEqual("data".utf8) {
                let end = min(body + size, data.count)
                return stride(from: body, to: end - 1, by: 2).map {
                    Int16(bitPattern: UInt16(data[$0]) | (UInt16(data[$0 + 1]) << 8))
                }
            }
            // 块长为奇数时补一个填充字节。
            cursor = body + size + (size & 1)
        }
        throw MalformedWAV(reason: "没找到 data 块：\(url.lastPathComponent)")
    }
}
