import Foundation
import Testing

@testable import vInput

/// 基准集对照运行器。默认跳过，由标记文件启用：
///
/// ```bash
/// ./scripts/bench-run.sh                                     # 用应用的默认模型
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

        // **不接受「不指定模型」。** modelFolder 为 nil 时
        // WhisperKitTranscriber 会落到 modelName 的默认值 "base"，WhisperKit
        // 联网下载一个产品从不使用的模型跑完全集（应用默认是 turbo，见
        // ModelPreference），而报告头此前只写「模型：默认」——照 M5 计划执行
        // 不带参数的 ./scripts/bench-run.sh 的人拿到的就是这份报告
        // （2026-08-17 独立验收 F1）。脚本已改为总是解析出具体模型，这里再堵
        // 一道：手写标记文件也不能绕过。
        let modelFolder = try #require(
            config.modelFolder,
            "标记文件里 modelFolder 是 null——用 ./scripts/bench-run.sh 启动，它会解析出应用的默认模型"
        )

        // 直接用生产的 WhisperKitTranscriber，不复刻任何解码参数。
        // Sources/vInputBench/Bench.swift 的 shim 曾与生产差了两个参数
        // （skipSpecialTokens、promptTokens）而注释写着「保持相同」——
        // 用一条与生产不同的管线去选模型会得到错的结论。
        let transcriber = WhisperKitTranscriber(modelFolder: modelFolder)
        try await transcriber.prepare()

        // 翻译段是可选的：标记文件里没有 translateTo 就是 nil，下面每一处
        // 与它有关的输出都不产生，报告与从前逐字一致
        // （`./scripts/bench-run.sh` 不带第二个参数时就是这条路径）。
        //
        // 语言码不合法要在这里就抛，**不能等跑完转写再说**：那要白等一分钟，
        // 而且更要紧的是绝不能悄悄退回某个默认语言。
        let translation = try BenchTranslationSection.make(config: config)
        var translationRows: [BenchTranslationSection.Row] = []
        if let translation {
            // 加载单独计时，不进任何一条的耗时——同扫描装置。
            try await translation.prepare()
        }

        var lines: [String] = []
        var missing: [String] = []
        var totalCER = 0.0
        var counted = 0
        // 中文语境里写成半角的标点总数。报告头单列一行，见下面 M6 ⑤ 的注释。
        var totalHalfWidth = 0
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

            // 全半角单独一格：CER 排除标点、标点数只数个数，两者合起来正好
            // 把「中文语境写成半角」这件事完全屏蔽掉（M6 ⑤）。写成
            // 「实际/参考」的形式，因为参考文本上它恒为 0，一眼能看出差距。
            let halfWidth = BenchMetrics.halfWidthPunctuationInChinese(output)
            totalHalfWidth += halfWidth
            let referenceHalfWidth = BenchMetrics.halfWidthPunctuationInChinese(entry.text)

            let mark = cer == 0 ? "✅" : "❌"
            lines.append("""
                \(mark) \(entry.id)  CER=\(String(format: "%.3f", cer))  \
                标点=\(BenchMetrics.punctuationCount(output))  \
                半角=\(halfWidth)/\(referenceHalfWidth)\(hitNote)
                   参考：\(entry.text)
                   实际：\(output)
                """)

            // 翻译喂的是**转写输出**（生产链路就是这么走的），不是标准文本。
            if let translation {
                let row = await translation.measure(
                    id: entry.id, category: entry.category, source: output)
                translationRows.append(row)
                lines.append(contentsOf: BenchTranslationSection.entryLines(row))
            }
        }

        // 转写耗时不含翻译：这个数是拿来选 Whisper 模型的，混进几十秒翻译
        // 之后它就再也不能和历次报告比了。翻译耗时在尾部的汇总段里单列。
        let elapsed = Date().timeIntervalSince(startedAt)
            - translationRows.map(\.elapsed).reduce(0, +)

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
        // 模型名必须是具体的目录名。写「默认」是不可追溯的——那正是 F1 能
        // 藏住「跑的其实是 base」的原因。
        report += "模型：\(BenchRunGate.modelShortName(modelFolder))\n"
        report += "代码：\(BenchRunGate.codeVersion())\n"
        // 不含模型加载，只算转写：选模型时关心的是每次听写要等多久，
        // 而模型在应用里是常驻的，加载只发生一次。
        report += "转写耗时：\(String(format: "%.1f", elapsed)) 秒\n"
        report += "样本：\(counted) / \(manifest.entries.count)\n"
        // 拆成两句是为了在中间插一行：没有翻译段时两句拼起来与从前逐字一致。
        if let translation { report += translation.headerLine() }
        report += "\n"
        report += "总体 CER：\(String(format: "%.4f", totalCER / Double(counted)))\n"
        // 单列一行而不是只写在逐条里：这一格的用途是「跨两份报告看它有没有
        // 变大」，埋在二十几条里翻不出来。标准文本上它恒为 0，所以这个数
        // 就是差距本身。
        report += "中文语境半角标点：\(totalHalfWidth)（标准文本为 0）\n\n"
        for category in BenchCategory.allCases {
            guard let stat = categoryStats[category], stat.count > 0 else { continue }
            report += "\(category.rawValue)：CER=\(String(format: "%.4f", stat.cer / Double(stat.count)))"
            report += "（\(stat.count) 条）\n"
        }
        report += "\n" + lines.joined(separator: "\n") + "\n"
        // 汇总在尾部：逐条看得见「这条译成什么样」，汇总回答「整体如何」。
        if let translation {
            report += translation.summaryLines(rows: translationRows).joined(separator: "\n") + "\n"
        }

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
        /// 目标语言码。**有它才跑翻译段**，没有就完全不跑，报告与从前逐字一致。
        ///
        /// 认不出来的语言码要让整轮失败，**不许悄悄退回中文或英文**：
        /// 报告头会写着一种语言、跑的是另一种，而那种报告会被拿去做决策
        /// （同 `TranslationSweepConfig` 对未知提示词变体的处理）。
        let translateTo: String?
        /// 翻译用的本地 MLX 模型目录。`translateTo` 存在时必须有。
        let translationModelFolder: String?
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
        // 带翻译的那种跑法在文件名上要看得出来——同一个 Whisper 模型跑一次
        // 纯转写、跑一次带翻译，两份报告的内容差一大截，文件名一样的话
        // 「该拿哪两份 diff」就得靠打开看。不带 `translateTo` 时后缀为空，
        // 文件名与从前逐字一致。
        let language = config.translateTo.map { "-\($0)" } ?? ""
        return archiveDirectory.appendingPathComponent(
            "\(timestampForFilename(startedAt))-\(model)\(language).txt"
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

/// 基准集报告里的**翻译段**。只有 `Bench/.run-config.json` 里带 `translateTo`
/// 时才存在；没有它，整份报告与从前逐字一致。
///
/// # 度量点在闸门之前
///
/// 这里直接调 `Translator.translate`，**不经 `TranslationPipeline`、也不经
/// `TranslationGate`**。闸门跑在注入路径上，会把不合格的译文换成中文原文；
/// 在闸门之后测等于在问「闸门放行的东西符不符合闸门的判据」——恒真。
///
/// M6 栽的正是这个：`BenchMetrics.halfWidthPunctuationInChinese` 与转换器
/// 共用同一个函数、又跑在转换之后，26 条全读 0，那不是测量结果是定义。
/// `TranslationSweepTests` 出于同一条理由也直接调翻译器。
/// 这条接法由 `BenchTranslationSectionTests.measuresBeforeTheGate` 扫源码钉住。
///
/// # 「原文」是转写输出，不是标准文本
///
/// 喂进翻译器的就是转写出来的那串字（生产链路是 转写 → 校正 → 翻译），
/// 所以术语、数字、长度比全部拿它当分母。拿标准文本当分母的话，ASR 自己
/// 弄丢的术语会被记到翻译头上——两层的错混在一格里就没法归因了。
final class BenchTranslationSection {
    /// `Equatable` 是为了让测试能钉**具体是哪一种失败**。
    /// 只断言「抛了个 Failure」是不够的：几种失败凑在一条路径上，
    /// 「未知语言码被悄悄退回英文」照样会因为别的原因抛，用例就绿了
    /// ——2026-08-19 变异验证当场撞到过（P6 那一格最初漏网）。
    enum Failure: Error, Equatable, CustomStringConvertible {
        case unknownLanguage(String)
        case chineseIsNotTranslation
        case missingModelFolder
        case modelFolderNotFound(String)

        var description: String {
            switch self {
            case .unknownLanguage(let code):
                """
                标记文件里的 translateTo 是「\(code)」，不认识。
                可用的：\(TranslationTarget.allCases.map(\.rawValue).joined(separator: " "))
                **宁可整轮不跑也不退回默认语言**：报告头写着一种语言、跑的是另一种，
                而这份报告会被拿去做决策。
                """
            case .chineseIsNotTranslation:
                "translateTo 是 zh，而中文＝不翻译。要跑翻译段就给一种外语。"
            case .missingModelFolder:
                "带了 translateTo 却没有 translationModelFolder——用 ./scripts/bench-run.sh <whisper 模型> <语言码> 启动。"
            case .modelFolderNotFound(let path):
                "翻译模型目录不存在：\(path)"
            }
        }
    }

    let target: TranslationTarget
    let modelFolder: String
    /// 真正加载在 `prepare()` 里做，构造只记路径：本类型的构造要能在普通
    /// 单元测试里跑（`BenchTranslationSectionTests`），而 MLX 在 SwiftPM
    /// 命令行下连初始化都会崩（没有 default.metallib，见 docs/dev-dependencies.md）。
    private var translator: (any Translator)?

    private init(target: TranslationTarget, modelFolder: String) {
        self.target = target
        self.modelFolder = modelFolder
    }

    /// 没有 `translateTo` 就返回 nil（不跑翻译段）；有但不合法就抛。
    static func make(config: BenchRunGate.Config) throws -> BenchTranslationSection? {
        guard let code = config.translateTo else { return nil }
        guard let target = TranslationTarget(rawValue: code) else {
            throw Failure.unknownLanguage(code)
        }
        guard target.requiresTranslation else { throw Failure.chineseIsNotTranslation }
        guard let folder = config.translationModelFolder else { throw Failure.missingModelFolder }
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw Failure.modelFolderNotFound(folder) }
        return BenchTranslationSection(target: target, modelFolder: folder)
    }

    /// 加载翻译模型。耗时几十秒，**不算进任何一条的耗时里**。
    func prepare() async throws {
        let built = MLXTranslator(modelDirectory: URL(fileURLWithPath: modelFolder))
        // 闸门、超时、maxTokens 全用生产默认值：在这里硬写一个数等于绕过
        // 那几条各自有实测支撑的守卫，而且不会有人发现。
        try await built.prepare()
        translator = built
    }

    /// 译一条并量出一行。**返回的是未经闸门的原始译文。**
    func measure(id: String, category: BenchCategory, source: String) async -> Row {
        let started = Date()
        var output = ""
        var failure: String?
        do {
            guard let translator else { throw TranslatorError.modelNotReady }
            output = try await translator.translate(source, to: target)
        } catch {
            // 一条失败不该让整轮白跑——报告才是产物，失败原样记进表里。
            failure = "\(error)"
        }
        return Row(
            id: id, category: category, source: source, translation: output,
            elapsed: Date().timeIntervalSince(started), error: failure)
    }

    /// 一条样本的翻译结果与它的全部度量。
    ///
    /// 每一格都走 `TranslationMetrics`，**不在这里另写一份判据**——
    /// 扫描装置（`TranslationSweepTests`）与本段用的必须是同一把尺子，
    /// 否则两份报告里同名的一列说的不是同一件事。
    struct Row {
        let id: String
        let category: BenchCategory
        /// 喂进翻译器的那串字＝转写输出。分母全部取自它。
        let source: String
        /// **未经 `TranslationGate` 过滤的原始译文。**
        let translation: String
        let elapsed: TimeInterval
        let error: String?

        var sourceHan: Int { TranslationMetrics.residualHanCount(source) }
        var outputHan: Int { TranslationMetrics.residualHanCount(translation) }
        var residualPunctuation: Int {
            TranslationMetrics.residualChinesePunctuationCount(translation)
        }
        var terms: [String] { BenchMetrics.technicalTerms(in: source) }
        var termHits: Int { terms.filter(translation.contains).count }
        var termRate: Double {
            TranslationMetrics.termPreservationRate(source: source, translation: translation)
        }
        var sourceDigits: [String] { TranslationMetrics.digitsIn(source) }
        var lostDigits: [String] {
            TranslationMetrics.lostDigits(source: source, translation: translation)
        }
        var lengthRatio: Double {
            TranslationMetrics.lengthRatio(source: source, translation: translation)
        }
        var truncated: Bool { TruncationSignal.looksTruncated(translation) }
        /// 「术语保留满分」与「把原文抄了一遍」分不开，靠这一格分开。
        /// 判据在 `TranslationMetrics.looksCopiedFromSource`，与扫描装置共用。
        var looksCopied: Bool {
            TranslationMetrics.looksCopiedFromSource(source: source, translation: translation)
        }
    }

    // MARK: - 报告文本（全部是纯函数，可单测）

    var modelShortName: String { BenchRunGate.modelShortName(modelFolder) }

    /// 报告头里的那一行。
    func headerLine() -> String {
        "翻译：\(target.rawValue) · \(modelShortName)（度量点在闸门之前，下同）\n"
    }

    /// 逐条那两行。
    static func entryLines(_ row: Row) -> [String] {
        guard row.error == nil else {
            return ["   译文：（失败）", "   翻译 ✖失败：\(row.error ?? "")"]
        }
        var flags: [String] = []
        if row.outputHan > 0 { flags.append("❌汉字") }
        if row.looksCopied { flags.append("⚠抄原文") }
        if row.truncated { flags.append("✂截断") }
        if !row.lostDigits.isEmpty { flags.append("🔢丢数字\(row.lostDigits.joined(separator: ","))") }
        let mark = flags.isEmpty ? "✅" : flags.joined(separator: " ")
        return [
            "   译文：\(row.translation)",
            // **每一格都带着自己的分母。** 只印分子的话，「术语 0」既可能是
            // 全丢了、也可能是原文压根没有术语，而这两件事差得很远。
            "   翻译 \(mark)  汉字 \(row.outputHan)/\(row.sourceHan)"
                + "  术语 \(row.termHits)/\(row.terms.count)"
                + "  数字 丢\(row.lostDigits.count)/共\(row.sourceDigits.count)"
                + "  长度比 \(f(row.lengthRatio, 2))  \(f(row.elapsed))秒",
        ]
    }

    /// **「数字丢失」那一行。分母为 0 时不许只印一个 0。**
    ///
    /// 这是第 0 步实地踩过的坑：`Bench/manifest.json` 那 26 条里一个 ASCII
    /// 数字都没有（2026-08-18 数过），于是这一列的分母恒为 0。印一个漂亮的
    /// 「0」会被读成「一个数字都没丢」，而真相是「这批素材根本考不到数字」
    /// ——一个看着很像通过了的数。
    static func digitsSummaryLines(lost: Int, total: Int, target: TranslationTarget) -> [String] {
        guard total > 0 else {
            return [
                "  数字丢失      **原文共 0 个阿拉伯数字：分母为 0，这一列读不出任何东西**",
                "                基准集的标准文本里一个 ASCII 数字都没有。要考数字（报价场景最贵的错）",
                "                换带数字的语料跑扫描：./scripts/translate-sweep.sh <模型> \(target.rawValue) "
                    + "--corpus Bench/translate-digits.json",
            ]
        }
        return ["  数字丢失      \(lost) / 原文共 \(total) 个"]
    }

    /// **「术语保留」那一行。分母同样要印出来。**
    ///
    /// 平均值只对「原文里真有术语」的条目算：把「没有术语可丢」的条目按
    /// 1.0 混进来，口语类会把平均顶到接近 1，读起来像「术语保得很好」。
    static func termsSummaryLine(rates: [Double], withoutTerms: Int) -> String {
        guard !rates.isEmpty else {
            return "  术语保留      **本批 \(withoutTerms) 条原文都没有技术术语：分母为 0，这一列读不出任何东西**"
        }
        let mean = rates.reduce(0, +) / Double(rates.count)
        return "  术语保留      \(f(mean, 2))（分母非空 \(rates.count) 条；"
            + "另 \(withoutTerms) 条原文无技术术语，按 1.0 计，不进这个平均）"
    }

    /// 报告尾部的汇总段。
    func summaryLines(rows: [Row]) -> [String] {
        var out: [String] = [
            "",
            "## 翻译段汇总（\(target.rawValue) · \(modelShortName)）",
            "**度量点在闸门之前**：下面每一格都来自未经 TranslationGate 过滤的原始译文，",
            "分母一律是「喂进翻译器的那串字」，也就是上面每条的「实际：」。",
            "读表先看分母——分母为 0 的那一列读不出任何东西。",
            "样本：\(rows.count) 条，失败 \(rows.filter { $0.error != nil }.count) 条",
        ]

        let ok = rows.filter { $0.error == nil }
        guard !ok.isEmpty else {
            out.append("  \(rows.count) 条全部失败，无可汇总的数据")
            return out
        }

        let han = ok.map(\.outputHan)
        let punct = ok.map(\.residualPunctuation)
        out.append("  残留汉字      共 \(han.reduce(0, +)) 个，涉及 \(han.filter { $0 > 0 }.count) 条（应为 0）")
        out.append("  残留中文标点  共 \(punct.reduce(0, +)) 个，涉及 \(punct.filter { $0 > 0 }.count) 条")

        let withTerms = ok.filter { !$0.terms.isEmpty }
        out.append(
            Self.termsSummaryLine(
                rates: withTerms.map(\.termRate), withoutTerms: ok.count - withTerms.count))
        out.append(
            contentsOf: Self.digitsSummaryLines(
                lost: ok.flatMap(\.lostDigits).count,
                total: ok.flatMap(\.sourceDigits).count,
                target: target))

        let ratios = ok.map(\.lengthRatio)
        out.append(
            "  长度比        均 \(Self.f(ratios.reduce(0, +) / Double(ratios.count), 2))"
                + "  最小 \(Self.f(ratios.min() ?? 0, 2))  最大 \(Self.f(ratios.max() ?? 0, 2))")
        out.append("  疑似截断      \(ok.filter(\.truncated).count) 条")
        // **这一行与上面的「术语保留」是配着读的。** 术语保留的分母是从原文
        // 抽的术语，模型把原文原样吐回来就是满分——「零汉字残留 + 术语满分」
        // 和「大量汉字残留 + 术语满分」是两回事，后者根本不是翻译。
        out.append("  疑似抄原文    \(ok.filter(\.looksCopied).count) 条（译文汉字数 ≥ 原文的一半）")
        out.append("                ↑ 与「术语保留」配着读：把原文原样吐回来，术语保留也是满分。")

        let elapsed = ok.map(\.elapsed).sorted()
        out.append(
            "  单条耗时      均 \(Self.f(elapsed.reduce(0, +) / Double(elapsed.count)))"
                + "  中位 \(Self.f(elapsed[elapsed.count / 2]))"
                + "  最长 \(Self.f(elapsed.last ?? 0)) 秒")
        return out
    }

    static func f(_ value: Double, _ digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value)
    }
}

/// 翻译段的守卫。**不门控，跟着普通 `./scripts/test.sh` 一起跑**——
/// 上面那套对照本体要真模型、要几分钟，普通测试跑不到它，而这几件事必须
/// 每次都被检查。
///
/// # 变异表（2026-08-19 实测，
/// `./scripts/test.sh --filter "BenchTranslationSectionTests|TranslationMetricsTests"`，
/// 数的是**逐条结果行**不是汇总行）
///
/// | 变异 | 结果 |
/// |---|---|
/// | 度量点挪到闸门之后（`measure` 里过一道闸门，被拦就换成中文原文） | 1 条红：`measuresBeforeTheGate` |
/// | 分母为 0 时仍只印一个 `0`，不标注 | 1 条红：`zeroDenominatorIsNeverPrintedAsAPlainZero` |
/// | 术语那一行不再印分母 | 1 条红：`termsLineAlwaysPrintsItsDenominator` |
/// | 逐条那一行的数字格只印分子 | 1 条红：`entryLineCarriesDenominators` |
/// | `looksCopiedFromSource` 永远返回 false | 1 条红：`copyingIsSeparatedFromPerfectTermScore` |
/// | 未知语言码悄悄退回英文 | 1 条红：`unknownLanguageAborts` |
/// | 带了 `translateTo` 也不跑翻译段（整段静默失踪） | 5 条红 |
///
/// **「未知语言码」那一格第一次是漏网的**，写在这里当作记号：最初的写法是
/// `#expect(throws: Failure.self)` 而配置里不给模型目录，于是变异体照样会
/// 因为「没有模型目录」抛出**另一种** `Failure`，用例全绿。改成钉具体那一
/// 格（`Failure` 加了 `Equatable`）并补上一个真实存在的临时目录之后才红。
/// 「抛了个错」和「抛了那个错」差着一个变异。
@Suite("基准集报告的翻译段")
struct BenchTranslationSectionTests {
    private func config(
        translateTo: String? = nil, translationModelFolder: String? = nil
    ) -> BenchRunGate.Config {
        BenchRunGate.Config(
            modelFolder: "/models/whisper",
            translateTo: translateTo,
            translationModelFolder: translationModelFolder)
    }

    // MARK: - 开关：不带 translateTo 就完全不跑

    /// 没有 `translateTo` ＝ 没有翻译段。整份报告与从前逐字一致的前提。
    @Test("不带 translateTo 时没有翻译段")
    func absentLanguageMeansNoSection() throws {
        #expect(try BenchTranslationSection.make(config: config()) == nil)
    }

    /// **旧的标记文件要能照读。** 只有 `modelFolder` 的那种（本次改动之前
    /// 的写法）解出来必须是「不跑翻译段」，不能因为多了两个字段就整轮失败。
    @Test("旧标记文件仍然可解，且不跑翻译段")
    func oldMarkerStillDecodes() throws {
        let data = Data(#"{"modelFolder":"/models/whisper"}"#.utf8)
        let decoded = try JSONDecoder().decode(BenchRunGate.Config.self, from: data)
        #expect(decoded.modelFolder == "/models/whisper")
        #expect(decoded.translateTo == nil)
        #expect(try BenchTranslationSection.make(config: decoded) == nil)
    }

    /// 建一个空目录当「翻译模型目录」，用完删掉。
    ///
    /// 语言那两条**必须**带上一个存在的目录：不带的话它们会因为「没有模型
    /// 目录」而抛，于是「未知语言码被悄悄退回英文」这种变异照样让用例绿——
    /// 2026-08-19 变异验证当场撞到（P6 最初漏网）。
    private func temporaryDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// **认不出来的语言码让整轮失败，不许退回默认语言。**
    ///
    /// 退回默认的后果是报告头写着一种语言、跑的是另一种——而这份报告会被
    /// 拿去做决策（同 `TranslationSweepConfig` 对未知提示词变体的处理）。
    ///
    /// 钉的是**具体哪一种失败**，理由见 `temporaryDirectory`。
    @Test("未知语言码让整轮失败")
    func unknownLanguageAborts() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: BenchTranslationSection.Failure.unknownLanguage("jp")) {
            _ = try BenchTranslationSection.make(
                config: config(translateTo: "jp", translationModelFolder: dir.path))
        }
    }

    /// `zh` ＝不翻译，跑一轮「翻译成中文」只会得到一份全是恒等式的报告。
    @Test("translateTo 是 zh 时拒绝")
    func chineseIsRejected() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: BenchTranslationSection.Failure.chineseIsNotTranslation) {
            _ = try BenchTranslationSection.make(
                config: config(translateTo: "zh", translationModelFolder: dir.path))
        }
    }

    @Test("有语言却没有翻译模型目录时失败")
    func missingModelFolderAborts() {
        #expect(throws: BenchTranslationSection.Failure.missingModelFolder) {
            _ = try BenchTranslationSection.make(config: config(translateTo: "en"))
        }
    }

    @Test("翻译模型目录不存在时失败")
    func missingModelDirectoryAborts() {
        #expect(
            throws: BenchTranslationSection.Failure.modelFolderNotFound("/nonexistent/model")
        ) {
            _ = try BenchTranslationSection.make(
                config: config(translateTo: "en", translationModelFolder: "/nonexistent/model"))
        }
    }

    @Test("配齐时给出翻译段")
    func completeConfigBuildsSection() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let section = try #require(
            try BenchTranslationSection.make(
                config: config(translateTo: "es", translationModelFolder: dir.path)))
        #expect(section.target == .spanish)
        #expect(section.headerLine().contains("es"))
        #expect(section.headerLine().contains("闸门之前"), "报告头没说清度量点在哪")
    }

    // MARK: - 分母：印 0 而不标注就是在骗人

    /// **分母为 0 时不许只印一个漂亮的 0。**
    ///
    /// 基准集那 26 条里一个 ASCII 数字都没有（第 0 步实地数过），这一列的
    /// 分母恒为 0。印「数字丢失 0」会被读成「一个都没丢」，而真相是这批
    /// 素材根本考不到数字——一个看着很像通过了的数，正是本仓库头号缺陷类型。
    @Test("分母为 0 时那一行必须自己说出来，而不是印一个 0")
    func zeroDenominatorIsNeverPrintedAsAPlainZero() {
        let empty = BenchTranslationSection.digitsSummaryLines(lost: 0, total: 0, target: .english)
            .joined(separator: "\n")
        #expect(empty.contains("分母为 0"), "没标出分母为 0：\(empty)")
        #expect(empty.contains("读不出任何东西"), "没说清这一列读不出东西：\(empty)")
        // 光说「读不出」还不够，要给出下一步——考数字有现成的语料和脚本。
        #expect(empty.contains("translate-digits.json"), "没告诉人怎么才能考到数字：\(empty)")
        #expect(empty.contains("translate-sweep.sh"), "没给出跑法：\(empty)")

        let counted = BenchTranslationSection.digitsSummaryLines(
            lost: 2, total: 7, target: .english
        ).joined(separator: "\n")
        #expect(counted.contains("2 / 原文共 7 个"), "分母非空时要写成 分子/分母：\(counted)")
        #expect(!counted.contains("分母为 0"), "分母明明非空却说分母为 0：\(counted)")
    }

    /// 术语那一行同理：分母为 0（这批原文全都没有技术术语）要自己说出来。
    @Test("术语那一行永远带着自己的分母")
    func termsLineAlwaysPrintsItsDenominator() {
        let empty = BenchTranslationSection.termsSummaryLine(rates: [], withoutTerms: 26)
        #expect(empty.contains("分母为 0"), "全无术语时没标出分母为 0：\(empty)")
        #expect(empty.contains("读不出任何东西"), "\(empty)")

        let some = BenchTranslationSection.termsSummaryLine(rates: [1.0, 0.5], withoutTerms: 17)
        #expect(some.contains("分母非空 2 条"), "没印出分母：\(some)")
        #expect(some.contains("17 条"), "没印出「另外多少条不进平均」：\(some)")
        #expect(some.contains("0.75"), "平均值不对或没印出来：\(some)")
    }

    /// 逐条那一行也要带分母：只印分子的话，「术语 0」既可能是全丢了、
    /// 也可能是原文压根没有术语。
    @Test("逐条那一行的每一格都带分母")
    func entryLineCarriesDenominators() {
        let row = BenchTranslationSection.Row(
            id: "tech-01", category: .technical,
            source: "我们用 GitHub Actions 做持续集成。",
            translation: "We use GitHub Actions for continuous integration.",
            elapsed: 1.5, error: nil)
        let text = BenchTranslationSection.entryLines(row).joined(separator: "\n")
        #expect(text.contains("汉字 0/"), "残留汉字没带分母：\(text)")
        #expect(text.contains("术语 1/1"), "术语没带分母或抽错了：\(text)")
        #expect(text.contains("数字 丢0/共0"), "数字没带分母：\(text)")
        #expect(text.contains("长度比"), "\(text)")
    }

    // MARK: - 抄原文 ≠ 翻译

    /// **「术语保留满分」与「把原文抄了一遍」必须分得开。**
    ///
    /// 术语保留的分母是从原文抽的术语，模型把原文原样吐回来就是满分——
    /// M5 那次「术语命中率测的是词在不在 prompt 里」是同一款陷阱。
    /// 这里拿两条同样满分的样本对照：一条是真译文，一条是抄回来的原文。
    @Test("零汉字残留的满分与抄原文的满分，在报告里分得开")
    func copyingIsSeparatedFromPerfectTermScore() {
        let source = "我们用 GitHub Actions 做持续集成。"
        let translated = BenchTranslationSection.Row(
            id: "tech-02", category: .technical, source: source,
            translation: "We use GitHub Actions for continuous integration.",
            elapsed: 1, error: nil)
        let copied = BenchTranslationSection.Row(
            id: "tech-03", category: .technical, source: source,
            translation: source, elapsed: 1, error: nil)

        // 两条的术语保留都是满分——单看这一格分不开。
        #expect(translated.termRate == 1.0)
        #expect(copied.termRate == 1.0)
        // 分开它们的是这两格。
        #expect(translated.looksCopied == false)
        #expect(copied.looksCopied, "把原文原样吐回来却没被标成抄原文")
        #expect(copied.outputHan == copied.sourceHan)

        let text = BenchTranslationSection.entryLines(copied).joined(separator: "\n")
        #expect(text.contains("⚠抄原文"), "逐条那一行没标出抄原文：\(text)")
        #expect(text.contains("❌汉字"), "满篇汉字却没标：\(text)")
    }

    // MARK: - 度量点在闸门之前

    /// **闸门会把这条译文换成中文原文，而度量必须仍然看得见它原来的样子。**
    ///
    /// 这条用真的 `TranslationGate` 判一次（`.reject`），再证明同一条样本
    /// 在报告里的每一格都是**原始译文**的数：残留汉字 5、长度比 0.42。
    /// 在闸门之后测的话，这两个数会变成中文原文的数（残留汉字＝整句、
    /// 长度比＝1.0），而报告会看起来像「一切正常」。
    @Test("闸门拦下的译文，度量照样读的是原始译文")
    func metricsSeeTheRawTranslationNotTheGatedOne() {
        let source = "我们下午三点上线新版本。"
        let bad = "We 下午三点 ship."  // 残留汉字，闸门必拦
        let verdict = TranslationGate().check(source: source, translation: bad, target: .english)
        #expect(verdict != .pass, "这条样本得先真的会被闸门拦下，否则本条什么都没证明")

        let row = BenchTranslationSection.Row(
            id: "x", category: .technical, source: source, translation: bad,
            elapsed: 1, error: nil)
        // 4 ＝「下午三点」，先跑出来再写进断言的。
        #expect(row.outputHan == 4, "读到的不是原始译文里的汉字数")
        #expect(row.translation == bad, "度量拿到的不是原始译文")
        // 闸门放行后注入的是中文原文，那种情况下这两个数会是 12 与 1.0。
        #expect(row.outputHan != row.sourceHan)
    }

    /// **扫源码钉住：翻译段直接调翻译器，不经流水线、不经闸门。**
    ///
    /// 上面那条证明得了「给定原始译文，度量是对的」，证明不了「跑起来喂给
    /// 度量的确实是原始译文」。改走 `TranslationPipeline` 的话，喂进来的就
    /// 成了闸门放行后的结果，而上面那条一条都不会红——那正是 M6 栽的形态：
    /// 在闸门之后测，等于测「闸门放行的东西符不符合闸门的判据」，恒真。
    ///
    /// 读整份文件做 `contains` 而不是逐行 grep：跨行写法行式匹配看不见。
    @Test("翻译段直接调翻译器，不经流水线与闸门")
    func measuresBeforeTheGate() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        // **要找的两个记号是拼出来的，不能直接写。** 写成字面量的话，这行
        // 代码自己就成了一处匹配，而「多出来的那一处是本行还是度量路径上的」
        // 从计数上分不出来——扫描自己把自己扫进去，正是本仓库头号缺陷类型的
        // 一个变种（云端出站面那条扫描是靠「刻意不写出类型名」躲开的）。
        let pipelineToken = "TranslationPipeline" + "("
        let gateToken = "TranslationGate" + "()"
        let pipelines = source.components(separatedBy: pipelineToken).count - 1
        let gates = source.components(separatedBy: gateToken).count - 1
        #expect(
            pipelines == 0,
            """
            翻译段里出现了 TranslationPipeline 的构造。度量点必须在闸门之前：
            闸门会把不合格的译文换成中文原文，在它之后测等于测「闸门放行的
            东西符不符合闸门的判据」——恒真（M6 的教训）。
            """
        )
        #expect(
            gates == 1,
            """
            TranslationGate 的构造点应当正好一处（metricsSeeTheRawTranslationNotTheGatedOne
            那条对照用例），实际 \(gates) 处。多出来的那处很可能是度量路径上的。
            """
        )
        let callsTranslatorDirectly = source.contains("translator.translate(source, to: target)")
        #expect(callsTranslatorDirectly, "翻译段没有直接调 Translator.translate，度量点可能被挪走了")
    }
}
