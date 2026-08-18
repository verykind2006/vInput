import Foundation
import Testing

@testable import vInput

@Suite("目标语言")
struct TranslationTargetTests {
    /// 中文是「不翻译」，必须能表达，否则菜单栏没法回到原状态。
    @Test("中文表示不翻译")
    func chineseMeansNoTranslation() {
        #expect(TranslationTarget.chinese.requiresTranslation == false)
        #expect(TranslationTarget.english.requiresTranslation == true)
    }

    /// 本轮只做拉丁字母语种——闸门「译文里不该有汉字」对日语完全失效
    /// （日文本来就用汉字），而日韩两种语言用户与实现方都读不了，
    /// 无从判断「报价三百」有没有被翻成「报价三千」。见 spec 第一节。
    @Test("本轮只有拉丁字母语种")
    func onlyLatinScriptForNow() {
        // 逐个点名而不是遍历——遍历 requiresTranslation 的集合来断言
        // usesLatinScript，在两者实现相同时是同义反复，检查不到东西。
        #expect(TranslationTarget.chinese.usesLatinScript == false)
        #expect(TranslationTarget.english.usesLatinScript)
        #expect(TranslationTarget.spanish.usesLatinScript)
        #expect(TranslationTarget.german.usesLatinScript)
        #expect(TranslationTarget.portuguese.usesLatinScript)
        #expect(TranslationTarget.french.usesLatinScript)
        #expect(TranslationTarget.italian.usesLatinScript)
        // 本轮的范围闸门：加语言时这条会先红，逼人回来想清楚闸门还成不成立。
        #expect(TranslationTarget.allCases.filter(\.requiresTranslation).count == 6)
    }

    /// prompt 里要用英文名——模型对 "Spanish" 的理解比对「西班牙语」稳。
    @Test("每种语言都有 prompt 用的英文名")
    func hasEnglishNameForPrompt() {
        #expect(TranslationTarget.spanish.englishName == "Spanish")
        #expect(TranslationTarget.portuguese.englishName == "Portuguese")
        for target in TranslationTarget.allCases where target.requiresTranslation {
            #expect(!target.englishName.isEmpty)
        }
    }

    /// 菜单栏要显示中文名。
    @Test("每种语言都有菜单显示名")
    func hasDisplayName() {
        #expect(TranslationTarget.chinese.displayName == "中文")
        #expect(TranslationTarget.english.displayName == "英文")
        for target in TranslationTarget.allCases {
            #expect(!target.displayName.isEmpty)
        }
    }

    /// 偏好要跨启动保存，所以必须有稳定的字符串标识——
    /// 不能靠枚举顺序，加一种语言就会把用户的设置改掉。
    @Test("标识符稳定且唯一")
    func rawValuesAreStableAndUnique() {
        #expect(TranslationTarget.english.rawValue == "en")
        #expect(TranslationTarget.chinese.rawValue == "zh")
        let ids = TranslationTarget.allCases.map(\.rawValue)
        #expect(Set(ids).count == ids.count)
    }
}
