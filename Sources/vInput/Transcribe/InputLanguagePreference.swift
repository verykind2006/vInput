import Foundation

/// 用户说的是什么语言。转写解码、校正挂载、翻译源语言都读它。
///
/// 注入 `UserDefaults` 而非直接用 `.standard`：测试需要互不干扰的独立
/// 存储，否则测试之间会互相污染（与 `TranslationPreference` 同款）。
///
/// 键带 `transcription.` 前缀：它属于转写，不属于翻译——云端开关
/// 「只管翻译」那条边界（见 `TranslationPreference`）不该被它搅浑。
struct InputLanguagePreference {
    private enum Key { static let language = "transcription.inputLanguage" }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// 默认中文——发布以来的行为基线，升级不改变任何人的现状。
    /// 读到不认识的值时同样退回中文（应用降级回旧版本、或手改 plist）。
    var language: Language {
        get {
            guard let raw = defaults.string(forKey: Key.language) else { return .chinese }
            return Language(rawValue: raw) ?? .chinese
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.language) }
    }
}
