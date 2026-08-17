import Foundation
import Testing

@testable import vInput

/// initial prompt 的候选对照（临时实验脚手架，结论落定后删除）。
///
/// ```bash
/// ./scripts/prompt-sweep.sh openai_whisper-large-v3-v20240930_turbo
/// ```
///
/// 与 `BenchRunnerTests` 同样用标记文件门控、同样 `.serialized`——
/// 并发跑多个 Core ML 实例会报 ANE 超时。
@Suite("prompt 候选对照", .enabled(if: PromptSweepGate.isEnabled), .serialized)
struct PromptSweepTests {
    @Test("逐个候选跑全集 + 泄漏检测")
    func sweep() async throws {
        let manifest = try BenchManifest.loadFromRepository()
        let config = try PromptSweepGate.config()
        let noiseFiles = PromptSweepGate.noiseFiles(in: config.noiseDir)

        // 与 BenchRunnerTests 同一道门槛：modelFolder 为 nil 会让转写器落到
        // "base" 并联网下载它，扫九个候选就是九遍 base，结论与产品无关
        // （2026-08-17 独立验收 F1）。报告头也只写具体目录名，不写「默认」。
        let modelFolder = try #require(
            config.modelFolder,
            "标记文件里 modelFolder 是 null——用 ./scripts/prompt-sweep.sh 启动"
        )

        var report = "# prompt 候选对照\n"
        report += "模型：\(BenchRunGate.modelShortName(modelFolder))\n"
        report += "泄漏样本：\(noiseFiles.map(\.lastPathComponent).joined(separator: " ")) 各 \(config.leakRepeats) 次\n\n"

        for candidate in config.candidates {
            // 每个候选一个新的转写器：prompt 在 prepare() 时编码并缓存，
            // 换 prompt 就得换实例。模型因此要重复加载，几秒的代价换
            // 「一次跑完全部候选、指标写进同一份报告」是值得的。
            let transcriber = WhisperKitTranscriber(
                modelFolder: modelFolder, prompt: candidate.prompt
            )
            try await transcriber.prepare()

            var lines: [String] = []
            var totalCER = 0.0
            var counted = 0
            var stats: [BenchCategory: (cer: Double, count: Int, punct: Int, hit: Double)] = [:]

            for entry in manifest.entries {
                let audioURL = BenchManifest.audioURL(for: entry)
                guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }
                let samples = try BenchRecorder.readWAV(from: audioURL)
                let output = try await transcriber.transcribe(samples)

                let cer = BenchMetrics.characterErrorRate(
                    reference: entry.text, hypothesis: output
                )
                let terms = BenchMetrics.technicalTerms(in: entry.text)
                let hit = terms.isEmpty
                    ? 1.0 : BenchMetrics.termHitRate(terms: terms, in: output)
                let punct = BenchMetrics.punctuationCount(output)

                totalCER += cer
                counted += 1
                let previous = stats[entry.category] ?? (0, 0, 0, 0)
                stats[entry.category] = (
                    previous.cer + cer, previous.count + 1,
                    previous.punct + punct, previous.hit + hit
                )

                let hitNote = terms.isEmpty ? "" : "  术语=\(fmt(hit, 2))"
                lines.append(
                    "  \(cer == 0 ? "✅" : "❌") \(entry.id)  CER=\(fmt(cer, 3))  "
                    + "标点=\(punct)\(hitNote)\n     实际：\(output)"
                )
            }

            // 泄漏与幻觉：静音/底噪各跑若干次，看最终输出（用户看得见的那层）
            // 是否非空、是否含 prompt 里的词。
            var leaks: [String] = []
            var nonEmpty = 0
            var attempts = 0
            for file in noiseFiles {
                let samples = try BenchRecorder.readWAV(from: file)
                for _ in 0..<config.leakRepeats {
                    attempts += 1
                    let output = try await transcriber.transcribe(samples)
                    guard !output.isEmpty else { continue }
                    nonEmpty += 1
                    leaks.append("  ⚠️ \(file.deletingPathExtension().lastPathComponent)：\(output)")
                }
            }

            report += String(repeating: "=", count: 60) + "\n"
            report += "【\(candidate.name)】\(candidate.prompt.count) 字\n"
            report += "\(candidate.prompt)\n\n"
            report += "总体 CER：\(fmt(totalCER / Double(max(counted, 1)), 4))（\(counted) 条）\n"
            for category in BenchCategory.allCases {
                guard let stat = stats[category], stat.count > 0 else { continue }
                let n = Double(stat.count)
                report += "\(category.rawValue)：CER=\(fmt(stat.cer / n, 4))"
                report += "  标点合计=\(stat.punct)"
                if category == .technical { report += "  术语命中=\(fmt(stat.hit / n, 3))" }
                report += "\n"
            }
            report += "泄漏：\(attempts) 次静音/底噪，非空 \(nonEmpty) 次\n"
            report += leaks.isEmpty ? "" : leaks.joined(separator: "\n") + "\n"
            report += "\n" + lines.joined(separator: "\n") + "\n\n"

            print("跑完候选：\(candidate.name)")
        }

        try report.write(to: PromptSweepGate.reportURL, atomically: true, encoding: .utf8)
        print(report)
        print("报告：\(PromptSweepGate.reportURL.path)")
    }

    private func fmt(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}

enum PromptSweepGate {
    struct Candidate: Codable {
        let name: String
        let prompt: String
    }

    struct Config: Codable {
        let modelFolder: String?
        let noiseDir: String
        let leakRepeats: Int
        let candidates: [Candidate]
    }

    static var markerURL: URL {
        BenchManifest.repositoryRoot.appendingPathComponent("Bench/.prompt-sweep.json")
    }

    static var reportURL: URL {
        BenchManifest.repositoryRoot.appendingPathComponent("Bench/prompt-sweep.txt")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    static func config() throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: markerURL))
    }

    static func noiseFiles(in directory: String) -> [URL] {
        let url = URL(fileURLWithPath: directory)
        let found = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        )) ?? []
        return found.filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
    }
}
