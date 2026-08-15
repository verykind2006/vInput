import Foundation
import Testing

@testable import vInput

/// 基准集对照运行器。默认跳过，由标记文件启用：
///
/// ```bash
/// ./scripts/bench-run.sh                                     # 用默认模型
/// ./scripts/bench-run.sh openai_whisper-large-v3-v20240930_turbo
/// ```
///
/// **门控用标记文件而非环境变量**：`xcodebuild test` 不把父进程环境传给
/// 测试运行器，实测会让整个套件被静默跳过而仍报 TEST SUCCEEDED
/// （M4 期间踩过）。转写层虽然用 `swift test` 就能跑，但保持同一种门控
/// 方式可以少一个需要记住的差异。
///
/// **必须串行**：并发跑十几个 Core ML 实例会报
/// `ANE op async execution has timed out`，整片假失败。
@Suite("基准集对照", .enabled(if: BenchRunGate.isEnabled), .serialized)
struct BenchRunnerTests {
    @Test("跑完全集并输出报告")
    func runFullBenchmark() async throws {
        let manifest = try BenchManifest.loadFromRepository()
        let config = try BenchRunGate.config()

        // 直接用生产的 WhisperKitTranscriber，不复刻任何解码参数。
        // Sources/vInputBench/Bench.swift 的 shim 曾与生产差了两个参数
        // （skipSpecialTokens、promptTokens）而注释写着「保持相同」——
        // 用一条与生产不同的管线去选模型会得到错的结论。
        let transcriber = WhisperKitTranscriber(modelFolder: config.modelFolder)
        try await transcriber.prepare()

        var lines: [String] = []
        var missing: [String] = []
        var totalCER = 0.0
        var counted = 0
        var categoryStats: [BenchCategory: (cer: Double, count: Int)] = [:]
        let startedAt = Date()

        for entry in manifest.entries {
            let audioURL = BenchManifest.audioURL(for: entry)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                lines.append("⬜ \(entry.id) 未录音，跳过")
                missing.append(entry.id)
                continue
            }

            let samples = try BenchRecorder.readWAV(from: audioURL)
            let output = try await transcriber.transcribe(samples)

            let cer = BenchMetrics.characterErrorRate(
                reference: entry.text, hypothesis: output
            )
            totalCER += cer
            counted += 1
            let previous = categoryStats[entry.category] ?? (0, 0)
            categoryStats[entry.category] = (previous.cer + cer, previous.count + 1)

            // 技术词单独看命中率：CER 会把「github actions」算成 13 个字
            // 里错 2 个，看着还行，实际上专名全毁了。分类指标不能被
            // 总体指标取代，这是 M4 用数据换来的教训。
            let terms = BenchMetrics.technicalTerms(in: entry.text)
            let hitNote = terms.isEmpty
                ? ""
                : "  术语=\(String(format: "%.2f", BenchMetrics.termHitRate(terms: terms, in: output)))"

            let mark = cer == 0 ? "✅" : "❌"
            lines.append("""
                \(mark) \(entry.id)  CER=\(String(format: "%.3f", cer))  \
                标点=\(BenchMetrics.punctuationCount(output))\(hitNote)
                   参考：\(entry.text)
                   实际：\(output)
                """)
        }

        let elapsed = Date().timeIntervalSince(startedAt)

        // 一条录音都没有时先把缺哪些打出来，再失败——不然用户只看到一句
        // 断言失败，不知道下一步该做什么。
        if counted == 0 {
            print("""
                基准集里 \(manifest.entries.count) 条全部未录音：
                \(missing.joined(separator: " "))

                录制方法（约半小时，需要你本人读）：
                  ./scripts/build-app.sh
                  open --env VINPUT_BENCH=1 dist/vInput.app
                然后菜单栏 →「开始录制基准集」→ 按提示逐条读 →
                「开始 / 结束本条录音」，读错了用「上一条」重录。
                录音写到 Bench/audio/<id>.wav（不进版本库）。
                """)
        }
        // 用 #require 而非 #expect：counted 为 0 时后面要除以它，
        // 算出来的 NaN 会写进报告，让人以为「跑过了只是数值怪」。
        try #require(
            counted > 0,
            "一条录音都没有——先按上面打印的步骤用 VINPUT_BENCH=1 启动应用录制"
        )

        var report = "# 基准集对照报告\n"
        // 头部这五行是给「两次运行对比」用的：模型与代码版本回答
        // 「这份报告是什么跑出来的」，时间戳与耗时回答「什么时候、多慢」。
        // 逐条耗时刻意不写进报告——它每次都不一样，会让 diff 的每一行都变，
        // 反而看不出质量差异。要看速度看这里的总耗时。
        report += "时间：\(BenchRunGate.timestampForDisplay(startedAt))\n"
        report += "模型：\(config.modelFolder.map(BenchRunGate.modelShortName) ?? "默认")\n"
        report += "代码：\(BenchRunGate.codeVersion())\n"
        // 不含模型加载，只算转写：选模型时关心的是每次听写要等多久，
        // 而模型在应用里是常驻的，加载只发生一次。
        report += "转写耗时：\(String(format: "%.1f", elapsed)) 秒\n"
        report += "样本：\(counted) / \(manifest.entries.count)\n\n"
        report += "总体 CER：\(String(format: "%.4f", totalCER / Double(counted)))\n\n"
        for category in BenchCategory.allCases {
            guard let stat = categoryStats[category], stat.count > 0 else { continue }
            report += "\(category.rawValue)：CER=\(String(format: "%.4f", stat.cer / Double(stat.count)))"
            report += "（\(stat.count) 条）\n"
        }
        report += "\n" + lines.joined(separator: "\n") + "\n"

        // 上一份归档要在写入新归档之前取，否则取到的是自己。
        let previousArchive = BenchRunGate.latestArchive()
        let archiveURL = BenchRunGate.archiveURL(startedAt: startedAt, config: config)
        try FileManager.default.createDirectory(
            at: BenchRunGate.archiveDirectory, withIntermediateDirectories: true
        )
        try report.write(to: archiveURL, atomically: true, encoding: .utf8)
        // report.txt 始终是最近一次，归档目录留全部历史：
        // 「改了 prompt 前后对比」和「换模型对比」是两条不同的对比线，
        // 只留一份最新的报告两条都做不了。
        try report.write(to: BenchRunGate.reportURL, atomically: true, encoding: .utf8)

        print(report)
        print("报告：\(BenchRunGate.relativePath(archiveURL))")
        if let previousArchive {
            print("与上一次对比：diff \(BenchRunGate.relativePath(previousArchive)) \(BenchRunGate.relativePath(archiveURL))")
        }
    }
}

/// 对照运行的门控与配置。
enum BenchRunGate {
    struct Config: Codable {
        /// Whisper 模型目录的绝对路径。nil 表示用默认。
        let modelFolder: String?
    }

    static var markerURL: URL {
        BenchManifest.repositoryRoot.appendingPathComponent("Bench/.run-config.json")
    }

    static var reportURL: URL {
        BenchManifest.repositoryRoot.appendingPathComponent("Bench/report.txt")
    }

    /// 历次报告的归档目录。
    static var archiveDirectory: URL {
        BenchManifest.repositoryRoot.appendingPathComponent("Bench/reports", isDirectory: true)
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    static func config() throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: markerURL))
    }

    /// 模型目录路径 → 目录名。报告里写全路径太长，且换台机器就对不上。
    static func modelShortName(_ folder: String) -> String {
        URL(fileURLWithPath: folder).lastPathComponent
    }

    /// 归档文件名：`<时间戳>-<模型名>.txt`。
    ///
    /// 时间戳在前是为了让 `ls` 按时间排序，模型名在后是为了一眼看出
    /// 哪两份该拿来 diff。**不按模型名覆盖**——同一模型改了 prompt
    /// 前后跑两次也要能对比，覆盖会把「改之前」弄丢。
    static func archiveURL(startedAt: Date, config: Config) -> URL {
        let model = config.modelFolder.map(modelShortName) ?? "default"
        return archiveDirectory.appendingPathComponent(
            "\(timestampForFilename(startedAt))-\(model).txt"
        )
    }

    /// 归档里最近的一份（按文件名排序，等价于按时间排序）。没有则 nil。
    static func latestArchive() -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(
            at: archiveDirectory, includingPropertiesForKeys: nil
        )) ?? []
        return names.filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last
    }

    /// 相对仓库根的路径，用来打印可直接粘贴的命令。
    static func relativePath(_ url: URL) -> String {
        let root = BenchManifest.repositoryRoot.path
        guard url.path.hasPrefix(root + "/") else { return url.path }
        return String(url.path.dropFirst(root.count + 1))
    }

    static func timestampForFilename(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func timestampForDisplay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// 跑这次对照时的代码版本。
    ///
    /// **报告里必须有它**：对照的用途是判断「这次改动让指标变好还是变坏」，
    /// 而只有模型名的两份报告说不清差异来自模型还是来自中间那几次提交。
    /// 工作区脏时标出来——那种情况下 SHA 并不能完整描述跑的是什么代码。
    static func codeVersion() -> String {
        guard let sha = git("rev-parse", "--short", "HEAD"), !sha.isEmpty else {
            return "未知（不在 git 仓库里？）"
        }
        let dirty = git("status", "--porcelain").map { !$0.isEmpty } ?? false
        return dirty ? "\(sha)（有未提交改动）" : sha
    }

    /// 在仓库根跑一条 git 命令，取标准输出。失败返回 nil——报告里写「未知」
    /// 也比让整轮对照崩掉强。
    private static func git(_ arguments: String...) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", BenchManifest.repositoryRoot.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
