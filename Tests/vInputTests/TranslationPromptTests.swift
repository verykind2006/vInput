import Foundation
import Testing

@testable import vInput

@Suite("翻译提示词")
struct TranslationPromptTests {
    @Test("提示词里出现目标语言的英文名")
    func namesTargetInEnglish() {
        let prompt = TranslationPrompt.user(for: "你好", from: .chinese, to: .spanish)
        #expect(prompt.contains("Spanish"))
        #expect(prompt.contains("你好"))
    }

    /// 规则必须并进**用户消息**。
    ///
    /// 上游 `ChatSession(instructions:)` 会被静默丢弃——`respond` 与
    /// `streamResponse` 都做 `generator.messages = [.user(...)]`（赋值而非
    /// 追加，`Streamlined.swift:43` 对 `:196/:237`）。M4 期间实测发现，
    /// 校正层因此把规则并进了用户提示（见 CorrectionPrompt.user）。
    @Test("规则并在用户消息里，不依赖 instructions")
    func rulesAreInUserMessage() {
        let prompt = TranslationPrompt.user(for: "测试", from: .chinese, to: .english)
        #expect(prompt.contains("Output only the translation"))
    }

    /// 技术术语与数字要原样保留——这是用户的主场景，也是度量里各单列一格的
    /// 东西（`TranslationMetrics.termPreservationRate` / `.lostDigits`）。
    ///
    /// **钉整句，不钉关键词。** 起初这里查的是 `contains("technical")` 与
    /// `contains("number")`，评审施加变异证明它是半空的：把两条规则的语义
    /// 整个反过来、只留关键词——
    ///
    /// ```
    /// Translate technical terms and product names into the target language.
    /// Convert all numbers into spelled-out words.
    /// ```
    ///
    /// ——提示词命令模型做的事和度量要测的事完全相反，23 个用例一条没红。
    /// 那检查的只是「这两个词在不在 prompt 里」，与 M5 那次「术语命中率测的
    /// 是词在不在 prompt 里」是同一款缺陷。整句里带上 `exactly as they
    /// appear`，语义反转就会被抓到，也顺带覆盖了 `product names` 与
    /// `code identifiers`。
    ///
    /// 断言写的是**拼接后**的字符串：提示词源码里这两句带续行反斜杠，
    /// 照源码字面写会永远匹配不上。
    @Test("提示词要求保留技术术语与数字")
    func asksToPreserveTermsAndNumbers() {
        let prompt = TranslationPrompt.user(for: "测试", from: .chinese, to: .english)
        #expect(
            prompt.contains(
                "Keep technical terms, product names, and code identifiers exactly as they appear."
            ))
        #expect(prompt.contains("Keep all numbers exactly as they appear."))
        // 中文数词的换算规则（万=10⁴、亿=10⁸）**试过、无效、撤了**——
        // 前后对照 33/192 → 40/192，依据见 TranslationPrompt 的类型注释与
        // Bench/reports/numerals/。这里断言它不在，免得哪天被凭直觉加回来
        // 而不看当时的数据。要再试，必须先跑数词语料的前后对照。
        #expect(!prompt.contains("Convert Chinese number words"))
    }

    /// 源语言不再写死中文——提示词第一行要点名真正的源语言。
    @Test("提示词点名源语言")
    func promptNamesTheSourceLanguage() {
        let prompt = TranslationPrompt.user(for: "hello", from: .english, to: .spanish)
        #expect(prompt.contains("Translate the following English text into Spanish."))
        #expect(!prompt.contains("Chinese text"))
    }

    @Test("中文做源语言时措辞与旧版一字不差")
    func chineseSourceKeepsTheOldWording() {
        // 老路径的措辞一字不变——它是 M8 实测过的那一版。
        let prompt = TranslationPrompt.user(for: "你好", from: .chinese, to: .german)
        #expect(prompt.contains("Translate the following Chinese text into German."))
    }

    /// 提示词里唯一随语言变化的东西只能是语言名。
    ///
    /// 轴心挑 en/de 而不是别的对：`replacingOccurrences` 这一手隐含要求
    /// **`"English"` 不作为固定文案出现在提示词里**（出现了就会被连带替换成
    /// `"German"`，比对以很难看懂的方式炸掉）。今天成立——除语言名外的
    /// 固定文案里没有任何语言名（源语言名如今来自 `from:` 参数，本条把它
    /// 钉死在 `.chinese`，保障不缩水）。将来谁往规则里写一句含 English 的
    /// 固定文案（比如 "Answer in English if unsure"），要么换轴心，要么改成
    /// 只比对去掉语言名之后的残余。
    ///
    /// **`en != de` 这一条不是凑数的。** 只留下面那个
    /// `replacingOccurrences` 的比对，一个**压根不提语言**的实现（比如
    /// 把 `\(target.englishName)` 写丢了）会让两串完全相同、替换也是空
    /// 操作，于是断言恒真——正是本仓库栽过好几次的那类「看着在检查，
    /// 其实什么都没检查」。加上不等号后，这条用例自己就能同时钉死
    /// 「有语言名」和「只有语言名在变」。
    @Test("不同语言的提示词只差语言名")
    func differsOnlyByLanguage() {
        let en = TranslationPrompt.user(for: "同一句", from: .chinese, to: .english)
        let de = TranslationPrompt.user(for: "同一句", from: .chinese, to: .german)
        #expect(en != de)
        #expect(en.replacingOccurrences(of: "English", with: "German") == de)
    }

    /// 与上一条对称：固定目标、遍历源语言，两两之间也只能差源语言名。
    ///
    /// 防的是将来有人给某个源语言单独改正文措辞（比如给英文源加一句
    /// 特殊规则），正文一漂移，Task 3 那套对照就分不清差异来自语言名还是
    /// 来自正文。锚定 `.chinese` 再逐一比对，传递性上等价于两两比对。
    ///
    /// 目标固定挑 `.spanish` 与源语言名不撞车的场合最多；`Spanish` 自己做
    /// 源时（源=目标的废话形态）替换会把两个位置一起换掉，恰好也等于真实
    /// 输出，不用单独排除。`prompt != baseline` 同款不是凑数的：忽略
    /// `source` 参数的实现会让替换空转、比对恒真。
    @Test("不同源语言的提示词只差源语言名")
    func sourcesDifferOnlyBySourceLanguageName() {
        let baseline = TranslationPrompt.user(for: "同一句", from: .chinese, to: .spanish)
        for source in Language.allCases where source != .chinese {
            let prompt = TranslationPrompt.user(for: "同一句", from: source, to: .spanish)
            #expect(prompt != baseline)
            #expect(
                baseline.replacingOccurrences(of: "Chinese", with: source.englishName) == prompt,
                "源语言 \(source.englishName) 的提示词与锚点的差异不止源语言名")
        }
    }

    /// 缺省变体就是生产用的那个，换句话说：加变体这件事没有顺手改掉生产提示词。
    @Test("不传变体时用英文语言名")
    func defaultVariantIsEnglishName() {
        #expect(
            TranslationPrompt.user(for: "同一句", from: .chinese, to: .spanish)
                == TranslationPrompt.user(
                    for: "同一句", from: .chinese, to: .spanish, variant: .englishLanguageName))
    }

    /// 两个变体**只差语言名**——对照实验的全部效力都押在这一条上。
    ///
    /// 正文一旦跟着漂移，测出来的差异就分不清来自「语言名换成中文」还是
    /// 来自「顺手把某条规则也改了」，那份对照表就是废的。
    ///
    /// **`en != zh` 不是凑数的**（同上面 `differsOnlyByLanguage` 的理由）：
    /// 只留 `replacingOccurrences` 的比对，一个把 `variant` 参数整个忽略掉的
    /// 实现会让两串完全相同、替换是空操作，断言恒真。
    ///
    /// 轴心挑 `.spanish`：`Spanish` 不作为固定文案出现在提示词里，而
    /// `.english` 会——目标语言名与固定文案撞车的风险不必去试。
    ///
    /// 源语言带上之后，变体换的是**两个**语言名——源与目标都出自
    /// `variant.languageName(for:)`，所以这里要替换两处（Chinese→中文、
    /// Spanish→西班牙文）才该相等。
    @Test("提示词变体只换语言名")
    func variantsDifferOnlyByLanguageName() {
        let en = TranslationPrompt.user(for: "同一句", from: .chinese, to: .spanish)
        let zh = TranslationPrompt.user(
            for: "同一句", from: .chinese, to: .spanish, variant: .chineseLanguageName)
        #expect(en != zh)
        #expect(
            en.replacingOccurrences(of: "Chinese", with: "中文")
                .replacingOccurrences(of: "Spanish", with: "西班牙文") == zh)
    }

    /// 中文变体里不能残留英文语言名，否则「换成中文」只换了一半。
    @Test("中文变体不再出现英文语言名")
    func chineseVariantDropsEnglishName() {
        let zh = TranslationPrompt.user(
            for: "同一句", from: .chinese, to: .german, variant: .chineseLanguageName)
        #expect(zh.contains("德文"))
        #expect(!zh.contains("German"))
        // 源语言名如今也走变体：中文变体下 Chinese 换成了「中文」。
        #expect(zh.contains("中文 text"))
        #expect(!zh.contains("Chinese"))
    }
}

/// 没有加载成本的实现（云端、测试替身）不写 `isReady` 也该天然就绪。
///
/// 这个替身同时是 `Translator` 协议本身唯一的编译期用户——本轮还没有任何
/// 真实现，少了它，协议改坏了（比如默认实现被删、签名对不上）在整个套件里
/// 一声不响。
private struct StubTranslator: Translator {
    /// 让替身走一次抛出路径。**这是 `TranslatorError` 在本仓库唯一的用户**，
    /// 理由见 `notReadyThrows`。
    var shouldFail = false

    func prepare() async throws {}

    func translate(_ text: String, from source: Language, to target: Language) async throws -> String {
        if shouldFail { throw TranslatorError.modelNotReady }
        return "\(target.englishName): \(text)"
    }
}

@Suite("翻译器协议")
struct TranslatorProtocolTests {
    @Test("不覆盖 isReady 的实现默认就绪")
    func defaultsToReady() async {
        #expect(await StubTranslator().isReady)
    }

    /// 「未就绪时立即抛 `.modelNotReady`，而不是就地加载模型」这条协议契约，
    /// 在加上本用例之前只是注释里的一句祈使句：`TranslatorError` 全仓库零
    /// 用户，只有声明那一行。对照 `CorrectorError`——`MLXCorrector` 与
    /// `CorrectionPipeline` 里有 5 处真实抛出点，测试里 8 处引用。
    ///
    /// 加上本用例之后，变异实测（不是推理）：
    /// - `.modelNotReady` 改名 → 编译错误；
    /// - `engineFailed(String)` 改成 `engineFailed(Error)` → 编译错误
    ///   （`#expect(throws:)` 的取值形态要求 `Error & Equatable`，
    ///   带非 Equatable 载荷的 case 会让合成的 `==` 失败）；
    /// - 替身不再抛 → 本用例红。
    ///
    /// **`.missingAPIKey` 删掉仍然没人抓得到——实测确认，本轮不补。**
    /// 它今天没有抛出点，删掉在语义上确实无害；真正的守卫是 Task 9 的
    /// `GeminiTranslator`（缺 key 的那条路径）。`.timedOut` 与
    /// `.engineFailed` 同理留给 Task 8 的 `MLXTranslator`。在这里为它们造
    /// 替身只会写出「我刚才让它抛的就是它抛的」，钉不住任何真实行为——
    /// 那正是本仓库反复栽的那类空断言。
    @Test("未就绪的实现抛 modelNotReady")
    func notReadyThrows() async {
        let stub = StubTranslator(shouldFail: true)
        await #expect(throws: TranslatorError.modelNotReady) {
            try await stub.translate("你好", from: .chinese, to: .english)
        }
    }
}
