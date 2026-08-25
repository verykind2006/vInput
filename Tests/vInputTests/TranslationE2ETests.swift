import Foundation
import Testing

@testable import vInput

/// 翻译端到端体检。需要真实模型，默认跳过。
///
/// **必须用 `xcodebuild` 跑，不能用 `swift build` / `swift test`。**
/// SwiftPM 命令行无法编译 mlx-swift 的 Metal 着色器（见其 README 与
/// `docs/dev-dependencies.md`），MLX 会在运行时报
/// `Failed to load the default metallib` 而整个测试进程中止。
///
/// ```bash
/// ./scripts/translate-e2e.sh                          # 默认 4B
/// ./scripts/translate-e2e.sh qwen2.5-7b-instruct-4bit # 换模型做对照
/// ```
///
/// **门控用标记文件而非环境变量**，理由与 `E2EGate` 一字不差：
/// `xcodebuild test` 不把父进程的环境变量传给测试运行器，实测结果是整个
/// 套件被静默跳过、而 xcodebuild 照样报 `TEST SUCCEEDED`、退出码 0。
///
/// # 存在的理由：单元测试全都在测假翻译器
///
/// `TranslationPipelineTests` / `DictationTranslationTests` 用的是
/// `FakeTranslator`——它们验的是接线（超时、闸门、失败退回中文原文），
/// 验不了模型本身是不是真的能译对：会不会把数字译丢、会不会把 `Terraform`
/// 「翻译」成中文、译文里会不会残留汉字。这几件事只能拿真模型测。
///
/// # 一个默认跳过的门控套件是本仓库头号缺陷类型的终极形态
///
/// 它连断言都不用写就能永远绿。所以：**这套用例在 2026-08-19 真跑过**，
/// 每条的期望值都写明了实测出处，逐条译文见下面各自的注释。
///
/// **必须串行。** Swift Testing 默认并行跑用例，而多条用例同时向同一个
/// MLX 模型发起推理会让 Metal 崩掉（M4 实测：
/// `-[_MTLCommandBuffer commit]: failed assertion 'commit an already
/// committed command buffer'`）。`ModelContainer.perform` 只保证模型访问
/// 串行，保证不了 Metal 命令缓冲区层面的并发安全。
@Suite("翻译端到端", .enabled(if: TranslationE2EGate.isEnabled), .serialized)
struct TranslationE2ETests {
    /// 用 `static let` 而不是每条用例各自 new 一个：全部用例共享同一个
    /// translator 实例，`MLXTranslator` 内部靠 `OneShotLoader` 判重，
    /// 只有第一次 `prepare()` 真的触发加载，其余立即返回——不然每条用例
    /// 都要重复加载同一份 2 GB 模型。
    ///
    /// 标记文件指向的目录不存在时置 nil，交给 `makePipeline()` 里的
    /// `#require` 给出清晰提示，而不是在这里让整个 suite 崩掉。
    private static let translator: MLXTranslator? = {
        guard let directory = TranslationE2EGate.modelDirectory else { return nil }
        return MLXTranslator(modelDirectory: directory)
    }()

    /// 先等模型真正就绪，再返回可用的管线。
    ///
    /// `TranslationPipeline.translate` 在模型未就绪时会立即退回中文原文并
    /// 标注 `.modelLoading`——不先 `await prepare()` 的话，第一条用例必然
    /// 只测出「原样返回」，测不出模型的任何行为。
    ///
    /// **闸门与超时都用默认值。** 计划正文写的是
    /// `TranslationGate(minimumLengthRatio: 0.3)` 与 `timeout: .seconds(120)`；
    /// 那两个数各自有实测支撑（闸门 1.1、超时 8 秒）也各自有测试守着，
    /// 在这里硬写等于绕过守卫，而且不会有人发现。
    ///
    /// **8 秒够不够是量出来的，不是猜的**：2026-08-19 本机跑了两轮
    /// （4B，共 32 次推理），单次 **1.0–2.6 秒**，两轮各自的最慢值是
    /// 2.0 与 2.6 秒。8 秒对最慢的那次留 3 倍余量，**不必为 e2e 放宽**
    /// ——计划正文写的 120 秒是照着「第一次推理有额外开销」拍的，实测没有
    /// 这回事：额外开销全在模型加载上，而加载已经在上一行的 `prepare()` 里
    /// 做完（实测 3.2 秒，有页缓存），不受这个预算约束。
    private func makePipeline(to target: Language) async throws -> TranslationPipeline {
        let translator = try #require(
            Self.translator,
            "模型不在标记文件指定的位置，见 TranslationE2EGate.modelDirectory"
        )
        try await translator.prepare()
        return TranslationPipeline(translator: translator, source: .chinese, target: target)
    }

    /// 把一条实测结果打到标准输出。
    ///
    /// **通过的用例也打**：断言查的全是机械判据（残留汉字数、数字有没有丢、
    /// 术语在不在），语义对不对机器判不了，只能由人扫一眼译文。只在失败时
    /// 打印的话，绿灯那几条到底译成了什么没人知道——而这套体检的价值有一半
    /// 就在那几行字上。同 `scripts/translate-sweep.sh` 的报告。
    private func report(_ label: String, source: String, result: TranslationResult, seconds: Double) {
        print("[翻译 e2e] \(label) \(String(format: "%.1f", seconds))秒")
        print("    原文：\(source)")
        print("    译文：\(result.text)")
        print("    标注：\(result.annotation.map(String.init(describing:)) ?? "无")")
    }

    private func translate(
        _ source: String, to target: Language, label: String
    ) async throws -> TranslationResult {
        let pipeline = try await makePipeline(to: target)
        let started = ContinuousClock.now
        let result = await pipeline.translate(source)
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        report(label, source: source, result: result, seconds: seconds)
        return result
    }

    // MARK: - 中译英

    /// 素材取自基准集 `homo-02`，不是现编的。
    ///
    /// 断言只有两条，都是机械判据：**没有标注**（说明推理成功、闸门放行，
    /// 而不是退回了中文原文）、**残留汉字为 0**（拉丁字母译文里出现汉字，
    /// 只可能是没译完或者退回了中文）。
    ///
    /// 「没有标注」这一条比看上去硬：翻译层一切失败路径都收敛为
    /// 「返回中文原文 + 标注」，所以 `annotation == nil` 等价于
    /// 「这一条真的走完了推理并过了闸门」。
    @Test("中译英出干净的英文")
    func translatesChineseIntoCleanEnglish() async throws {
        let source = "新功能的上线计划已经定了，下周三开始灰度。"
        let result = try await translate(source, to: .english, label: "中译英")

        #expect(result.annotation == nil, "实际输出：\(result.text)")
        #expect(
            TranslationMetrics.residualHanCount(result.text) == 0,
            "译文里还有汉字。实际输出：\(result.text)"
        )
        #expect(result.text != source, "译文与原文相同，说明翻译实际未生效")
    }

    // MARK: - 数字

    /// 数字用例的素材**全部取自 `Bench/translate-digits.json`**，不是现编的。
    ///
    /// 计划正文给的是「这批货的单价是每件十二美元五角，起订量五百件。」，
    /// 期望 `digits.contains("500")`——原文里是**中文数字**「五百」，模型输出
    /// `500` 还是 `five hundred` 完全没测过，而 `TranslationMetrics.digitsIn`
    /// 只认 ASCII 数字（那条注释里写清了为什么）。中文数字译成 `five hundred`
    /// 是**正确行为**，拿它考数字保留等于考了个假的。
    ///
    /// 第 0 步专门补过这份 12 条的阿拉伯数字语料，正是为这件事。
    static func digitsCorpus() throws -> BenchManifest {
        let url = BenchManifest.repositoryRoot
            .appendingPathComponent("Bench/translate-digits.json")
        return try JSONDecoder().decode(BenchManifest.self, from: try Data(contentsOf: url))
    }

    /// `TranslationMetrics.lostDigits` **判不了**的四条。
    ///
    /// **它们不是模型译错了。** 2026-08-19 本机实测
    /// （`qwen3-4b-instruct-2507-4bit`，12 条全跑），这四条的译文逐条是：
    ///
    /// | id | 原文片段 | 译文片段 | `lostDigits` 报什么 | 为什么它是错的 |
    /// |---|---|---|---|---|
    /// | digit-01 | 报价是 128000 元 | `128,000 CNY` | 丢了 `128000` | 千分位逗号把数字串切成 `128` / `000` |
    /// | digit-10 | 降到 98000 元 | `98,000 yuan` | 丢了 `98000` | 同上 |
    /// | digit-04 | 2026 年 8 月 18 日 | `August 18, 2026` | 丢了 `8` | 月份译成月名，`8` 本来就该消失——留着 `8` 才是错的 |
    /// | digit-09 | 第二次在 10 月 | `in October` | 丢了 `10` | 同上 |
    ///
    /// ### 为什么是「排除」而不是别的三种做法
    ///
    /// - **不放宽 `lostDigits`。** 它只认 ASCII 数字串原样出现，这份严格正是
    ///   它的价值：放宽到「忽略逗号」之后，`128000 → 12,800` 这类真错也会
    ///   被放过，而那是报价场景里最贵的错。
    /// - **不用 `withKnownIssue`。** 那是「已知缺陷、等着修」的意思，而这四条
    ///   模型一个数字都没译错，没有东西可修——挂上去只会让人以为这里有个坑。
    /// - **不改素材。** 这四条是语料里最像真实报价的四条（金额、日期），
    ///   删掉它们等于把最该考的场景考没了。它们仍然每轮都跑、每轮都打印译文，
    ///   只是不参与那条机器判据。
    ///
    /// 计划正文那条编的用例（「起订量五百件」期望 `digits.contains("500")`）
    /// 正是同一个陷阱的另一面：中文数字译成 `five hundred` 是正确行为，
    /// 而 `digitsIn` 只认 ASCII，那条断言永远不可能成立。
    static let metricBlindIDs: Set<String> = ["digit-01", "digit-04", "digit-09", "digit-10"]

    /// 本轮参与断言的条目 id。**默认全都参与**，只减去上面那四条——
    /// 语料哪天加了第 13 条，它会自动进入被断言的那一组，而不是被静默漏掉。
    static let digitIDs: [String] =
        (try? digitsCorpus())?.entries.map(\.id).filter { !metricBlindIDs.contains($0) } ?? []

    /// 只跑被排除之外的那些。被排除的四条由
    /// `translatesMetricBlindEntriesAnyway`（同一次运行里）照样译一遍并打印译文，
    /// 好让「排除」这件事随时能被人复核。
    @Test("数字原样保留", arguments: TranslationE2ETests.digitIDs)
    func preservesArabicDigits(_ id: String) async throws {
        let entry = try #require(
            try Self.digitsCorpus().entries.first(where: { $0.id == id }),
            "语料里没有 \(id)"
        )
        let result = try await translate(entry.text, to: .english, label: "数字 \(id)")

        let lost = TranslationMetrics.lostDigits(source: entry.text, translation: result.text)
        #expect(lost.isEmpty, "丢了数字 \(lost)。实际输出：\(result.text)")
    }

    /// 被 `metricBlindIDs` 排除的那四条**照样跑、照样打印译文**。
    ///
    /// 一个被排除的用例如果连跑都不跑，那份排除清单就再也没人复核得了——
    /// 它会慢慢变成一个「往里加就能让红灯变绿」的口袋。这里让它们每轮都出现在
    /// 报告里，人扫一眼就能判断「128,000 CNY」到底是对是错。
    ///
    /// 断言换成这一层还能机器判的两条：**没有标注**（推理真的跑完并过了闸门，
    /// 不是退回中文原文）、**残留汉字为 0**。2026-08-19 实测四条全部满足。
    @Test("被排除的数字条目照样译得出干净英文", arguments: TranslationE2ETests.metricBlindIDs.sorted())
    func translatesMetricBlindEntriesAnyway(_ id: String) async throws {
        let entry = try #require(
            try Self.digitsCorpus().entries.first(where: { $0.id == id }),
            "语料里没有这个 id"
        )
        let result = try await translate(entry.text, to: .english, label: "数字（排除）\(id)")

        #expect(result.annotation == nil, "实际输出：\(result.text)")
        #expect(
            TranslationMetrics.residualHanCount(result.text) == 0,
            "译文里还有汉字。实际输出：\(result.text)"
        )
    }

    // MARK: - 技术术语

    /// 素材是基准集的 `tech-hold-01`。**用户主场景**：这个工具的使用者
    /// 满嘴产品名与代码标识符，把 `Terraform` 「翻译」掉比不翻译更糟。
    ///
    /// 断言写成逐个 `contains` 而不是
    /// `TranslationMetrics.termPreservationRate(...) == 1.0`：后者在
    /// `BenchMetrics.technicalTerms(in:)` 抽不出任何术语时**按 1.0 计**
    /// （那是它给口语样本留的出口），于是词表哪天漏抽了这三个词，
    /// 这条用例会变成恒真——本仓库栽过七次的正是这一类。
    /// 底下那条 `terms` 断言是双保险：术语表真的认得这三个词。
    @Test("技术术语原样保留")
    func preservesTechnicalTerms() async throws {
        let source = "这个服务部署在 Azure 上，用 Terraform 管配置，日志推到 Datadog 里看。"
        let result = try await translate(source, to: .english, label: "术语")

        for term in ["Azure", "Terraform", "Datadog"] {
            #expect(result.text.contains(term), "术语 \(term) 没了。实际输出：\(result.text)")
        }
        #expect(
            BenchMetrics.technicalTerms(in: source).count >= 3,
            "术语表认不出这句话里的三个产品名了，上面那三条 contains 就失去了参照"
        )
    }

    // MARK: - 目标是中文

    /// 输出语言是中文时**连模型都不该碰**，原样返回。
    ///
    /// `TranslationPipelineTests` 已经用 `FakeTranslator` 的调用计数钉住了
    /// 「一次都没调」。这里换一个真模型能给出、假替身给不出的证据：**耗时**。
    /// 同一个进程里刚跑完的那十几条真推理是 1.0–2.6 秒，这一条必须是眨眼之间
    /// ——真去跑了一次推理是藏不住的。
    ///
    /// 阈值取 0.3 秒：比实测最快的一次真推理（1.0 秒）小三倍多，
    /// 又比实测到的本条耗时（**0.001 秒**）大两个数量级，两边都不贴边。
    ///
    /// 素材故意用 digit-01——同一句话在上面那条被排除的用例里刚跑过一次真推理
    /// （1.2 秒），两次耗时摆在同一份报告里，差三个数量级。
    @Test("目标是中文时原样返回")
    func chineseTargetReturnsSourceUntouched() async throws {
        let source = "这个方案的报价是 128000 元，含税，有效期到月底。"
        let pipeline = try await makePipeline(to: .chinese)

        let started = ContinuousClock.now
        let result = await pipeline.translate(source)
        let elapsed = ContinuousClock.now - started

        #expect(result.text == source, "实际输出：\(result.text)")
        #expect(result.annotation == nil)
        #expect(
            elapsed < .milliseconds(300),
            "耗时 \(elapsed)，不像是「压根没调模型」——中文目标绝不该触发推理"
        )
    }
}

/// 排除清单的守卫。**这一套不带门控**，`./scripts/test.sh` 每次都会跑。
///
/// 存在的理由：`metricBlindIDs` 是一个「往里加就能让红灯变绿」的口袋，而它
/// 所在的那套用例默认跳过——口袋被悄悄撑大是不会有人发现的。这里让它的
/// 两条不变量在**不需要模型**的普通测试里就有牙口。
@Suite("翻译端到端的素材清单")
struct TranslationE2ECorpusTests {
    /// 排除清单里的每一个 id 都必须真的在语料里。
    ///
    /// 门控打开时，写错的 id（`digit-1`）会让被排除的那条用例在 `#require`
    /// 上红——但门控**默认是关的**，而这份清单是在门控关着的日常开发里被人
    /// 改动的。没有这条的话，往清单里塞一个不存在的 id 在 899 条里没有任何
    /// 症状，「先塞进去再说」就没人拦得住。
    @Test("排除清单里的 id 都真的在语料里")
    func metricBlindIDsExistInCorpus() throws {
        let ids = Set(try TranslationE2ETests.digitsCorpus().entries.map(\.id))
        for id in TranslationE2ETests.metricBlindIDs {
            #expect(ids.contains(id), "排除清单里的 \(id) 在 translate-digits.json 里不存在")
        }
    }

    /// 被排除的必须是少数。
    ///
    /// 具体的数不重要，重要的是**有一个上界**：没有上界的话，把 12 条全塞进
    /// 排除清单同样一路绿灯，而那时「数字原样保留」这条用例一次都不会跑。
    /// 取一半是因为它离今天的 4/12 有余量，又离「全塞进去」足够远。
    @Test("被排除的条目不到语料的一半")
    func metricBlindIDsStayAMinority() throws {
        let total = try TranslationE2ETests.digitsCorpus().entries.count
        #expect(total > 0)
        let excluded = TranslationE2ETests.metricBlindIDs.count
        #expect(excluded * 2 < total, "排除了 \(excluded)/\(total) 条，「数字原样保留」快没东西可考了")
        #expect(
            !TranslationE2ETests.digitIDs.isEmpty,
            "参与断言的条目一条都不剩了"
        )
    }
}

/// 翻译端到端体检的开关与模型位置。
///
/// 与校正那套（`E2EGate`）**各用各的标记文件**：两套体检各跑一次都要几十秒
/// 到几分钟，合用一个开关就没法只跑其中一套。
///
/// 刻意不走环境变量：`xcodebuild test` 不把父进程环境传给测试运行器，
/// 实测会让整个套件被静默跳过而仍报 `TEST SUCCEEDED`、退出码 0。
enum TranslationE2EGate {
    /// 仓库根目录下的标记文件。在 .gitignore 里排除——它是本机开关，
    /// 不该跟着提交跑到别人机器上。
    static let markerPath = "Testing/.translate-e2e-enabled"

    /// 默认模型目录名。标记文件为空时用它。
    ///
    /// **4B 而不是 7B 是实测定的**（M8 第 0 步）：62 条译文上 4B 残留汉字 0，
    /// 7B 有 57 个残留汉字分布在 8 条上，而 4B 还快一到三倍。
    static let defaultModelName = "qwen3-4b-instruct-2507-4bit"

    /// 仓库根。**直接借 `E2EGate` 的**，不另写一遍 `#filePath` 回溯——
    /// 两处各写一份的话，哪天目录层级变了只改一处，而漏掉的那一处的表现是
    /// 「套件被静默跳过」，正是本文件开头警告的那个假绿灯。
    static var repositoryRoot: URL { E2EGate.repositoryRoot }

    /// 标记文件的内容，去掉首尾空白。文件不存在或为空时返回空串。
    static var markerContents: String {
        let path = repositoryRoot.appendingPathComponent(markerPath).path
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 要测的模型目录，位于仓库内的 `Models/`（**大写 M**）下。
    ///
    /// 模型名写在标记文件里，换模型做对照不必改代码也不必重新编译：
    ///
    /// ```bash
    /// ./scripts/translate-e2e.sh qwen2.5-7b-instruct-4bit
    /// ```
    static var defaultModelDirectory: URL {
        let name = markerContents.isEmpty ? defaultModelName : markerContents
        return repositoryRoot.appendingPathComponent("Models/\(name)", isDirectory: true)
    }

    /// **目录真的存在才算启用。** 只判标记文件在不在的话，模型没下载时
    /// 整套用例会在 `#require` 上逐条报错；而只判目录的话，标记文件删掉之后
    /// 它还会继续跑。两个都要。
    static var isEnabled: Bool {
        FileManager.default.fileExists(
            atPath: repositoryRoot.appendingPathComponent(markerPath).path
        ) && modelDirectory != nil
    }

    /// 模型目录。不存在时返回 nil。
    static var modelDirectory: URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: defaultModelDirectory.path, isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return defaultModelDirectory
    }
}
