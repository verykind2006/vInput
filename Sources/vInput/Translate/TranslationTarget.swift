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

/// 这一档语言在 M8 第 0 步实测里的质量。**菜单要靠它说清六种并不一样稳。**
///
/// 用户 2026-08-19 的决定是「六种全上，但要标出差异」，理由是让用户自己
/// 判断什么场合用哪种。做成带值的枚举而不是一句写死的说明文字，是为了让
/// 「加一种语言却没给它定级」被机械地抓到：
///
/// - `TranslationTarget.quality` 是**穷尽 switch**，加一格编译不过；
/// - 而「随手标成 measured 编个数」由 `TranslationTargetTests` 那条
///   「实测过的正好是这三种、数值逐个钉死」拦下——第 0 步只测了
///   英/西/德三种，第四个 `measured` 一定是编的。
enum TranslationQuality: Equatable, Sendable {
    /// 中文＝不翻译，无所谓质量。
    case notApplicable
    /// 实测过。`termRetention` 是**技术术语与代码标识符原样保留的比例**，
    /// 1.0 表示一个都没被译走。
    case measured(termRetention: Double)
    /// 没有实测数据。**不许编一个数糊上去。**
    case unmeasured
}

extension TranslationTarget {
    /// 实测质量。数字来自 M8 第 0 步，`Bench/reports/m8-step0/`（已 gitignore，
    /// 报告在开发机上）：英文术语保留 1.00 且零残留汉字，西语 0.92、德语 0.89
    /// ——即每十个技术术语约有一个被译走或译错。
    ///
    /// **葡/法/意没有测过，所以是 `unmeasured`，不是「大概和西语差不多」。**
    /// 本仓库栽过的那一类错误里有一半是「断言了没量过的事」。
    var quality: TranslationQuality {
        switch self {
        case .chinese: .notApplicable
        case .english: .measured(termRetention: 1.00)
        case .spanish: .measured(termRetention: 0.92)
        case .german: .measured(termRetention: 0.89)
        // 三种一起列：它们的取值来源相同（都没测），分开写只是重复。
        // 加一种新语言时这里同样编译不过，人被迫回来定级。
        case .portuguese, .french, .italian: .unmeasured
        }
    }

    /// 菜单项上的那一行字。
    ///
    /// **提示做在每一个菜单项上，而不是一次性弹窗**：弹窗切走再切回来就
    /// 看不到了，而用户挑语言的那一刻正是他需要这个差异的时刻。
    ///
    /// 计算放在这里而不是拼在 SwiftUI 视图里，是本仓库既有的分工
    /// （见 `HUDViewModel`：「全部计算做成纯函数，视图只负责画」）——
    /// 拼在视图里就没有任何测试守得住它。
    var menuLabel: String {
        switch quality {
        case .notApplicable:
            // 「中文」单看是个语言名，看不出选它等于关掉翻译。
            "\(displayName)（不翻译）"
        case .measured(let retention):
            // 两位小数：实测值本身就是两位（1.00 / 0.92 / 0.89），
            // 多印几位是在假装精度。
            "\(displayName) · 术语保留 \(String(format: "%.2f", retention))"
        case .unmeasured:
            "\(displayName) · 未实测"
        }
    }
}
