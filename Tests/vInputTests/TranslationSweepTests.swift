import Foundation
import Testing

@testable import vInput

/// 扫描配置。**用标记文件而不是环境变量**——理由见
/// `TranslationSweepGateTests` 的注释。
///
/// 只服务于扫描装置，不进生产目标。
struct TranslationSweepConfig {
    let modelDirectory: URL
    let targets: [TranslationTarget]
    /// 每种语言只跑基准集的前几条。nil＝全跑。
    ///
    /// 26 条 × 6 种语言 = 156 次推理，一轮几十分钟。没有限流手段就没法先花
    /// 两分钟确认「装置真的加载得动模型、真的写得出报告」，只能一把梭；
    /// Task 4 要分批跑，也靠它。
    let limit: Int?
    let promptVariant: TranslationPrompt.Variant
    let maxTokens: Int
    /// 换一份语料跑。nil＝用 `Bench/manifest.json` 那 26 条。
    ///
    /// 存在的理由是 `Bench/translate-digits.json`：那 26 条里一个 ASCII
    /// 数字都没有，`lostDigits` 的分母恒为 0（见 `BenchCategory.digits`）。
    /// 用「换语料」而不是「往 manifest 里加条目」，是因为 manifest 的每一条
    /// 都假设有对应录音。
    let corpus: URL?

    private struct Raw: Decodable {
        let modelDirectory: String
        let targets: [String]
        let limit: Int?
        let promptVariant: String?
        let maxTokens: Int?
        let corpus: String?
    }

    static func load(from url: URL) -> TranslationSweepConfig? {
        guard let data = try? Data(contentsOf: url),
            let raw = try? JSONDecoder().decode(Raw.self, from: data)
        else { return nil }

        // 未知语言码跳过而不是让整份配置作废：脚本传错一个字母不该让其余
        // 五种语言白跑。一个都不认识则作废——「零种语言」跑出来的报告只有
        // 表头，和「跑完了但全都没问题」长得太像。
        let targets = raw.targets.compactMap(TranslationTarget.init(rawValue:))
        guard !targets.isEmpty else { return nil }

        // **变体的处理与语言相反：认不出来就整份作废。** 退回默认值会写出
        // 一份标着「中文语言名」、实际跑的是英文语言名的报告，对照结论整个
        // 反过来而没有任何迹象。
        let variant: TranslationPrompt.Variant
        if let name = raw.promptVariant {
            guard let parsed = TranslationPrompt.Variant(rawValue: name) else { return nil }
            variant = parsed
        } else {
            variant = .englishLanguageName
        }

        return TranslationSweepConfig(
            modelDirectory: URL(fileURLWithPath: raw.modelDirectory),
            targets: targets,
            limit: raw.limit,
            promptVariant: variant,
            maxTokens: raw.maxTokens ?? MLXTranslator.defaultMaxTokens,
            corpus: raw.corpus.map { URL(fileURLWithPath: $0) }
        )
    }

    /// 本轮要跑的语料。
    ///
    /// **换语料失败要抛，不能悄悄退回 manifest。** 退回去会跑出一份标着
    /// 「数字语料」、实际跑的是没有数字的那 26 条的报告，而那份报告里
    /// 「数字丢失」那一列会写「分母为 0」——看起来和「数字语料里一个数字
    /// 都没考到」一模一样。与未知提示词变体同一条理由。
    func loadCorpus() throws -> BenchManifest {
        guard let corpus else { return try BenchManifest.loadFromRepository() }
        let data = try Data(contentsOf: corpus)
        return try JSONDecoder().decode(BenchManifest.self, from: data)
    }

    /// 仓库根：本文件在 `Tests/vInputTests/` 下，退三级
    /// （与 `TranslationProbeGate.repositoryRoot` 同一条路径，
    /// 层数由 `markerURLResolvesToRepositoryRoot` 实地验证）。
    static var markerURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // vInputTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
            .appendingPathComponent("Bench/.translate-sweep.json")
    }

    static var current: TranslationSweepConfig? { load(from: markerURL) }

    /// 本轮要跑的条目：`limit` 截前几条。
    func entries(from manifest: BenchManifest) -> [BenchEntry] {
        guard let limit, limit < manifest.entries.count else { return manifest.entries }
        return Array(manifest.entries.prefix(max(0, limit)))
    }
}

/// 「这条译文疑似被截断」的判据。
///
/// **存在的理由：撞 `maxTokens` 上限是静默的。** 表现是「返回半截译文、
/// 成功返回、不报错」，与取消半途而废（见 `MLXTranslator.translate` 里记的
/// 实测：8/8 都成功返回半截译文）**表现一模一样**，事后从结果里分不开。
/// 没有这条判据，一份「26 条全绿」的报告里可能有若干条只译了一半，
/// 而每条的指标——残留汉字 0、术语保留 1.0——全都好看。
///
/// 判据：去掉尾部空白与收尾的引号括号后，最后一个字符不是句末标点。
/// 基准集 26 条标准文本全部以「。」结尾，译文正常收尾就该落在句末标点上。
///
/// **它不是空判据**，两处证据：
/// 1. `TruncationSignalTests` 里拿真实观测到的半截译文验过（不是编的句子）；
/// 2. 把 `maxTokens` 调小到必然撞上限跑一轮，判据应当大面积亮起——
///    这是 `scripts/translate-sweep.sh --max-tokens` 存在的理由。
///
/// **它只是信号不是判决**：正常译文以引号或省略号收尾也可能被标出来，
/// 报告里因此同时打印译文原文，由人过一眼。宁可多报——漏报的那条会被当成
/// 好样本写进 Task 4 的结论。
enum TruncationSignal {
    private static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    /// 可以合法地挂在句末标点右边的收尾字符。
    private static let closers: Set<Character> = [
        "\"", "”", "'", "’", ")", "）", "»", "」", "]", "》",
    ]

    static func looksTruncated(_ text: String) -> Bool {
        var chars = Array(text)
        while let last = chars.last, last.isWhitespace || closers.contains(last) {
            chars.removeLast()
        }
        // 空输出（或只剩引号括号）也算没说完——它同样是「成功返回但没东西」。
        guard let last = chars.last else { return true }
        return !terminators.contains(last)
    }
}

@Suite("疑似截断的判据")
struct TruncationSignalTests {
    @Test("完整句子不报")
    func completeSentence() {
        #expect(!TruncationSignal.looksTruncated("The unit price is twelve dollars."))
        #expect(!TruncationSignal.looksTruncated("¿Cuál es el precio?"))
        #expect(!TruncationSignal.looksTruncated("Zahl bitte!"))
    }

    @Test("句末标点后挂引号括号不报")
    func trailingClosersAreFine() {
        #expect(!TruncationSignal.looksTruncated("He said \"go home.\""))
        #expect(!TruncationSignal.looksTruncated("（见上文。）"))
        #expect(!TruncationSignal.looksTruncated("Fine.  \n"))
    }

    /// **这三条是真实观测，不是编的句子。**
    ///
    /// 2026-08-18 实测：`qwen2.5-7b-instruct-4bit`，
    /// `./scripts/translate-sweep.sh qwen2.5-7b-instruct-4bit en --limit 3 --max-tokens 5`，
    /// 三条技术类样本撞上限后的原始输出照抄如下。同一批样本在 `maxTokens=512`
    /// 下的输出分别是 102 / 114 / 89 字的完整句子，全部以句点收尾、本判据一条
    /// 不报——**「5 全报、512 全不报」这个对照就是这条判据不空的证据**，
    /// 而不是我挑了三个必然通过的字符串。
    ///
    /// 顺带量到了这个模型英文输出的 token 密度：22/26/25 字 ÷ 5 token
    /// ≈ 4.4–5.2 字每 token。Task 4 拿它把「译文字数」换算成 token 数，
    /// 判断 512 到底留了多少余量。
    @Test("撞上限的半截译文会被报出来")
    func realTruncatedOutput() {
        #expect(TruncationSignal.looksTruncated("There is an issue with"))
        #expect(TruncationSignal.looksTruncated("We write code using Claude"))
        #expect(TruncationSignal.looksTruncated("Change the return type of"))
    }

    /// 对照的另一半：同一批样本不撞上限时的完整输出，一条都不该报。
    ///
    /// 少了这一半，上面那条用「全都报」也能满分——一个恒返回 true 的实现
    /// 会让它全绿，而那正是本仓库栽过七次的那类空判据。
    @Test("同一批样本不撞上限时一条都不报")
    func realCompleteOutput() {
        #expect(
            !TruncationSignal.looksTruncated(
                "There is an issue with the code of this component, we need to add a "
                    + "dependency array in the useEffect."))
        #expect(
            !TruncationSignal.looksTruncated(
                "We write code using Claude Code, then use GitHub Actions for continuous "
                    + "integration, and finally deploy it to AWS."))
        #expect(
            !TruncationSignal.looksTruncated(
                "Change the return type of this function to Promise, then add error "
                    + "handling in the catch."))
    }

    @Test("空输出算没说完")
    func emptyIsSuspect() {
        #expect(TruncationSignal.looksTruncated(""))
        #expect(TruncationSignal.looksTruncated("   \n "))
        #expect(TruncationSignal.looksTruncated("\"\""))
    }
}

/// 门控用**标记文件**而不是环境变量。
///
/// `xcodebuild test` 不把父进程环境变量传给测试运行器——实测会让整个套件
/// 被静默跳过而仍报 TEST SUCCEEDED、退出码 0。M5 期间踩过，
/// `CorrectionE2ETests` 的 `E2EGate`（`Testing/.e2e-enabled`）与
/// `BenchRunnerTests` 的 `BenchRunGate`（`Bench/.run-config.json`）
/// 都因此用标记文件，本套照做。
@Suite("翻译扫描的门控")
struct TranslationSweepGateTests {
    /// 建个临时目录，写一份标记文件，返回它的 URL。
    private func marker(_ json: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("没有标记文件时不启用")
    func disabledWithoutMarker() {
        #expect(TranslationSweepConfig.load(from: URL(fileURLWithPath: "/nonexistent")) == nil)
    }

    @Test("标记文件解析出模型目录与语言清单")
    func parsesMarker() throws {
        let url = try marker(#"{"modelDirectory":"/tmp/qwen","targets":["en","es"]}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let config = try #require(TranslationSweepConfig.load(from: url))
        #expect(config.modelDirectory.path == "/tmp/qwen")
        #expect(config.targets == [.english, .spanish])
    }

    /// 未知语言码要被忽略而不是让整份配置作废——脚本传错一个字母不该让
    /// 其余五种语言白跑。
    @Test("未知语言码被跳过")
    func skipsUnknownTargets() throws {
        let url = try marker(#"{"modelDirectory":"/tmp/qwen","targets":["en","xx"]}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let config = try #require(TranslationSweepConfig.load(from: url))
        #expect(config.targets == [.english])
    }

    /// 一个语言码都认不出来时整份配置作废：跑一轮「零种语言」会写出一份
    /// 只有表头的报告，而那份报告看起来和「跑完了但全都没问题」很像。
    @Test("语言全不认识时整份配置作废")
    func rejectsAllUnknownTargets() throws {
        let url = try marker(#"{"modelDirectory":"/tmp/qwen","targets":["xx","yy"]}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(TranslationSweepConfig.load(from: url) == nil)
    }

    /// `limit` 限每种语言跑前几条。26 条 × 6 种 = 156 次推理，一轮几十分钟，
    /// 没有限流手段就没法先花两分钟确认装置真的跑得起来。
    @Test("limit 缺省为 nil，给了就解析")
    func parsesLimit() throws {
        let without = try marker(#"{"modelDirectory":"/tmp/q","targets":["en"]}"#)
        let with = try marker(#"{"modelDirectory":"/tmp/q","targets":["en"],"limit":3}"#)
        defer {
            try? FileManager.default.removeItem(at: without.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: with.deletingLastPathComponent())
        }

        #expect(try #require(TranslationSweepConfig.load(from: without)).limit == nil)
        #expect(try #require(TranslationSweepConfig.load(from: with)).limit == 3)
    }

    /// 提示词变体缺省是生产用的那一个。
    @Test("提示词变体缺省是英文语言名")
    func defaultsToEnglishNaming() throws {
        let url = try marker(#"{"modelDirectory":"/tmp/q","targets":["en"]}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let config = try #require(TranslationSweepConfig.load(from: url))
        #expect(config.promptVariant == .englishLanguageName)
    }

    @Test("提示词变体可切到中文语言名")
    func parsesPromptVariant() throws {
        let url = try marker(
            #"{"modelDirectory":"/tmp/q","targets":["en"],"promptVariant":"chinese-language-name"}"#
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let config = try #require(TranslationSweepConfig.load(from: url))
        #expect(config.promptVariant == .chineseLanguageName)
    }

    /// **未知变体码与未知语言码的处理刻意相反。**
    ///
    /// 语言认不出来只是少跑一种语言，报告里一目了然；变体认不出来若退回
    /// 默认值，就会写出一份**标着「中文语言名」、实际跑的是英文语言名**的
    /// 报告——对照实验的结论会因此整个反过来，而没有任何迹象。
    /// 宁可整轮不跑。
    @Test("未知提示词变体让整份配置作废")
    func rejectsUnknownPromptVariant() throws {
        let url = try marker(
            #"{"modelDirectory":"/tmp/q","targets":["en"],"promptVariant":"zhongwen"}"#
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(TranslationSweepConfig.load(from: url) == nil)
    }

    /// `maxTokens` 缺省跟着生产值走，不在这里另写一个数——两处各写一个
    /// 就会有一天对不上，而对不上的表现是「扫描测出来的截断率和线上不一样」。
    @Test("maxTokens 缺省跟随生产默认值")
    func defaultsToProductionMaxTokens() throws {
        let without = try marker(#"{"modelDirectory":"/tmp/q","targets":["en"]}"#)
        let with = try marker(#"{"modelDirectory":"/tmp/q","targets":["en"],"maxTokens":32}"#)
        defer {
            try? FileManager.default.removeItem(at: without.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: with.deletingLastPathComponent())
        }

        #expect(
            try #require(TranslationSweepConfig.load(from: without)).maxTokens
                == MLXTranslator.defaultMaxTokens)
        #expect(try #require(TranslationSweepConfig.load(from: with)).maxTokens == 32)
    }

    /// `corpus` 缺省是 nil（用 manifest.json），给了就解析成路径。
    @Test("corpus 缺省为 nil，给了就解析")
    func parsesCorpus() throws {
        let without = try marker(#"{"modelDirectory":"/tmp/q","targets":["en"]}"#)
        let with = try marker(
            #"{"modelDirectory":"/tmp/q","targets":["en"],"corpus":"/tmp/digits.json"}"#)
        defer {
            try? FileManager.default.removeItem(at: without.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: with.deletingLastPathComponent())
        }

        #expect(try #require(TranslationSweepConfig.load(from: without)).corpus == nil)
        #expect(
            try #require(TranslationSweepConfig.load(from: with)).corpus?.path == "/tmp/digits.json")
    }

    /// 语料文件读不到要抛，不能悄悄退回 manifest.json——那会写出一份标着
    /// 「数字语料」、实际跑的是没有数字的那 26 条的报告。
    @Test("语料文件不存在时抛错而不是退回 manifest")
    func missingCorpusThrows() throws {
        let url = try marker(
            #"{"modelDirectory":"/tmp/q","targets":["en"],"corpus":"/nonexistent/x.json"}"#)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let config = try #require(TranslationSweepConfig.load(from: url))
        #expect(throws: (any Error).self) { try config.loadCorpus() }
    }

    /// 仓库自带的数字语料要能解析，而且**真的带 ASCII 数字**。
    ///
    /// 后半句才是重点：这份语料存在的全部意义就是让 `lostDigits` 的分母
    /// 非空，如果哪天有人把它改成没有数字的句子，那一列会静静地退回
    /// 「分母为 0」，而报告照样跑得出来。
    @Test("仓库里的数字语料可解析且分母非空")
    func repositoryDigitsCorpusHasDigits() throws {
        let url = TranslationSweepConfig.markerURL
            .deletingLastPathComponent()
            .appendingPathComponent("translate-digits.json")
        let manifest = try JSONDecoder().decode(
            BenchManifest.self, from: try Data(contentsOf: url))
        #expect(manifest.entries.count >= 8, "数字语料只有 \(manifest.entries.count) 条")
        for entry in manifest.entries {
            #expect(
                !TranslationMetrics.digitsIn(entry.text).isEmpty,
                "\(entry.id) 里没有 ASCII 数字，它在这份语料里读不出任何东西")
            #expect(entry.category == .digits)
        }
    }

    /// `markerURL` 从 `#filePath` 回溯三级到仓库根。
    ///
    /// **不只比对字符串**——比对路径尾巴的话，回溯层数少一级、多一级都
    /// 照样通过（尾巴是拼上去的，与前缀无关），而层数错了的后果是
    /// `current` 永远读不到标记文件、扫描永远跳过。这里改为验证回溯到的
    /// 那个目录里确实有仓库的东西。
    @Test("标记文件路径落在仓库根下")
    func markerURLResolvesToRepositoryRoot() {
        let root = TranslationSweepConfig.markerURL.deletingLastPathComponent()
            .deletingLastPathComponent()
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Bench/manifest.json").path),
            "回溯到的目录不像仓库根：\(root.path)"
        )
        #expect(TranslationSweepConfig.markerURL.lastPathComponent == ".translate-sweep.json")
    }
}

/// 拿真实模型跑多种语言的横评，输出可判读的表。**这是第 0 步的主体**：
/// 用哪个模型、超时给多少、闸门的长度比阈值定在哪、本地方案到底可不可行，
/// 全靠这份报告里的数决定。
///
/// **默认跳过**——门控是 `Bench/.translate-sweep.json`，由
/// `./scripts/translate-sweep.sh` 写入并在退出时删掉。
///
/// **必须用 `xcodebuild` 跑，不能用 `./scripts/test.sh`。** SwiftPM 命令行
/// 无法编译 mlx-swift 的 Metal 着色器，产物里没有 `default.metallib`，
/// MLX 一初始化就崩（同 `CorrectionE2ETests`，见 `docs/dev-dependencies.md`）。
///
/// `.serialized`：并发跑 MLX 会让 Metal 崩掉
/// （`commit an already committed command buffer`），M4 期间实测过。
/// 本套目前只有一条用例，加 `.serialized` 是为了将来加第二条时不必回想这件事。
@Suite(
    "翻译扫描",
    .enabled(if: TranslationSweepConfig.current != nil),
    .serialized
)
struct TranslationSweepTests {
    /// 一条样本跑一种语言的结果。
    private struct Row {
        let entry: BenchEntry
        let output: String
        let elapsed: TimeInterval
        let error: String?

        /// 原文里的汉字数。用的是 `residualHanCount`——它叫「残留」只是因为
        /// 主用途在译文那边，函数本身就是个汉字计数器，拿来数原文没有问题。
        var sourceHan: Int { TranslationMetrics.residualHanCount(entry.text) }
        var outputHan: Int { TranslationMetrics.residualHanCount(output) }
        var terms: [String] { BenchMetrics.technicalTerms(in: entry.text) }
        var sourceDigits: [String] { TranslationMetrics.digitsIn(entry.text) }

        var termRate: Double {
            TranslationMetrics.termPreservationRate(source: entry.text, translation: output)
        }
        var lostDigits: [String] {
            TranslationMetrics.lostDigits(source: entry.text, translation: output)
        }
        var lengthRatio: Double {
            TranslationMetrics.lengthRatio(source: entry.text, translation: output)
        }
        var truncated: Bool { TruncationSignal.looksTruncated(output) }

        /// **「术语保留 100%」与「把原文整段抄了一遍」分不开，这一格就是用来
        /// 分开它们的。**
        ///
        /// `termPreservationRate` 的分母是从**原文**抽出来的术语，模型只要把
        /// 原文原样吐回来，这个指标就是满分——M5 那次「术语命中率测的是词在
        /// 不在 prompt 里」是同一款陷阱的另一个形态。判据取「译文里的汉字数
        /// 达到原文汉字数的一半」：零星残留一两个字是漏译，过半就只能是抄。
        var looksCopied: Bool { sourceHan > 0 && outputHan * 2 >= sourceHan }
    }

    @Test("跑全部语言并输出报告")
    func sweep() async throws {
        let config = try #require(TranslationSweepConfig.current)
        let manifest = try config.loadCorpus()
        let entries = config.entries(from: manifest)
        #expect(!entries.isEmpty, "本轮一条样本都没有，报告里不会有任何东西")

        let translator = MLXTranslator(
            modelDirectory: config.modelDirectory,
            promptVariant: config.promptVariant,
            maxTokens: config.maxTokens
        )
        // 加载耗时单独记：它不该算进单条推理的耗时里，而超时预算只看后者
        // （Task 9.5 在校正层踩过——把加载算进超时，模型永远等不到就绪）。
        let loadStarted = Date()
        try await translator.prepare()
        let loadElapsed = Date().timeIntervalSince(loadStarted)

        let startedAt = Date()
        var lines: [String] = [
            "# 翻译对照报告",
            "时间：\(BenchRunGate.timestampForDisplay(startedAt))",
            "模型：\(config.modelDirectory.lastPathComponent)",
            "代码：\(BenchRunGate.codeVersion())",
            "提示词变体：\(config.promptVariant.rawValue)"
                + "（本轮 prompt 里的语言名长这样：\(config.promptVariant.languageName(for: .spanish))）",
            "maxTokens：\(config.maxTokens)"
                + (config.maxTokens == MLXTranslator.defaultMaxTokens ? "（生产默认值）" : "（**已改**）"),
            "语言：\(config.targets.map(\.rawValue).joined(separator: " "))",
            "语料：\(config.corpus?.lastPathComponent ?? "manifest.json")",
            "样本：\(entries.count) 条标准文本"
                + (config.limit == nil ? "（全量）" : "（limit=\(config.limit!)，共 \(manifest.entries.count) 条）"),
            "模型加载：\(Self.f(loadElapsed)) 秒",
            "",
            "读表说明——**每一格都可能是空的，先看分母**：",
            "  汉字 a/b   译文里的汉字数 / 原文里的汉字数。b 是分母，a 接近 b 就是把原文抄了一遍。",
            "  术语 a/b   原样保留的技术词 / 原文里的技术词。**b=0 时这条按 1.0 计**，",
            "             汇总里的平均值因此只对「分母非空」的条目才有意义。",
            "  数字       只统计原文里已是阿拉伯数字的那些。分母为 0 就说明这批素材",
            "             压根考不到数字，那一列的 0 读不出任何东西。",
            "  截断       译文不以句末标点收尾，见 `TruncationSignal` 的注释。",
            "             它是信号不是判决，报告里同时打印译文，由人过一眼。",
            "",
        ]

        /// 报告随跑随写：一轮全量是 26 × 6 = 156 次推理、几十分钟，
        /// 中途 Metal 崩一次就前功尽弃。每种语言跑完落一次盘。
        let out = TranslationSweepConfig.markerURL
            .deletingLastPathComponent()
            .appendingPathComponent("translate-sweep.txt")
        func flush() {
            try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        }
        flush()

        var totalRuns = 0
        var totalFailures = 0

        for target in config.targets {
            lines.append(String(repeating: "=", count: 72))
            lines.append("【\(target.displayName)】\(target.rawValue)")
            lines.append("")

            var rows: [Row] = []
            for entry in entries {
                let started = Date()
                var output = ""
                var failure: String?
                do {
                    output = try await translator.translate(entry.text, to: target)
                } catch {
                    // 一条失败不该让整轮白跑——报告才是产物。失败原样记进表里，
                    // 汇总里单列一格。
                    failure = "\(error)"
                }
                let row = Row(
                    entry: entry, output: output,
                    elapsed: Date().timeIntervalSince(started), error: failure)
                rows.append(row)
                totalRuns += 1
                if failure != nil { totalFailures += 1 }

                var flags: [String] = []
                if row.error != nil { flags.append("✖失败") }
                if row.outputHan > 0 { flags.append("❌汉字") }
                if row.looksCopied { flags.append("⚠抄原文") }
                if row.truncated && row.error == nil { flags.append("✂截断") }
                if !row.lostDigits.isEmpty { flags.append("🔢丢数字\(row.lostDigits.joined(separator: ","))") }
                let mark = flags.isEmpty ? "✅" : flags.joined(separator: " ")

                lines.append(
                    "\(mark) \(row.entry.id)（\(row.entry.category.rawValue)）"
                        + "  \(Self.f(row.elapsed))秒"
                        + "  汉字 \(row.outputHan)/\(row.sourceHan)"
                        + "  术语 \(row.terms.filter(row.output.contains).count)/\(row.terms.count)"
                        + "  长度比 \(Self.f(row.lengthRatio, 2))"
                        + "  译文 \(row.output.count) 字")
                lines.append("   原文：\(row.entry.text)")
                if let failure = row.error {
                    lines.append("   失败：\(failure)")
                } else {
                    lines.append("   译文：\(row.output)")
                }
            }

            lines.append("")
            lines.append(contentsOf: Self.summarize(target: target, rows: rows))
            lines.append("")
            flush()
        }

        lines.append(String(repeating: "=", count: 72))
        lines.append("总计 \(totalRuns) 次推理，失败 \(totalFailures) 次，"
            + "全程 \(Self.f(Date().timeIntervalSince(startedAt))) 秒")
        flush()

        print(lines.joined(separator: "\n"))
        print("报告：\(out.path)")

        // **唯一的断言。** 本套是测量装置不是回归门，指标好坏由人判；
        // 但「一次都没跑通」必须响——那种情况下报告里全是失败行，
        // 而一份跳过的套件和一份全失败的套件在 xcodebuild 的输出里长得一样。
        #expect(
            totalFailures < totalRuns,
            "全部 \(totalRuns) 次推理都失败了，报告里没有任何可读的数据")
    }

    // MARK: - 汇总

    private static func summarize(target: TranslationTarget, rows: [Row]) -> [String] {
        let ok = rows.filter { $0.error == nil }
        guard !ok.isEmpty else {
            return ["【\(target.displayName)】\(rows.count) 条全部失败，无可汇总的数据"]
        }

        let han = ok.map(\.outputHan)
        let punct = ok.map { TranslationMetrics.residualChinesePunctuationCount($0.output) }
        // **术语的平均值只对分母非空的条目算。** 把「原文没有术语」的条目
        // 按 1.0 混进来，口语类会把平均值顶到接近 1，读起来像「术语保得很好」。
        let withTerms = ok.filter { !$0.terms.isEmpty }
        let sourceDigits = ok.flatMap(\.sourceDigits).count
        let lost = ok.flatMap(\.lostDigits).count
        let ratios = ok.map(\.lengthRatio)
        let elapsed = ok.map(\.elapsed).sorted()

        var out: [String] = ["【\(target.displayName)】\(rows.count) 条，失败 \(rows.count - ok.count) 条"]
        out.append("  残留汉字      共 \(han.reduce(0, +)) 个，涉及 \(han.filter { $0 > 0 }.count) 条")
        out.append("  残留中文标点  共 \(punct.reduce(0, +)) 个，涉及 \(punct.filter { $0 > 0 }.count) 条")
        if withTerms.isEmpty {
            out.append("  术语保留      本批无术语可考，这一列读不出任何东西")
        } else {
            let rate = withTerms.map(\.termRate).reduce(0, +) / Double(withTerms.count)
            out.append(
                "  术语保留      \(f(rate, 2))（分母非空 \(withTerms.count) 条；"
                    + "另 \(ok.count - withTerms.count) 条原文无术语，按 1.0 计，不进这个平均）")
        }
        if sourceDigits == 0 {
            out.append("  数字丢失      原文共 0 个阿拉伯数字——**分母为 0，这一列读不出任何东西**")
        } else {
            out.append("  数字丢失      \(lost) / 原文共 \(sourceDigits) 个")
        }
        out.append(
            "  长度比        均 \(f(ratios.reduce(0, +) / Double(ratios.count), 2))"
                + "  最小 \(f(ratios.min() ?? 0, 2))  最大 \(f(ratios.max() ?? 0, 2))")
        out.append("  疑似截断      \(ok.filter(\.truncated).count) 条")
        out.append("  疑似抄原文    \(ok.filter(\.looksCopied).count) 条（译文汉字数 ≥ 原文的一半）")
        out.append(
            "  单条耗时      均 \(f(elapsed.reduce(0, +) / Double(elapsed.count)))"
                + "  中位 \(f(elapsed[elapsed.count / 2]))"
                + "  **最长 \(f(elapsed.last ?? 0))** 秒　← 超时预算看最长这个数")
        out.append(
            "  译文长度      最长 \(ok.map(\.output.count).max() ?? 0) 字"
                + "（撞没撞 maxTokens 看「疑似截断」那一行）")
        return out
    }

    private static func f(_ value: Double, _ digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value)
    }
}
