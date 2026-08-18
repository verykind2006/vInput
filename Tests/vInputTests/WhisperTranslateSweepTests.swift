import Foundation
import Testing
import WhisperKit

@testable import vInput

/// Whisper 自带 `task = .translate` 的对照装置。
///
/// **它测的是「翻译层能不能不要」。** Whisper 的解码器本身支持直接从语音
/// 解出英文；如果它够用，翻译层可以一个额外模型都不加载、一次额外推理都
/// 不做、零额外延迟——那会直接推翻「再挂一个 7B 翻译器」的整个方向。
/// 不测它就等于没做选型。
///
/// **它只能译成英文**，这是 Whisper 模型的固有限制（解码器只有
/// `<|translate|>` 一个方向，目标语言恒为英文），不是配置问题。所以它最多
/// 解决六种目标语言里的一种，读结论时不要当成全能替代。
///
/// 度量与 MLX 那一侧**完全共用** `TranslationMetrics`——两条路的数不共用
/// 一把尺子就没法比。
///
/// 默认跳过，门控是 `Bench/.whisper-translate.json`（标记文件而非环境变量，
/// 理由同 `TranslationSweepGateTests`）。由 `./scripts/whisper-translate.sh` 写入。
enum WhisperTranslateSweepConfig {
    private struct Raw: Decodable {
        let modelFolder: String
    }

    static var markerURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // vInputTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
            .appendingPathComponent("Bench/.whisper-translate.json")
    }

    static func modelFolder(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
            let raw = try? JSONDecoder().decode(Raw.self, from: data)
        else { return nil }
        return raw.modelFolder
    }

    static var modelFolder: String? { modelFolder(from: markerURL) }

    static var isEnabled: Bool { modelFolder != nil }
}

/// **必须串行**：并发跑多个 Core ML 实例会报
/// `ANE op async execution has timed out`，整片假失败（同 `BenchRunnerTests`）。
@Suite(
    "Whisper 直译对照",
    .enabled(if: WhisperTranslateSweepConfig.isEnabled),
    .serialized
)
struct WhisperTranslateSweepTests {
    private struct Row {
        let entry: BenchEntry
        let output: String
        let elapsed: TimeInterval

        var sourceHan: Int { TranslationMetrics.residualHanCount(entry.text) }
        var outputHan: Int { TranslationMetrics.residualHanCount(output) }
        var terms: [String] { BenchMetrics.technicalTerms(in: entry.text) }
        var termRate: Double {
            TranslationMetrics.termPreservationRate(source: entry.text, translation: output)
        }
        var lengthRatio: Double {
            TranslationMetrics.lengthRatio(source: entry.text, translation: output)
        }
        /// 判据与 `TranslationSweepTests.Row.looksCopied` 一字不差：
        /// 「术语保留 100%」与「把中文原样吐回来」分不开，这一格用来分开它们。
        /// Whisper 这一侧更需要它——`.translate` 失灵的典型表现就是退回转写，
        /// 而转写出来的中文在「术语保留」上是满分。
        var looksCopied: Bool { sourceHan > 0 && outputHan * 2 >= sourceHan }
    }

    @Test("拿基准集录音跑 Whisper 直译")
    func sweep() async throws {
        let modelFolder = try #require(WhisperTranslateSweepConfig.modelFolder)
        let manifest = try BenchManifest.loadFromRepository()

        let startedAt = Date()
        var lines: [String] = [
            "# Whisper 直译（task = .translate）对照报告",
            "时间：\(BenchRunGate.timestampForDisplay(startedAt))",
            "模型：\((modelFolder as NSString).lastPathComponent)",
            "代码：\(BenchRunGate.codeVersion())",
            "",
            "**Whisper 的 .translate 只能译成英文**，这是模型的固有限制，不是配置问题。",
            "它最多解决六种目标语言里的一种，别当成全能替代。",
            "",
            "度量与 MLX 那一侧共用 TranslationMetrics，两栏可以直接对着看。",
            "  汉字 a/b   译文里的汉字数 / 原文里的汉字数。a 接近 b 就是退回了转写。",
            "  术语 a/b   b=0 时不进平均。",
            "  长度比     显著字符数之比。",
            "",
        ]

        let out = WhisperTranslateSweepConfig.markerURL
            .deletingLastPathComponent()
            .appendingPathComponent("whisper-translate.txt")
        func flush() {
            try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        }
        flush()

        var totalRuns = 0
        var totalEmpty = 0

        // **两个变体都要跑：挂生产的中文 initial prompt / 不挂。**
        // 生产路径挂的是一段中文 initial prompt
        // （`Claude Code,Cursor,GitHub,AWS,prompt,token。` 加中文句子），
        // 而这一轮要模型输出英文——中文前缀有可能把输出往中文那边拽。
        // 只跑挂着的那一版，「Whisper 翻译不行」这个结论会和「我们给它挂了
        // 一个中文前缀」混在一起，事后分不开。
        for usePrompt in [true, false] {
            lines.append(String(repeating: "=", count: 72))
            lines.append(
                "【\(usePrompt ? "挂生产 initial prompt（中文）" : "不挂 prompt")】")
            lines.append("")

            let transcriber = WhisperKitTranscriber(
                modelFolder: modelFolder,
                prompt: usePrompt ? WhisperKitTranscriber.punctuationPrompt : "",
                task: .translate
            )
            try await transcriber.prepare()

            var rows: [Row] = []
            for entry in manifest.entries {
                let audioURL = BenchManifest.audioURL(for: entry)
                guard FileManager.default.fileExists(atPath: audioURL.path) else {
                    lines.append("⬜ \(entry.id) 未录音，跳过")
                    continue
                }
                let samples = try BenchRecorder.readWAV(from: audioURL)
                let started = Date()
                let output = try await transcriber.transcribe(samples)
                let row = Row(
                    entry: entry, output: output, elapsed: Date().timeIntervalSince(started))
                rows.append(row)
                totalRuns += 1
                if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    totalEmpty += 1
                }

                var flags: [String] = []
                if row.outputHan > 0 { flags.append("❌汉字") }
                if row.looksCopied { flags.append("⚠退回转写") }
                let mark = flags.isEmpty ? "✅" : flags.joined(separator: " ")
                lines.append(
                    "\(mark) \(row.entry.id)（\(row.entry.category.rawValue)）"
                        + "  \(Self.f(row.elapsed))秒"
                        + "  汉字 \(row.outputHan)/\(row.sourceHan)"
                        + "  术语 \(row.terms.filter(row.output.contains).count)/\(row.terms.count)"
                        + "  长度比 \(Self.f(row.lengthRatio, 2))")
                lines.append("   原文：\(row.entry.text)")
                lines.append("   输出：\(row.output)")
            }

            lines.append("")
            lines.append(contentsOf: Self.summarize(rows: rows))
            lines.append("")
            flush()
        }

        lines.append(String(repeating: "=", count: 72))
        lines.append(
            "总计 \(totalRuns) 次转写，空输出 \(totalEmpty) 次，"
                + "全程 \(Self.f(Date().timeIntervalSince(startedAt))) 秒")
        flush()

        print(lines.joined(separator: "\n"))
        print("报告：\(out.path)")

        // **唯一的断言，与 MLX 那一侧同一条理由。** 本套是测量装置不是回归门，
        // 指标好坏由人判；但「一条都没跑」「全是空输出」必须响——那种情况下
        // 报告里没有任何可读的数，而一份跳过的套件与一份全空的套件在
        // xcodebuild 的输出里长得一样。
        #expect(totalRuns > 0, "一条录音都没跑到，报告里没有任何数据")
        #expect(totalEmpty < totalRuns, "全部 \(totalRuns) 次都是空输出")
    }

    private static func summarize(rows: [Row]) -> [String] {
        guard !rows.isEmpty else { return ["本轮一条都没跑到"] }
        let han = rows.map(\.outputHan)
        let withTerms = rows.filter { !$0.terms.isEmpty }
        let ratios = rows.map(\.lengthRatio)
        let elapsed = rows.map(\.elapsed).sorted()

        var out: [String] = ["合计 \(rows.count) 条"]
        out.append("  残留汉字      共 \(han.reduce(0, +)) 个，涉及 \(han.filter { $0 > 0 }.count) 条")
        out.append(
            "  退回转写      \(rows.filter(\.looksCopied).count) 条（输出汉字数 ≥ 原文的一半）")
        if withTerms.isEmpty {
            out.append("  术语保留      本批无术语可考，这一列读不出任何东西")
        } else {
            let rate = withTerms.map(\.termRate).reduce(0, +) / Double(withTerms.count)
            out.append(
                "  术语保留      \(f(rate, 2))（分母非空 \(withTerms.count) 条；"
                    + "另 \(rows.count - withTerms.count) 条原文无术语，不进这个平均）")
        }
        out.append(
            "  长度比        均 \(f(ratios.reduce(0, +) / Double(ratios.count), 2))"
                + "  最小 \(f(ratios.min() ?? 0, 2))  最大 \(f(ratios.max() ?? 0, 2))")
        out.append(
            "  单条耗时      均 \(f(elapsed.reduce(0, +) / Double(elapsed.count)))"
                + "  中位 \(f(elapsed[elapsed.count / 2]))"
                + "  **最长 \(f(elapsed.last ?? 0))** 秒")
        return out
    }

    private static func f(_ value: Double, _ digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value)
    }
}

@Suite("Whisper 直译的门控")
struct WhisperTranslateGateTests {
    /// 不查「仓库里那个文件此刻在不在」——扫描正在跑的时候它就在，
    /// 那样写会让本条在每次扫描时假失败。查的是解析逻辑本身。
    @Test("没有标记文件时不启用")
    func disabledWithoutMarker() {
        #expect(
            WhisperTranslateSweepConfig.modelFolder(from: URL(fileURLWithPath: "/nonexistent"))
                == nil)
    }

    @Test("标记文件解析出模型目录")
    func parsesMarker() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try #"{"modelFolder":"/tmp/turbo"}"#.write(to: url, atomically: true, encoding: .utf8)

        #expect(WhisperTranslateSweepConfig.modelFolder(from: url) == "/tmp/turbo")
    }

    /// 回溯层数验证：只比对路径尾巴的话，多一级少一级都照样通过，
    /// 而层数错了的后果是门控永远读不到标记文件、扫描永远跳过。
    @Test("标记文件路径落在仓库根下")
    func markerURLResolvesToRepositoryRoot() {
        let root = WhisperTranslateSweepConfig.markerURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Bench/manifest.json").path),
            "回溯到的目录不像仓库根：\(root.path)")
    }
}
