import Foundation

/// 听写输出的目标语言。
///
/// **本轮只收拉丁字母语种。** 日语、韩语不是技术做不到，是没有判断质量的
/// 手段：闸门「译文里不该有汉字」对日语完全失效（日文本来就用汉字），
/// 而这两种语言用户与实现方都读不了——模型输出一段看起来像日语的东西，
/// 无从判断它是不是把「报价三百」翻成了「报价三千」。而这个工具会把文字
/// **直接注进用户即将发出的窗口**。拉丁字母语种则相反：混语、漏译、
/// 残留汉字肉眼可见。
enum TranslationTarget: String, CaseIterable, Sendable, Equatable {
    /// 不翻译，保持转写原样。
    case chinese = "zh"
    case english = "en"
    case spanish = "es"
    case german = "de"
    case portuguese = "pt"
    case french = "fr"
    case italian = "it"

    /// 选中它是否意味着要走翻译流水线。
    var requiresTranslation: Bool { self != .chinese }

    /// 是否是拉丁字母书写系统。
    ///
    /// **显式列举而不是 `requiresTranslation` 的别名。** 写成别名的话这个
    /// 属性是同义反复，「所有可翻译语种都是拉丁字母」这条断言定义上必然
    /// 成立、检查不到任何东西——而将来加日语时，只要有人顺手把测试里的
    /// `count == 6` 改成 7，日语就会被静默标成拉丁字母语种。
    ///
    /// 这个标志将来是闸门的分流依据（闸门「译文里不该有汉字」只对拉丁
    /// 字母语种有效），标错的后果是把一整套判据用在它失效的语言上。
    var usesLatinScript: Bool {
        switch self {
        case .chinese: return false
        case .english, .spanish, .german, .portuguese, .french, .italian: return true
        }
    }

    /// 菜单栏显示用。
    var displayName: String {
        switch self {
        case .chinese: return "中文"
        case .english: return "英文"
        case .spanish: return "西班牙文"
        case .german: return "德文"
        case .portuguese: return "葡萄牙文"
        case .french: return "法文"
        case .italian: return "意大利文"
        }
    }

    /// prompt 里用的语言名。**用英文名而非中文名是本轮的假设，尚未测量。**
    ///
    /// 假设的依据是「模型对指令语言的理解在英文上更稳」，但这条在本项目里
    /// 没有任何实测支撑——而 Task 1–4 那个第 0 步正是为「不许断言未测量的
    /// 事」设的。**Task 3 的对照装置应当顺带验一次**：同一套素材、
    /// 只把语言名换成中文，看指标差多少。
    ///
    /// 不要拿 M5 的 `punctuationPrompt` 类比：那是把词写进 prompt 让 ASR
    /// 更可能吐出它（输出 token 先验），而且那个机制恰恰被本仓库记录为
    /// 指标陷阱——技术类 79% 的「改善」来自把答案写进了 prompt。
    /// 这里是指令可理解性，两回事。
    var englishName: String {
        switch self {
        case .chinese: return "Chinese"
        case .english: return "English"
        case .spanish: return "Spanish"
        case .german: return "German"
        case .portuguese: return "Portuguese"
        case .french: return "French"
        case .italian: return "Italian"
        }
    }
}
