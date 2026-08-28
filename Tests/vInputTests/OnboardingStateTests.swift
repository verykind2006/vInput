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
    ///
    /// 2026-08-28：下载与试说之间插进了「输入语言」，这里跟着改。
    /// 「哪一步是最后一步」由 `next` 返回 nil 定义，那一条没变。
    @Test func completesOnlyAfterTestDictation() {
        #expect(OnboardingState.next(after: .downloadModel, microphone: true, accessibility: true)
            == .inputLanguage)
        #expect(OnboardingState.next(after: .inputLanguage, microphone: true, accessibility: true)
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
        #expect(
            !OnboardingState.shouldPresent(
                isComplete: true, hasModel: true, microphone: true, accessibility: true,
                forcePresent: false))
        #expect(
            OnboardingState.shouldPresent(
                isComplete: false, hasModel: false, microphone: false, accessibility: false,
                forcePresent: false))
    }

    // 2026-08-28：`shouldPresent` 的签名加了 hasModel/microphone/accessibility/
    // forcePresent 四个参数，上面那条「写不出运行时断言」的限制随之解除——
    // 「完成过就不再弹，哪怕权限被撤销」现在是一条真能失败的测试，见
    // completeFlagStillShortCircuitsEverything。

    /// 环境全绿就不弹：模型齐、两项权限都有，说明这台机器已经配好了，
    /// 没有任何一步向导还能告诉他新东西。
    ///
    /// 2026-08-28 重装系统后撞上的正是这条缺口：UserDefaults 被清空
    /// （`onboarding.complete` 键直接消失），而模型和权限一应俱全，
    /// 向导却每次启动都糊在脸上。
    @Test("环境全绿不弹向导")
    func doesNotPresentWhenEverythingIsReady() {
        #expect(
            !OnboardingState.shouldPresent(
                isComplete: false, hasModel: true, microphone: true, accessibility: true,
                forcePresent: false),
            "模型和两项权限都齐了还弹向导，等于每次开机糊用户一脸。")
    }

    /// 半绿态必须照弹——这才是向导存在的理由。
    ///
    /// 三个缺口逐个单独验：写成「随便缺一个就弹」的话，
    /// 把判据错写成 `hasModel || microphone || accessibility` 之类
    /// 也能蒙混过关。
    @Test("差任何一项都还要弹")
    func presentsWhenAnythingIsMissing() {
        #expect(
            OnboardingState.shouldPresent(
                isComplete: false, hasModel: false, microphone: true, accessibility: true,
                forcePresent: false),
            "没有模型就没法听写，这正是向导要解决的头号问题。")
        #expect(
            OnboardingState.shouldPresent(
                isComplete: false, hasModel: true, microphone: false, accessibility: true,
                forcePresent: false),
            "没有麦克风权限，一个字也录不进来。")
        #expect(
            OnboardingState.shouldPresent(
                isComplete: false, hasModel: true, microphone: true, accessibility: false,
                forcePresent: false),
            "没有辅助功能权限，转写出来的字注不进任何应用。")
    }

    /// 完成标记仍然一票否决，**哪怕环境全塌**。
    ///
    /// 这是原注释里那条写不出来的断言。语义没变：撤销权限的那一刻用户正在
    /// 系统设置里，弹一个抢焦点的窗口是打断；面板状态行会说「需要麦克风
    /// 权限」，那条路更轻。
    @Test("完成过就永远不再弹，哪怕环境全塌")
    func completeFlagStillShortCircuitsEverything() {
        #expect(
            !OnboardingState.shouldPresent(
                isComplete: true, hasModel: false, microphone: false, accessibility: false,
                forcePresent: false),
            "完成过的人不该因为事后撤了权限就被向导抢一次焦点。")
    }

    /// 开发开关无条件弹，**优先于完成标记和全绿环境**。
    ///
    /// 存在的理由：判据改成看环境之后，开发机（模型权限俱全）再也弹不出
    /// 向导了，而向导本身还需要被验收。没有这个开关就只能靠撤权限、
    /// 挪模型来触发，那是拿真实环境当测试夹具。
    @Test("开发开关短路一切")
    func forcePresentOverridesEverything() {
        #expect(
            OnboardingState.shouldPresent(
                isComplete: true, hasModel: true, microphone: true, accessibility: true,
                forcePresent: true),
            "开关打开却弹不出来，这个开关就没有存在的意义。")
    }

    /// 开发开关从 UserDefaults 读，键名钉死。
    ///
    /// 钉键名是因为它是对外契约的一部分——用户要在终端敲
    /// `defaults write com.vinput.app onboarding.forcePresent -bool true`，
    /// 改了键名而不改文档，那行命令就会静默失效。
    @Test("开发开关的键名与默认值")
    func forcePresentReadsFromDefaults() {
        let defaults = makeDefaults()
        #expect(!OnboardingState.forcePresent(defaults: defaults), "没设过就不该强弹。")

        defaults.set(true, forKey: OnboardingState.forcePresentKey)
        #expect(OnboardingState.forcePresent(defaults: defaults))
        #expect(OnboardingState.forcePresentKey == "onboarding.forcePresent")
    }

    /// 输入语言排在下载模型之后、试说一句之前。
    ///
    /// 位置有讲究：模型下载在 `present()` 那一刻就在后台跑了，靠前面几步
    /// 吸收那十几分钟；语言选择再吸收一段。而紧接着的「试说一句」正好
    /// 用上刚选的语言，选完立刻验证，形成闭环。
    @Test("输入语言步骤插在下载与试说之间")
    func inputLanguageSitsBetweenDownloadAndTest() {
        #expect(
            OnboardingState.next(after: .downloadModel, microphone: true, accessibility: true)
                == .inputLanguage,
            "下载完直接跳到试说，语言选择这一步就永远不会出现。")
        #expect(
            OnboardingState.next(after: .inputLanguage, microphone: true, accessibility: true)
                == .testDictation)
    }

    /// 语言步骤**不因权限而跳过**——它跟麦克风、辅助功能不是一回事。
    ///
    /// 权限步骤能跳是因为「已经给了就没什么可做的」；语言没有这种
    /// 「已满足」状态，读不到值时是默认中文而不是「未设置」，所以它
    /// 对每个真正走向导的人都该出现一次。
    @Test("语言步骤不受权限影响")
    func inputLanguageIsNotSkippedByPermissions() {
        for mic in [true, false] {
            for ax in [true, false] {
                #expect(
                    OnboardingState.next(after: .downloadModel, microphone: mic, accessibility: ax)
                        == .inputLanguage,
                    "权限状态 mic=\(mic) ax=\(ax) 时语言步骤被跳过了。")
            }
        }
    }
}
