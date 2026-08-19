import Foundation

/// 翻译的提示词。
///
/// **全部并进用户消息，不用 `instructions`。** 上游
/// `ChatSession(instructions:)` 会被静默丢弃——`respond` 与 `streamResponse`
/// 都做 `generator.messages = [.user(...)]`（赋值而非追加，
/// `Streamlined.swift:43` 对 `:196/:237`）。M4 期间实测发现：模型收不到规则
/// 就开始聊天，而这个缺陷不以任何错误的形式暴露，只表现为「好像没生效」。
/// 校正层因此把规则并进了用户提示（见 `CorrectionPrompt.user`），这里照做。
///
/// **规则用英文写、语言名也用英文名，这条尚未测量**——依据只是「模型对指令
/// 语言的理解在英文上更稳」这个假设（同 `TranslationTarget.englishName` 的
/// 注记）。Task 3 的对照装置应当顺带验一次：同一套素材换成中文指令，看指标
/// 差多少。
enum TranslationPrompt {
    /// 提示词变体。**只为对照实验存在，生产路径永远用 `.englishLanguageName`。**
    ///
    /// 存在的理由是上面那句「这条尚未测量」：把「英文语言名更稳」留在注释里
    /// 当假设，等于永远测不到。变体写在这里而不是写在扫描装置里，是因为两个
    /// 变体必须**只差语言名**——各写各的提示词正文，一改就漂移，测出来的
    /// 差异就分不清来自语言名还是来自正文（`differsOnlyByLanguage` 守的是
    /// 语言之间，`variantsDifferOnlyByLanguageName` 守的是变体之间）。
    ///
    /// rawValue 是标记文件里写的字符串，改名就是改配置格式。
    enum Variant: String, CaseIterable, Sendable, Equatable {
        /// 生产用：`Spanish`、`German`。
        case englishLanguageName = "english-language-name"
        /// 对照用：`西班牙文`、`德文`。
        case chineseLanguageName = "chinese-language-name"

        func languageName(for target: TranslationTarget) -> String {
            switch self {
            case .englishLanguageName: return target.englishName
            case .chineseLanguageName: return target.displayName
            }
        }
    }

    /// 三条规则，每条都对应闸门或度量里的一格：
    ///
    /// - 只输出译文——多余的解释会被闸门的长度比判成异常，也会被注入。
    /// - 保留技术术语原样——用户主场景，度量里单列一格。
    /// - 保留数字——报价场景最贵的错，度量里单列一格。
    ///
    /// 刻意不放示例。校正层实测过：编的例子会被模型当成答案背下来，原样
    /// 输出到一句压根不含那个词的话上（见 `CorrectionPrompt` 的注记）。
    /// 翻译要不要给示例、给几条，同样该由 Task 3 的对照装置来定，
    /// 而不是在这里拍脑袋。
    ///
    /// **调用方保证 `target.requiresTranslation`。** 这里不拦 `.chinese`：
    /// 传进来会生成 "Translate the following Chinese text into Chinese."，
    /// 是句废话但不是崩溃。要在这一层拦就得决定「拦了返回什么」，而唯一
    /// 合理的答案（原样返回、根本别调模型）是流水线的分支，不是提示词的。
    /// Task 7 的 pipeline 落地时按这条来。
    static func user(
        for text: String,
        target: TranslationTarget,
        variant: Variant = .englishLanguageName
    ) -> String {
        """
        Translate the following Chinese text into \(variant.languageName(for: target)).

        Output only the translation. Do not add explanations, pinyin, \
        or the original text.
        Keep technical terms, product names, and code identifiers exactly as \
        they appear.
        Keep all numbers exactly as they appear.

        \(text)
        """
    }
}
