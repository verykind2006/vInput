import Foundation
import Testing

@testable import vInput

/// 翻译标注怎么落到 HUD 上。
///
/// 测的是 `AppModel.applyTranslationAnnotation` 这个 `static` 纯函数——
/// `AppModel` 的实例构造会拉起真快捷键、真 CGEvent tap 与模型加载，测试
/// 进程里跑不动，判断留在方法体里就没有任何东西守得住。
@Suite("翻译标注到 HUD")
@MainActor
struct TranslationAnnotationTests {
    /// 正常译出时不该在 HUD 上留字——留了的话每句话都要多停
    /// `hudNoticeLinger` 那几秒（`endHUD` 有附注就不立刻收面板）。
    @Test("正常译出不显示标注")
    func silentOnSuccess() {
        let model = HUDViewModel()
        AppModel.applyTranslationAnnotation(nil, to: model)
        #expect(model.notice == nil)
    }

    /// **nil 的语义是「什么都不做」，不是「清空」。**
    ///
    /// 这条守的是一个真发生过的写法错误：翻译回调排在校正回调之后
    /// （`.correcting` → `.translating`），照抄校正那行写成
    /// `notice = annotation?.hudLabel` 的话，**一次成功的翻译会把刚写进去的
    /// 校正标注抹掉**，而用户看到的是「校正好像没运行」。
    ///
    /// 把实现改回赋值式，本条立刻红。
    @Test("正常译出不抹掉已有的校正标注")
    func successDoesNotWipeCorrectionNotice() {
        let model = HUDViewModel()
        model.notice = "校正已运行，本次无改动"
        AppModel.applyTranslationAnnotation(nil, to: model)
        #expect(model.notice == "校正已运行，本次无改动")
    }

    /// 文案取自 `TranslationAnnotation.hudLabel`，**不在这一层另写一套**。
    ///
    /// 断言写成「等于 hudLabel」而不是「等于某个字面量」是有意的：字面量
    /// 会把同一句话钉在两个地方，改一处忘另一处的表现是「HUD 说的和日志
    /// 说的不一样」，很难查。而 `hudLabel` 本身的措辞由
    /// `TranslationAnnotationLabelTests` 单独守着（两两不同、都含「中文原文」、
    /// 加一格不配文案编译不过）。
    @Test("失败时显示对应文案")
    func showsLabelOnFailure() {
        let model = HUDViewModel()
        AppModel.applyTranslationAnnotation(.timedOut, to: model)
        #expect(model.notice == TranslationAnnotation.timedOut.hudLabel)
    }

    /// **每一种标注都要真的写得出去。**
    ///
    /// 只测 `.timedOut` 一种的话，「某个分支被漏掉、写不出任何东西」不会被
    /// 发现。样本表与 `TranslationAnnotationLabelTests` 共用同一份，
    /// 那边有个只为编译期存在的穷尽 switch——枚举加一格时那里编译不过，
    /// 人被迫回来补样本，这份表也就跟着全。
    @Test("每一种标注都写得到 HUD 上")
    func everyAnnotationReachesHUD() {
        for annotation in TranslationAnnotationLabelTests.annotations {
            let model = HUDViewModel()
            AppModel.applyTranslationAnnotation(annotation, to: model)
            #expect(model.notice == annotation.hudLabel, "\(annotation) 没写到 HUD 上")
        }
    }

    /// 翻译标注覆盖先前的校正标注——**当前行为，刻意钉住**。
    ///
    /// 两者都非 nil 时用户其实需要知道两件事（「校正改了三处」+「翻译超时，
    /// 已注入中文原文」），当前实现是「后写的赢」。这条不是在说这个行为对，
    /// 是在说它是**选定的**：将来改成拼接成两行时本条会先红，改的人会看到
    /// 这段注释，而不是以为自己在修一个 bug。
    @Test("翻译标注覆盖先前的校正标注（当前行为，刻意钉住）")
    func translationOverwritesCorrectionNotice() {
        let model = HUDViewModel()
        model.notice = "校正已运行，本次无改动"
        AppModel.applyTranslationAnnotation(.timedOut, to: model)
        #expect(model.notice == TranslationAnnotation.timedOut.hudLabel)
    }
}
