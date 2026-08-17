import Foundation
import Testing

@testable import vInput

/// 解码参数变体的三维对照。默认跳过，由标记文件启用：
///
/// ```bash
/// ./scripts/decode-sweep.sh          # 约 40 分钟，报告出到 Bench/decode-sweep.txt
/// ```
///
/// **存在的理由：M6 ⓪ 的修法之争不在「哪个能治丢字」，在「代价是多少」。**
/// 候选的三个变体（关 VAD 分块、关首 token 阈值、放宽首 token 阈值）动的
/// 全是防幻觉机制。只报「长语音不丢字了」而不报「静音会不会开始冒话」，
/// 等于拿一种丢字换另一种丢字，那不是修好。所以本套**一次跑三个维度**，
/// 缺任何一维的结论都不成立：
///
/// 1. **长语音丢字**——`Bench/long-audio-corpus.json` 的三组语料，判据是
///    字数覆盖率（见 `LongAudioTests` 的类型注释：截断的形态是「前面全对、
///    后面整段没了」，CER 会把它摊平）。
/// 2. **静音幻觉**——纯静音与白噪，判据是**最终输出非空的次数**（用户看得见
///    的那一层，`segmentsDroppingFallbackFiller` 之后）。与 `PromptSweepTests`
///    同一把尺子，好跟 M5 那轮「16 次静音零非空」直接对上。
/// 3. **正常语料没退化**——23 条真人基准集的 CER，防止某个变体治好了长音频
///    却把日常那 90% 的录音搞砸。
///
/// **必须重复采样。** 丢字是间歇性的：同一段 31 秒音频、同一个模型、温度 0，
/// 连续跑 12 次里五次丢七次正常（2026-08-17 实测）。Core ML 在 ANE 上的
/// 浮点抖动足够让 −1.86 在 −1.5 阈值两侧来回。**任何单次结果都不足以判定**，
/// 所以报的是失败次数而不是通过/不通过。
///
/// **必须串行**：并发跑多个 Core ML 实例会报 `ANE op async execution has
/// timed out`，整片假失败（与 `BenchRunnerTests`、`LongAudioTests` 同一条）。
@Suite("解码参数对照", .enabled(if: DecodeSweepGate.isEnabled), .serialized)
struct DecodeSweepTests {
    /// 覆盖率下限，与 `LongAudioTests.coverageFloor` 同一个数，理由见那里。
    /// 两处刻意各写各的：这套是诊断对照，那套是回归门；回归门的阈值将来
    /// 收紧时不该顺手改变历史对照表的判据。
    static let coverageFloor = 0.90

    @Test("逐个解码变体跑长语料 + 静音 + 基准集")
    func sweep() async throws {
        let config = try DecodeSweepGate.config()
        // --scaling 模式只跑下面那个耗时测量，不带变体。
        guard !config.variants.isEmpty else { return }
        let modelFolder = try #require(
            config.modelFolder,
            "标记文件里 modelFolder 是 null——用 ./scripts/decode-sweep.sh 启动"
        )
        let manifest = config.runBench ? try? BenchManifest.loadFromRepository() : nil

        var report = "# 解码参数三维对照\n"
        report += "模型：\(BenchRunGate.modelShortName(modelFolder))\n"
        report += "代码：\(BenchRunGate.codeVersion())\n"
        report += "长语料：\(config.longCases.count) 段 TTS 中文，覆盖率取 repeats 次里最差的一次\n"
        report += "静音素材：\(config.silenceFiles.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: " "))"
        report += " 各 \(config.silenceRepeats) 次\n"
        report += "基准集：\(manifest.map { "\($0.entries.count) 条真人录音" } ?? "本轮未跑")\n\n"

        var summary: [DecodeSweepGate.Summary] = []

        for variant in config.variants {
            // 每个变体一个新的转写器：prompt 与解码参数都在构造时定死，
            // prompt 还在 prepare() 里编码并缓存（与 PromptSweepTests 同一条）。
            let transcriber = WhisperKitTranscriber(
                modelFolder: modelFolder, tuning: variant.tuning
            )
            try await transcriber.prepare()

            report += String(repeating: "=", count: 64) + "\n"
            report += "【\(variant.name)】\(variant.describe())\n\n"

            // MARK: 维度一 长语音丢字

            report += "用例        时长    参考字  实际字  覆盖率  CER   失败\n"
            var tails: [String] = []
            var worstCoverage = Double.infinity
            var denseFailures = 0
            var denseRuns = 0
            var longFailures = 0
            var longRuns = 0
            for testCase in config.longCases {
                let samples = try BenchRecorder.readWAV(
                    from: URL(fileURLWithPath: testCase.wav)
                )
                let reference = BenchMetrics.significantCharacters(testCase.text).count

                var caseWorst = Double.infinity
                var caseWorstOutput = ""
                var caseWorstCER = 0.0
                var bad = 0
                let runs = max(1, testCase.repeats)
                for _ in 0..<runs {
                    let output = try await transcriber.transcribe(samples)
                    let actual = BenchMetrics.significantCharacters(output).count
                    let coverage = Double(actual) / Double(reference)
                    if coverage < Self.coverageFloor { bad += 1 }
                    if coverage < caseWorst {
                        caseWorst = coverage
                        caseWorstOutput = output
                        caseWorstCER = BenchMetrics.characterErrorRate(
                            reference: testCase.text, hypothesis: output
                        )
                    }
                }

                longFailures += bad
                longRuns += runs
                worstCoverage = min(worstCoverage, caseWorst)
                if testCase.id == DecodeSweepGate.canaryCaseID {
                    denseFailures = bad
                    denseRuns = runs
                }

                let idColumn = testCase.id.padding(
                    toLength: max(11, testCase.id.count), withPad: " ", startingAt: 0
                )
                report += idColumn + String(
                    format: " %5.1fs %6d %7d %7.3f %6.3f %4d/%d\n",
                    testCase.seconds, reference,
                    BenchMetrics.significantCharacters(caseWorstOutput).count,
                    caseWorst, caseWorstCER, bad, runs
                )
                // 断尾的位置比覆盖率更能说明问题——真机上那次是「改成?」，
                // 半个句子。只记结尾，全文太长，且报告要能 diff。
                tails.append("  \(testCase.id) 最差那次的结尾：…\(String(caseWorstOutput.suffix(24)))")
            }
            report += tails.joined(separator: "\n") + "\n\n"

            // MARK: 维度二 静音幻觉

            // **判据是最终输出非空的次数，不是 CER 也不是「像不像幻觉」。**
            // 静音的正确答案只有一个：空字符串。冒出任何字都是幻觉，
            // 而它会被直接注入到用户正在编辑的文档里。
            var nonEmpty = 0
            var attempts = 0
            var leaks: [String] = []
            for path in config.silenceFiles {
                let url = URL(fileURLWithPath: path)
                let samples = try BenchRecorder.readWAV(from: url)
                for _ in 0..<config.silenceRepeats {
                    attempts += 1
                    let output = try await transcriber.transcribe(samples)
                    guard !output.isEmpty else { continue }
                    nonEmpty += 1
                    leaks.append(
                        "  ⚠️ \(url.deletingPathExtension().lastPathComponent)：\(output)"
                    )
                }
            }
            report += "静音幻觉：\(attempts) 次静音/底噪，非空 \(nonEmpty) 次\n"
            report += leaks.isEmpty ? "" : leaks.joined(separator: "\n") + "\n"
            report += "\n"

            // MARK: 维度三 正常语料没退化

            var benchCER: Double?
            var benchLines: [String] = []
            if let manifest {
                var total = 0.0
                var counted = 0
                var stats: [BenchCategory: (cer: Double, count: Int)] = [:]
                for entry in manifest.entries {
                    let audioURL = BenchManifest.audioURL(for: entry)
                    guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }
                    let samples = try BenchRecorder.readWAV(from: audioURL)
                    let output = try await transcriber.transcribe(samples)
                    let cer = BenchMetrics.characterErrorRate(
                        reference: entry.text, hypothesis: output
                    )
                    total += cer
                    counted += 1
                    let previous = stats[entry.category] ?? (0, 0)
                    stats[entry.category] = (previous.cer + cer, previous.count + 1)
                    if cer > 0.2 {
                        benchLines.append("  ❌ \(entry.id)  CER=\(fmt(cer, 3))\n     实际：\(output)")
                    }
                }
                if counted > 0 {
                    benchCER = total / Double(counted)
                    report += "基准集总体 CER：\(fmt(total / Double(counted), 4))（\(counted) 条）\n"
                    for category in BenchCategory.allCases {
                        guard let stat = stats[category], stat.count > 0 else { continue }
                        report += "  \(category.rawValue)：CER=\(fmt(stat.cer / Double(stat.count), 4))\n"
                    }
                    report += benchLines.isEmpty ? "" : benchLines.joined(separator: "\n") + "\n"
                }
            }
            report += "\n"

            summary.append(
                DecodeSweepGate.Summary(
                    name: variant.name,
                    denseFailures: denseFailures, denseRuns: denseRuns,
                    longFailures: longFailures, longRuns: longRuns,
                    worstCoverage: worstCoverage,
                    silenceNonEmpty: nonEmpty, silenceAttempts: attempts,
                    benchCER: benchCER
                )
            )
            print("跑完变体：\(variant.name)")
        }

        // MARK: 对照表

        // 三个维度并排。**任何一列单独看都会得出错误结论**，摆在一起是为了
        // 让「治好了丢字但静音开始冒话」这种交换一眼可见。
        report += String(repeating: "=", count: 64) + "\n"
        report += "# 对照表\n"
        report += "变体                     \(DecodeSweepGate.canaryCaseID)失败  长语料失败  最低覆盖率  静音非空  基准集CER\n"
        for row in summary {
            let name = row.name.padding(
                toLength: max(24, row.name.count), withPad: " ", startingAt: 0
            )
            report += name + String(
                format: "   %2d/%-2d      %3d/%-3d     %7.3f   %3d/%-3d   ",
                row.denseFailures, row.denseRuns,
                row.longFailures, row.longRuns,
                row.worstCoverage,
                row.silenceNonEmpty, row.silenceAttempts
            )
            report += row.benchCER.map { fmt($0, 4) } ?? "—"
            report += "\n"
        }

        try report.write(to: DecodeSweepGate.reportURL, atomically: true, encoding: .utf8)
        print(report)
        print("报告：\(DecodeSweepGate.reportURL.path)")

        // **本套刻意不做断言。** 它是选型用的对照组，不是回归门——回归门是
        // `LongAudioTests`，它只盯生产那一档。变体跟着生产一起红没有意义，
        // 而「静音非空 3 次算不算红」正是本轮要拿数据回答的问题，不该先写死。
        #expect(!summary.isEmpty, "一个变体都没跑，标记文件是不是空的")
    }

    /// 关掉分块之后，很长的录音会不会变慢或吃内存。
    ///
    /// **这条必须单独量，因为两条路径的并行度不同。** VAD 分块那条会把各块
    /// 丢进 `TaskGroup` 并发解码（`concurrentWorkerCount` 在 macOS 上默认 16，
    /// 见 `vendor/WhisperKit/Sources/WhisperKit/Core/WhisperKit.swift:803-870`）；
    /// 关掉分块走的是 `runTranscribeTask` 里那个 `while seek < …` 的**串行**
    /// 滑窗循环。也就是说「关分块」除了改判据，还顺手把长录音的解码从并发
    /// 变成了串行——录音越长差得越多，而这一点在 90 秒以内的语料上看不出来。
    ///
    /// 内存不在担心之列，看代码就能定：mel 与 encoder 都在窗口循环**内部**
    /// 逐窗算（`TranscribeTask.swift:114-146`），整段留在内存里的只有原始
    /// float 数组，10 分钟 16k 单声道 = 600 × 16000 × 4 B ≈ 38 MB。仍然实测
    /// 一次峰值内存，因为「看代码就能定」这句话本身也该被数据检验。
    ///
    /// 只跑一次，不重复采样：量的是耗时与内存，不是那个间歇性的丢字。
    @Test("超长音频：关分块后的耗时与内存")
    func scaling() async throws {
        let config = try DecodeSweepGate.config()
        let cases = config.scalingCases ?? []
        guard !cases.isEmpty else { return }
        let modelFolder = try #require(config.modelFolder)

        var report = "# 超长音频：分块 on/off 的耗时对照\n"
        report += "模型：\(BenchRunGate.modelShortName(modelFolder))\n"
        report += "代码：\(BenchRunGate.codeVersion())\n\n"
        report += "用例          音频时长   分块  耗时     实时倍率  覆盖率\n"

        for testCase in cases {
            let samples = try BenchRecorder.readWAV(from: URL(fileURLWithPath: testCase.wav))
            let reference = BenchMetrics.significantCharacters(testCase.text).count
            for vad in [true, false] {
                var tuning = DecodeTuning.production
                tuning.vadChunking = vad
                let transcriber = WhisperKitTranscriber(modelFolder: modelFolder, tuning: tuning)
                try await transcriber.prepare()

                let started = Date()
                let output = try await transcriber.transcribe(samples)
                let elapsed = Date().timeIntervalSince(started)
                let actual = BenchMetrics.significantCharacters(output).count

                let idColumn = testCase.id.padding(
                    toLength: max(13, testCase.id.count), withPad: " ", startingAt: 0
                )
                report += idColumn + String(
                    format: " %7.1fs  %-4@ %6.1fs  %7.1fx  %7.3f\n",
                    testCase.seconds, vad ? "on" : "off" as NSString,
                    elapsed, testCase.seconds / elapsed,
                    Double(actual) / Double(reference)
                )
                print("跑完：\(testCase.id) vad=\(vad) \(String(format: "%.1f", elapsed))s")
            }
        }

        let url = DecodeSweepGate.reportURL
            .deletingLastPathComponent()
            .appendingPathComponent("decode-sweep-scaling.txt")
        try report.write(to: url, atomically: true, encoding: .utf8)
        print(report)
        print("报告：\(url.path)")
    }

    private func fmt(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}

/// 解码参数对照的门控与配置。
enum DecodeSweepGate {
    /// 唯一实测会翻车的那条长语料，对照表单列一栏。
    ///
    /// 它是 31.0 秒、一口气说完、VAD 切点落在 15.4 秒的句子中间，与用户
    /// 2026-08-17 报告的那次（31.4 秒、断在「改成?」）同一形态。**其余长度
    /// 的切点碰巧落得好**，所以它们全绿不代表变体有效。
    static let canaryCaseID = "dense-31"

    struct Case: Codable {
        let id: String
        let group: String
        let wav: String
        let text: String
        let seconds: Double
        let repeats: Int
    }

    /// 一个解码参数变体。字段与 `DecodeTuning` 一一对应。
    ///
    /// `Float?` 的字段在 JSON 里**必须显式写出**（值或 `null`）：合成的
    /// Codable 分不清「缺字段」与「显式 null」，而 `null` 在这里是有意义的
    /// 取值（关掉那道检查），不能靠默认值兜。`scripts/decode-sweep.sh` 一律
    /// 全字段输出。
    struct Variant: Codable {
        let name: String
        let vadChunking: Bool
        let firstTokenLogProbThreshold: Float?
        let logProbThreshold: Float?
        let temperatureFallbackCount: Int
        let rescueEmptyChunks: Bool

        var tuning: DecodeTuning {
            DecodeTuning(
                vadChunking: vadChunking,
                firstTokenLogProbThreshold: firstTokenLogProbThreshold,
                logProbThreshold: logProbThreshold,
                temperatureFallbackCount: temperatureFallbackCount,
                rescueEmptyChunks: rescueEmptyChunks
            )
        }

        /// 报告头里那行「这个变体到底改了什么」。手写而不是 dump 结构体，
        /// 是因为报告要给人看、也要能跨轮次 diff。
        func describe() -> String {
            "vad=\(vadChunking ? "on" : "off")"
                + " firstToken=\(firstTokenLogProbThreshold.map { String($0) } ?? "off")"
                + " logProb=\(logProbThreshold.map { String($0) } ?? "off")"
                + " 退火档数=\(temperatureFallbackCount)"
                + (rescueEmptyChunks ? " 空块救援=on" : "")
        }
    }

    struct Config: Codable {
        let modelFolder: String?
        let variants: [Variant]
        let longCases: [Case]
        let silenceFiles: [String]
        let silenceRepeats: Int
        let runBench: Bool
        /// 只在 `--scaling` 模式下有值。可选是为了让旧的标记文件照样解得开。
        let scalingCases: [Case]?
    }

    struct Summary {
        let name: String
        let denseFailures: Int
        let denseRuns: Int
        let longFailures: Int
        let longRuns: Int
        let worstCoverage: Double
        let silenceNonEmpty: Int
        let silenceAttempts: Int
        let benchCER: Double?
    }

    static var markerURL: URL {
        BenchManifest.repositoryRoot.appendingPathComponent("Bench/.decode-sweep.json")
    }

    static var reportURL: URL {
        BenchManifest.repositoryRoot.appendingPathComponent("Bench/decode-sweep.txt")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    static func config() throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: markerURL))
    }
}
