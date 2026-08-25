import Foundation
import Testing

@testable import vInput

/// 「不翻译」从「目标=中文」的巧合里剥出来之后的两态语义。
struct TranslationChoiceTests {
    @Test func storageValuesAreStable() {
        // 存储格式一旦发布就不能变，逐个钉死。
        #expect(TranslationChoice.off.storageValue == "off")
        for language in Language.allCases {
            #expect(TranslationChoice.translate(to: language).storageValue == language.rawValue)
        }
    }

    @Test func unknownStorageValueFallsBackToOff() {
        // 认不出的值退回「不翻译」——唯一不会把用户没要的语言注进输入框的取值。
        #expect(TranslationChoice(storageValue: "klingon") == .off)
        #expect(TranslationChoice(storageValue: "off") == .off)
    }

    @Test func effectiveTargetIsNilWhenSameAsInput() {
        // 目标==输入 等同不翻译：不建管线、不烧模型。
        #expect(TranslationChoice.translate(to: .english).effectiveTarget(input: .english) == nil)
        #expect(TranslationChoice.translate(to: .spanish).effectiveTarget(input: .english) == .spanish)
        #expect(TranslationChoice.translate(to: .chinese).effectiveTarget(input: .english) == .chinese)
        #expect(TranslationChoice.off.effectiveTarget(input: .chinese) == nil)
    }

    @Test func legacyZhMigratesToOff() {
        // 老用户存的 "zh" 当时的含义是「不翻译」，不是「译成中文」。
        let defaults = UserDefaults(suiteName: "test.migration.\(UUID())")!
        defaults.set("zh", forKey: "translation.outputLanguage")
        let preference = TranslationPreference(defaults: defaults)
        #expect(preference.migrateLegacyOutputLanguageIfNeeded() == true)
        #expect(preference.choice == .off)
        // 第二次调用不再迁移（新键已写入）。
        #expect(preference.migrateLegacyOutputLanguageIfNeeded() == false)
    }

    @Test func legacyForeignLanguageMigratesToTranslate() {
        let defaults = UserDefaults(suiteName: "test.migration.\(UUID())")!
        defaults.set("es", forKey: "translation.outputLanguage")
        let preference = TranslationPreference(defaults: defaults)
        #expect(preference.migrateLegacyOutputLanguageIfNeeded() == true)
        #expect(preference.choice == .translate(to: .spanish))
    }

    @Test func freshInstallNeedsNoMigrationAndDefaultsToOff() {
        let defaults = UserDefaults(suiteName: "test.migration.\(UUID())")!
        let preference = TranslationPreference(defaults: defaults)
        #expect(preference.migrateLegacyOutputLanguageIfNeeded() == false)
        #expect(preference.choice == .off)
    }
}
