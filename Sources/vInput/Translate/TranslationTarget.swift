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

    /// 是否是拉丁字母书写系统。闸门只对这类语言有效，
    /// 将来加日韩时这个标志会变成分流依据。
    var usesLatinScript: Bool { requiresTranslation }

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

    /// prompt 里用的语言名。**用英文名而非中文名**：模型对
    /// "Spanish" 的理解比对「西班牙语」稳定，这与 M5 的
    /// `punctuationPrompt` 用具体术语点名是同一个道理。
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
