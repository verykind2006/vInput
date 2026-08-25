import Foundation

/// 语种表，一张表两个角色：既是**输入语言**（用户说的是哪种话，转写、
/// 校正、翻译三层都按它配置），也是**翻译目标**（`TranslationChoice`
/// 选中的那一格）。同一枚举两处用，加语言时两侧一起长。
///
/// **本轮只收拉丁字母语种。** 日语、韩语不是技术做不到，是没有判断质量的
/// 手段：闸门「译文里不该有汉字」对日语完全失效（日文本来就用汉字），
/// 而这两种语言用户与实现方都读不了——模型输出一段看起来像日语的东西，
/// 无从判断它是不是把「报价三百」翻成了「报价三千」。而这个工具会把文字
/// **直接注进用户即将发出的窗口**。拉丁字母语种则相反：混语、漏译、
/// 残留汉字肉眼可见。
enum Language: String, CaseIterable, Sendable, Equatable {
    /// 作为输入语言是默认档；作为翻译目标只是七档之一——「不翻译」
    /// 已是 `TranslationChoice.off` 的职责，不再借「目标=中文」表达。
    case chinese = "zh"
    case english = "en"
    case spanish = "es"
    case german = "de"
    case portuguese = "pt"
    case french = "fr"
    case italian = "it"

    /// 是否是拉丁字母书写系统。
    ///
    /// **显式列举而不是 `self != .chinese` 的简写。** 写成简写的话这个
    /// 属性是同义反复，「所有非中文语种都是拉丁字母」这条断言定义上必然
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

/// 这一档语言实测的翻译质量。**菜单要靠它说清六种并不一样稳。**
///
/// 用户 2026-08-19 的决定是「六种全上，但要标出差异」，理由是让用户自己
/// 判断什么场合用哪种。做成带值的枚举而不是一句写死的说明文字，是为了让
/// 「加一种语言却没给它定级」被机械地抓到：`Language.quality(from:)`
/// 是**穷尽 switch**，加一格编译不过。
///
/// # 数字取的是「忽略大小写」那一版，这一点不是随便选的
///
/// 2026-08-19 六语对照（26 条 × 6 种 = 156 次推理，零失败），
/// 两套判据给出的排序**完全不同**：
///
/// | 语言 | 逐字 | 忽略大小写 |
/// |---|---|---|
/// | 英文 | 1.00 | 1.00 |
/// | **德文** | **0.84（六种最差）** | **1.00（并列最好）** |
/// | 意大利文 | 0.98 | 1.00 |
/// | 法文 | 0.96 | 0.98 |
/// | 葡萄牙文 | 0.94 | 0.96 |
/// | 西班牙文 | 0.92 | 0.94 |
///
/// 德语那 0.16 的差**全部来自德语名词首字母大写**（`token`→`Token`、
/// `store`→`Store`、`selector`→`Selector`），而那是正确的德语。
/// 同一轮里西语葡语是真把 `refresh` 译成了 `actualización`、
/// 把 `store` 译成了 `almacén`——那才是丢失。
///
/// **只看逐字那个数的话，菜单会把德语标成最差，而它其实一个术语都没真丢。**
///
/// 顺带实测到模型的一个好行为：**camelCase 标识符一个字母都没动**
/// （`useMemo` / `useCallback` 原样保留），被大写的只有那些在句子里当普通
/// 名词用的单词。所以「复制译文里的代码标识符」这件事不受影响。
///
/// # 这些数的精度有限，别当成排名
///
/// 26 条里只有 **9 条**原文含技术术语，合计约 50 个术语——**一个术语约值
/// 0.02**。所以 0.94 与 0.98 之间的差不到两个术语，落在噪声里；
/// 真正读得出来的只有「六种都在 0.94 以上」这一句。
enum TranslationQuality: Equatable, Sendable {
    /// 与输入相同＝不翻译，无所谓质量。
    case notApplicable
    /// 实测过。`termRetention` 是**技术术语与代码标识符原样保留的比例**，
    /// 1.0 表示一个都没被译走。
    case measured(termRetention: Double)
    /// 没有实测数据。**不许编一个数糊上去。**
    case unmeasured
}

extension Language {
    /// 从给定输入语种译到本语种的实测质量。**中文输入的六种全部测过了**
    /// ——2026-08-19 的六语对照（26 条 × 6 种 = 156 次推理，零失败、
    /// 零残留汉字、零截断）。
    ///
    /// 此前葡/法/意标的是 `unmeasured`，德语标的是 0.89（只跑了 10 条的
    /// 小样本）。全量跑完之后德语的逐字值反而降到 0.84，而**忽略大小写是
    /// 1.00**——小样本乐观与判据选错，两个问题同时暴露。详见类型注释。
    func quality(from input: Language) -> TranslationQuality {
        if self == input { return .notApplicable }
        // 实测表只覆盖 zh→X（2026-08-19 六语对照）。其他输入语种的组合
        // 一律 unmeasured——不许编一个数糊上去。
        guard input == .chinese else { return .unmeasured }
        switch self {
        case .chinese: return .notApplicable   // input==.chinese 时到不了这里，穷尽 switch 需要它
        // 2026-08-19 六语对照，忽略大小写那一版。理由见类型注释。
        case .english: return .measured(termRetention: 1.00)
        case .german: return .measured(termRetention: 1.00)
        case .italian: return .measured(termRetention: 1.00)
        case .french: return .measured(termRetention: 0.98)
        case .portuguese: return .measured(termRetention: 0.96)
        case .spanish: return .measured(termRetention: 0.94)
        }
    }

    /// 菜单项上的那一行字（本语种作为目标、从 `input` 译过来时）。
    ///
    /// **提示做在每一个菜单项上，而不是一次性弹窗**：弹窗切走再切回来就
    /// 看不到了，而用户挑语言的那一刻正是他需要这个差异的时刻。
    ///
    /// 计算放在这里而不是拼在 SwiftUI 视图里，是本仓库既有的分工
    /// （见 `HUDViewModel`：「全部计算做成纯函数，视图只负责画」）——
    /// 拼在视图里就没有任何测试守得住它。
    func menuLabel(from input: Language) -> String {
        switch quality(from: input) {
        case .notApplicable:
            // 语言名单看是个语言名，看不出「选它等于不翻译」。
            "\(displayName)（与输入相同，不翻译）"
        case .measured(let retention):
            // 两位小数：实测值本身就是两位（1.00 / 0.94），
            // 多印几位是在假装精度。
            "\(displayName) · 术语保留 \(String(format: "%.2f", retention))"
        case .unmeasured:
            "\(displayName) · 未实测"
        }
    }
}
