import Foundation
import Testing

@testable import vInput

/// 长音频截断的复现与回归。默认跳过，由标记文件启用：
///
/// ```bash
/// ./scripts/long-audio.sh
/// ```
///
/// **为什么单独一套而不是并进基准集**：基准集 23 条最长的是 15–30 秒，
/// 30 秒以上零覆盖，而 30 秒正是 Whisper 单解码窗口的长度、也是 VAD 分块
/// 的触发点——盲区恰好落在边界外侧。这里用同一段话的逐段加长版扫过边界，
/// 短用例是长用例的前缀，所以「从哪一段开始丢」是直接看得出来的。
///
/// **判据是字数覆盖率，不是 CER。** 截断的形态是「前面全对、后面整段没了」，
/// CER 会把它摊平成一个不大不小的数（丢 30% 就是 0.3），与「到处听错」
/// 分不开；覆盖率把它单独拎出来。CER 仍然照算，用来区分「真丢了」和
/// 「只是听错了几个字」。
///
/// **必须重复采样，一次跑不出来。** 2026-08-17 实测：同一段 31 秒音频、
/// 同一个模型、温度 0，连续跑 8 次，**3 次整块丢字（覆盖率 0.554）、
/// 5 次正常（1.06）**；换个变体又跑出 4/5 与 0/5。丢字的那条路是「首 token
/// 的 logProb 低于 `firstTokenLogProbThreshold = -1.5` 就整窗作废」，而实测
/// 的 logProb 就在 −1.86 附近；Core ML 在 ANE 上的浮点结果有微小抖动，
/// 够它在阈值两侧来回。所以每条跑 `repeats` 次取**最差**的一次。
///
/// **推论：dense 组报绿不等于修好了。** 失败率两到八成，十二次全过也可能
/// 只是运气。判「修好了」要看三个变体的失败次数全为 0 且连续两轮如此；
/// 判「坏了」一次就够。budget 组不受此限——它是确定性的。
///
/// **2026-08-17：dense-31 已修**——生产默认改成不做 VAD 分块
/// （`DecodeTuning.production`，选型对照见 `./scripts/decode-sweep.sh` 与
/// `docs/Roadmap.md` M6 ⓪）。本套从「复现」转为「回归」：它现在守的是
/// 「别再把分块打开」以及「别在别的长度上退化」。
///
/// **budget-24 / budget-27 仍然是红的，且与本条修法无关。** 那是另一条
/// 确定性的边界：124 字的生产 prompt 编成 63 个 token，与采样共用 224 的
/// 预算，只剩 156 个可采样；这两条用 7.6 字/秒的超速语料刻意撞它。修它要
/// 回滚 prompt 长度，而那会牺牲技术类 CER（0.0254 → 0.0584 起），是独立的
/// 产品取舍。
///
/// **必须串行**：并发跑多个 Core ML 实例会报 `ANE op async execution has
/// timed out`，整片假失败（与 `BenchRunnerTests` 同一条）。
@Suite("长音频截断", .enabled(if: LongAudioGate.isEnabled), .serialized)
struct LongAudioTests {
    /// 覆盖率下限。低于此值视为截断。
    ///
    /// 取 0.90：TTS 语料上没出问题的用例实测覆盖率 0.95–1.07（高于 1 是
    /// 模型在块边界上重复了几个字），而出问题的掉到 0.50–0.88，两者之间
    /// 有很宽的间隔，阈值放在这个区间里哪里都不改变结论。留 10% 余量是给
    /// 听错的字与标点差异，不是给丢字的。
    static let coverageFloor = 0.90

    @Test("长音频不该丢字")
    func longAudioIsNotTruncated() async throws {
        let config = try LongAudioGate.config()
        let modelFolder = try #require(
            config.modelFolder,
            "标记文件里 modelFolder 是 null——用 ./scripts/long-audio.sh 启动"
        )

        var report = "# 长音频截断对照\n"
        report += "模型：\(BenchRunGate.modelShortName(modelFolder))\n"
        report += "代码：\(BenchRunGate.codeVersion())\n"
        report += "语料：\(config.cases.count) 段 TTS 中文，"
        report += "覆盖率取 repeats 次里最差的一次\n\n"

        // 生产默认那一档留到最后做断言。其余变体只出数不断言——它们是
        // 诊断用的对照组，跟着生产一起红没有意义。
        var productionWorst: [(id: String, seconds: Double, coverage: Double, bad: Int, runs: Int)] = []

        for variant in config.variants {
            // 每个变体一个新的转写器：prompt 在 prepare() 里编码并缓存，
            // 换 prompt 就得换实例（与 PromptSweepTests 同一条）。
            let transcriber = variant.prompt.map {
                WhisperKitTranscriber(modelFolder: modelFolder, prompt: $0)
            } ?? WhisperKitTranscriber(modelFolder: modelFolder)
            try await transcriber.prepare()

            report += "## \(variant.name)\n"
            report += "用例        时长    参考字  实际字  覆盖率  CER   失败\n"

            var lines: [String] = []
            for testCase in config.cases {
                let samples = try BenchRecorder.readWAV(
                    from: URL(fileURLWithPath: testCase.wav)
                )
                let reference = BenchMetrics.significantCharacters(testCase.text).count

                var worstCoverage = Double.infinity
                var worstOutput = ""
                var worstCER = 0.0
                var bad = 0
                for _ in 0..<max(1, testCase.repeats) {
                    let output = try await transcriber.transcribe(samples)
                    let actual = BenchMetrics.significantCharacters(output).count
                    let coverage = Double(actual) / Double(reference)
                    if coverage < Self.coverageFloor { bad += 1 }
                    if coverage < worstCoverage {
                        worstCoverage = coverage
                        worstOutput = output
                        worstCER = BenchMetrics.characterErrorRate(
                            reference: testCase.text, hypothesis: output
                        )
                    }
                }

                // 手工补空格而不是用 `%-11@`：String(format:) 的宽度修饰符
                // 对 `%@` 行为不一致，且这里的 id 是纯 ASCII，补空格更直白。
                let idColumn = testCase.id.padding(
                    toLength: max(11, testCase.id.count), withPad: " ", startingAt: 0
                )
                report += idColumn + String(
                    format: " %5.1fs %6d %7d %7.3f %6.3f %4d/%d\n",
                    testCase.seconds, reference,
                    BenchMetrics.significantCharacters(worstOutput).count,
                    worstCoverage, worstCER, bad, max(1, testCase.repeats)
                )
                // 断尾的位置比覆盖率更能说明问题——真机上那次是「改成?」，
                // 半个句子。只记结尾，全文太长，且报告要能 diff。
                lines.append("  \(testCase.id) 最差那次的结尾：…\(String(worstOutput.suffix(24)))")

                if variant.prompt == nil {
                    productionWorst.append(
                        (testCase.id, testCase.seconds, worstCoverage, bad,
                         max(1, testCase.repeats))
                    )
                }
            }
            report += lines.joined(separator: "\n") + "\n\n"
            print("跑完变体：\(variant.name)")
        }

        try report.write(to: LongAudioGate.reportURL, atomically: true, encoding: .utf8)
        print(report)
        print("报告：\(LongAudioGate.reportURL.path)")

        // 回归断言：**逐条报，不合并成一个数**。合并的话「31 秒那条时好时坏」
        // 与「所有长度都掉一点」会得到同一个平均值，而这两件事的成因不同。
        for entry in productionWorst {
            #expect(
                entry.coverage >= Self.coverageFloor,
                """
                \(entry.id)（\(String(format: "%.1f", entry.seconds)) 秒）\
                \(entry.runs) 次里 \(entry.bad) 次被截断，最差只出了参考文本的 \
                \(String(format: "%.1f%%", entry.coverage * 100))。\
                详见 \(LongAudioGate.reportURL.lastPathComponent)
                """
            )
        }
    }
}

/// 长音频对照的门控与配置。
enum LongAudioGate {
    struct Case: Codable {
        let id: String
        /// 所属语料组（paced / dense / budget），见 Bench/long-audio-corpus.json。
        let group: String
        /// 合成好的 16k 单声道 WAV 的绝对路径。
        let wav: String
        /// 送进 TTS 的原文，逐字已知，因此丢了多少能精确算。
        let text: String
        let seconds: Double
        /// 重复转写次数，取最差的一次。间歇性失败的组要大于 1，见类型注释。
        let repeats: Int
    }

    struct Variant: Codable {
        let name: String
        /// nil 表示用生产默认的 prompt，空串表示完全不挂 prompt。
        let prompt: String?
    }

    struct Config: Codable {
        let modelFolder: String?
        let cases: [Case]
        let variants: [Variant]
    }

    static var markerURL: URL {
        BenchManifest.repositoryRoot.appendingPathComponent("Bench/.long-audio.json")
    }

    static var reportURL: URL {
        BenchManifest.repositoryRoot.appendingPathComponent("Bench/long-audio.txt")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    static func config() throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: markerURL))
    }
}
