import Foundation
import Testing

@testable import vInput

@Suite("翻译提示词")
struct TranslationPromptTests {
    @Test("提示词里出现目标语言的英文名")
    func namesTargetInEnglish() {
        let prompt = TranslationPrompt.user(for: "你好", target: .spanish)
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
        let prompt = TranslationPrompt.user(for: "测试", target: .english)
        #expect(prompt.contains("Output only the translation"))
    }

    /// 技术术语要原样保留——这是用户的主场景，也是度量里单列一格的东西。
    @Test("提示词要求保留技术术语与数字")
    func asksToPreserveTermsAndNumbers() {
        let prompt = TranslationPrompt.user(for: "测试", target: .english)
        #expect(prompt.lowercased().contains("technical"))
        #expect(prompt.lowercased().contains("number"))
    }

    /// 提示词里唯一随语言变化的东西只能是语言名。
    ///
    /// **`en != de` 这一条不是凑数的。** 只留下面那个
    /// `replacingOccurrences` 的比对，一个**压根不提语言**的实现（比如
    /// 把 `\(target.englishName)` 写丢了）会让两串完全相同、替换也是空
    /// 操作，于是断言恒真——正是本仓库栽过好几次的那类「看着在检查，
    /// 其实什么都没检查」。加上不等号后，这条用例自己就能同时钉死
    /// 「有语言名」和「只有语言名在变」。
    @Test("不同语言的提示词只差语言名")
    func differsOnlyByLanguage() {
        let en = TranslationPrompt.user(for: "同一句", target: .english)
        let de = TranslationPrompt.user(for: "同一句", target: .german)
        #expect(en != de)
        #expect(en.replacingOccurrences(of: "English", with: "German") == de)
    }
}

/// 没有加载成本的实现（云端、测试替身）不写 `isReady` 也该天然就绪。
///
/// 这个替身同时是 `Translator` 协议本身唯一的编译期用户——本轮还没有任何
/// 真实现，少了它，协议改坏了（比如默认实现被删、签名对不上）在整个套件里
/// 一声不响。
private struct StubTranslator: Translator {
    func prepare() async throws {}

    func translate(_ text: String, to target: TranslationTarget) async throws -> String {
        "\(target.englishName): \(text)"
    }
}

@Suite("翻译器协议")
struct TranslatorProtocolTests {
    @Test("不覆盖 isReady 的实现默认就绪")
    func defaultsToReady() async {
        #expect(await StubTranslator().isReady)
    }
}
