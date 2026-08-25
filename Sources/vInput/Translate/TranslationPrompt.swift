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
/// 语言的理解在英文上更稳」这个假设（同 `Language.englishName` 的
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

        func languageName(for target: Language) -> String {
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
    /// **「中文数词按 万=10⁴、亿=10⁸ 换算」这条规则试过，无效，撤了**
    /// （2026-08-20，qwen3-4b × 六语 × 20 条数词语料前后对照）：
    /// 加规则前真错 33/192，加规则后 40/192——系统性错误（两万三→230,000、
    /// 四百六十万→46 million、96万8 六语全错）一个没少，英文侧反而更多
    /// 拼词输出。4B 不是不知道万是多少，是换算不稳，定义帮不上；而这条
    /// 规则每次请求还多啃约 30 个 token 的预算。修法改走确定性改写：
    /// 翻译前把解析得出的中文数词直接改写成阿拉伯数字
    /// （`ChineseNumerals.rewriteAsDigits`，见 `TranslationPipeline`），
    /// 模型照抄数字这件事实测可靠（digits 语料 12/12）。
    ///
    /// 刻意不放示例。校正层实测过：编的例子会被模型当成答案背下来，原样
    /// 输出到一句压根不含那个词的话上（见 `CorrectionPrompt` 的注记）。
    /// 翻译要不要给示例、给几条，同样该由 Task 3 的对照装置来定，
    /// 而不是在这里拍脑袋。
    ///
    /// **调用方保证 `source != target`。** 这里不拦相等：传进来会生成
    /// "Translate the following English text into English."，是句废话但不是
    /// 崩溃。要在这一层拦就得决定「拦了返回什么」，而唯一合理的答案
    /// （原样返回、根本别调模型）是流水线的分支（Task 6 落地），
    /// 不是提示词的。
    static func user(
        for text: String,
        from source: Language,
        to target: Language,
        variant: Variant = .englishLanguageName
    ) -> String {
        """
        Translate the following \(variant.languageName(for: source)) text into \(variant.languageName(for: target)).

        Output only the translation. Do not add explanations, pinyin, \
        or the original text.
        Keep technical terms, product names, and code identifiers exactly as \
        they appear.
        Keep all numbers exactly as they appear.

        \(text)
        """
    }
}
