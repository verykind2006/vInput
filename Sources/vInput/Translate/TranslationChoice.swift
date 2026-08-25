import Foundation

/// 翻译目标的两态：不翻译，或译成某语种。
///
/// **「不翻译」曾经借用「目标=中文」表示**——那是源恒为中文时代的巧合。
/// 输入语言放开后两个含义劈开：说英文选「不翻译」要出英文，而「译成中文」
/// 成了真实存在的方向。
enum TranslationChoice: Equatable, Sendable {
    case off
    case translate(to: Language)

    /// UserDefaults 里的存储值。"off" 不是任何语言的 rawValue，不会撞。
    ///
    /// **存稳定字符串而不是枚举序号**：`Language` 的 rawValue 由
    /// `LanguageTests.rawValuesAreStable` 逐个钉死，加一种语言不会把用户
    /// 已保存的设置挪到别的语言上；存序号的话在中间插一格就全错位了。
    var storageValue: String {
        switch self {
        case .off: "off"
        case .translate(let language): language.rawValue
        }
    }

    /// 读到不认识的值时退回「不翻译」——唯一不会把用户没要的语言注进
    /// 输入框的取值（与旧 `outputLanguage` 的退回同一条理由）。
    init(storageValue: String) {
        if let language = Language(rawValue: storageValue) {
            self = .translate(to: language)
        } else {
            self = .off
        }
    }

    /// 给定输入语言后的有效翻译目标；nil = 不翻译。
    /// **目标==输入时也是 nil**：译成自己说的语言是句废话，不建管线。
    func effectiveTarget(input: Language) -> Language? {
        switch self {
        case .off: nil
        case .translate(let language): language == input ? nil : language
        }
    }
}
