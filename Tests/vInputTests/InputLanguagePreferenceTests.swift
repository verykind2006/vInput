import Foundation
import Testing

@testable import vInput

@Suite("输入语言偏好")
struct InputLanguagePreferenceTests {
    /// 每条用例一个独立 suite：`UserDefaults.standard` 是进程级共享的，
    /// 用它会让并行跑的用例互相污染，而症状是「单跑绿、全量偶尔红」。
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "vinput.input-language.tests.\(UUID().uuidString)")!
    }

    /// 默认中文——发布以来的行为基线，升级不改变任何人的现状。
    @Test("默认是中文")
    func defaultsToChinese() {
        #expect(InputLanguagePreference(defaults: makeDefaults()).language == .chinese)
    }

    @Test("设置后能读回，认不出的值退回中文")
    func roundTripsAndSurvivesUnknownValue() {
        let defaults = makeDefaults()
        let preference = InputLanguagePreference(defaults: defaults)
        preference.language = .english
        #expect(InputLanguagePreference(defaults: defaults).language == .english)
        defaults.set("klingon", forKey: "transcription.inputLanguage")
        // 认不出的值退回中文——中文是发布以来的行为基线。
        #expect(preference.language == .chinese)
    }
}
