import Foundation
import Testing

@testable import vInput

/// 向导的步骤推进与状态恢复。
@MainActor
struct OnboardingStateTests {
    private func makeDefaults() -> UserDefaults {
        let name = "onboarding-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// 全新用户：从欢迎页开始。
    @Test func freshInstallStartsAtWelcome() {
        let state = OnboardingState(defaults: makeDefaults())
        #expect(!state.isComplete)
        #expect(state.step == .welcome)
    }

    /// 已授权的步骤自动跳过——重装或已经手动开过权限的人，
    /// 不该被再问一遍。
    @Test func skipsAlreadySatisfiedPermissionSteps() {
        #expect(
            OnboardingState.next(after: .welcome, microphone: true, accessibility: true)
                == .downloadModel)
        #expect(
            OnboardingState.next(after: .welcome, microphone: false, accessibility: true)
                == .microphone)
        #expect(
            OnboardingState.next(after: .microphone, microphone: true, accessibility: false)
                == .accessibility)
    }

    /// 走完最后一步才算完成。
    @Test func completesOnlyAfterTestDictation() {
        #expect(OnboardingState.next(after: .downloadModel, microphone: true, accessibility: true)
            == .testDictation)
        #expect(OnboardingState.next(after: .testDictation, microphone: true, accessibility: true)
            == nil)
    }

    /// 中途退出可续：记住走到哪了，下次从那儿开始，不从头再来。
    @Test func resumesWhereItLeftOff() {
        let defaults = makeDefaults()
        let first = OnboardingState(defaults: defaults)
        first.advance(to: .downloadModel)

        let second = OnboardingState(defaults: defaults)
        #expect(second.step == .downloadModel)
        #expect(!second.isComplete)
    }

    /// 完成后不再弹——这是「首次」向导。
    @Test func doesNotReappearOnceComplete() {
        let defaults = makeDefaults()
        let first = OnboardingState(defaults: defaults)
        first.markComplete()

        #expect(OnboardingState(defaults: defaults).isComplete)
        #expect(!OnboardingState.shouldPresent(isComplete: true))
        #expect(OnboardingState.shouldPresent(isComplete: false))
    }

    // 「权限被事后撤销不重开向导」这条场景，本文件删掉了对应的独立测试：
    // `shouldPresent(isComplete:)` 的签名里根本没有权限参数——调用方
    // （Task 6 的向导/AppModel）无法把权限状态传进来，所以「传 false 也
    // 返回 false」这种运行时断言写不出来；唯一能写出的形态是
    // `!shouldPresent(isComplete: true)`，而那正是 doesNotReappearOnceComplete
    // 已经断言过的同一行代码。留着它只是把同一个真值包一层新名字，
    // 是文档伪装成测试，本仓库的历史教训之一（见 MEMORY 里的
    // mutation-testing-is-mandatory）。「不咨询权限」这条契约由函数签名
    // 本身保证：想加回权限参数的人会在这改类型签名，而不是在这偷偷传参。
}
