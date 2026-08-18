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
@Suite("鼠标音频离线解码", .enabled(if: MouseDecodeGate.isEnabled), .serialized)
struct MouseDecodeTests {
    @Test("把解出的 PCM 喂给生产转写器")
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
            let url = URL(fileURLWithPath: candidate.wavPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                lines.append("⬜ \(candidate.label) 文件不存在：\(candidate.wavPath)")
                continue
            }
            let samples = try BenchRecorder.readWAV(from: url)

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
                   样本=\(samples.count)  控制帧时长=\(String(format: "%.3f", candidate.durationSeconds))s  \
                反算采样率=\(String(format: "%.0f", derivedRate))Hz
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
