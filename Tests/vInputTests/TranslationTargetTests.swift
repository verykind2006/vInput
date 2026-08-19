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

    /// englishName 直接插进 prompt（见 TranslationPrompt）。写错就是让模型
    /// 翻成别的语言，**而闸门对此完全无感**——残留汉字、长度比、中文标点
    /// 三条判据都发现不了「你选意大利语、结果给了法语」。所以逐个钉死。
    @Test("prompt 用的英文名逐个钉死")
    func englishNamesArePinned() {
        #expect(TranslationTarget.chinese.englishName == "Chinese")
        #expect(TranslationTarget.english.englishName == "English")
        #expect(TranslationTarget.spanish.englishName == "Spanish")
        #expect(TranslationTarget.german.englishName == "German")
        #expect(TranslationTarget.portuguese.englishName == "Portuguese")
        #expect(TranslationTarget.french.englishName == "French")
        #expect(TranslationTarget.italian.englishName == "Italian")
    }

    @Test("菜单显示名逐个钉死且不重名")
    func displayNamesArePinnedAndUnique() {
        #expect(
            TranslationTarget.allCases.map(\.displayName)
                == ["中文", "英文", "西班牙文", "德文", "葡萄牙文", "法文", "意大利文"]
        )
        // 重名不会被编译器拦住，而菜单栏出现两个「意大利文」用户没法选。
        let names = TranslationTarget.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
    }

    /// 偏好要跨启动保存，所以 rawValue 必须稳定——**逐个列全，不能只抽查
    /// 两个**。将来有人「统一成 ISO 639-2」把 es 改成 spa，用户已保存的
    /// 语言设置会静默丢失，而抽查式断言一片绿。
    ///
    /// 顺带取代了原来那条 `Set(ids).count == ids.count`：重复 rawValue 是
    /// **编译错误**（`raw value for enum case is not unique`），
    /// 那条断言永远不可能失败，检查不到任何东西。
    @Test("标识符稳定且逐个钉死")
    func rawValuesAreStable() {
        #expect(
            TranslationTarget.allCases.map(\.rawValue)
                == ["zh", "en", "es", "de", "pt", "fr", "it"]
        )
    }
}
