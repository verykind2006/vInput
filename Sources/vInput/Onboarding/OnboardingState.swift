import Foundation
import Observation

/// 首次启动向导的步骤与进度。
///
/// 步骤推进做成 `nonisolated static` 纯函数，实例只管落盘与恢复——
/// 向导窗口在测试进程里跑不起来，能榨出来的逻辑必须榨出来。
@MainActor
@Observable
final class OnboardingState {
    enum Step: String, Equatable, CaseIterable {
        case welcome
        case microphone
        case accessibility
        case downloadModel
        case inputLanguage
        case testDictation
    }

    static let stepKey = "onboarding.step"
    static let completeKey = "onboarding.complete"
    static let forcePresentKey = "onboarding.forcePresent"

    private let defaults: UserDefaults
    private(set) var step: Step
    private(set) var isComplete: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isComplete = defaults.bool(forKey: Self.completeKey)
        self.step = Step(rawValue: defaults.string(forKey: Self.stepKey) ?? "") ?? .welcome
    }

    func advance(to step: Step) {
        self.step = step
        defaults.set(step.rawValue, forKey: Self.stepKey)
    }

    func markComplete() {
        isComplete = true
        defaults.set(true, forKey: Self.completeKey)
    }

    /// 下一步是哪一步。**已满足的权限步骤直接跳过**——重装的人、或者
    /// 早就手动开过权限的人，不该被再问一遍。返回 nil 表示走完了。
    nonisolated static func next(
        after step: Step, microphone: Bool, accessibility: Bool
    ) -> Step? {
        switch step {
        case .welcome:
            if !microphone { return .microphone }
            if !accessibility { return .accessibility }
            return .downloadModel
        case .microphone:
            if !accessibility { return .accessibility }
            return .downloadModel
        case .accessibility:
            return .downloadModel
        case .downloadModel:
            return .inputLanguage
        case .inputLanguage:
            return .testDictation
        case .testDictation:
            return nil
        }
    }

    /// 开发开关：无条件弹向导。
    ///
    /// 判据改成看环境之后，配好的机器（模型权限俱全）再也弹不出向导了，
    /// 而向导本身还需要被验收。没有这个开关就只能靠撤权限、挪模型来触发,
    /// 那是拿真实环境当测试夹具。用法记在 `docs/dev-dependencies.md`：
    ///
    ///     defaults write com.vinput.app onboarding.forcePresent -bool true
    nonisolated static func forcePresent(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Self.forcePresentKey)
    }

    /// 要不要弹向导。
    ///
    /// **完成过就永远不再弹**，哪怕权限后来被撤销：撤销的那一刻用户正在
    /// 系统设置里，弹一个抢焦点的窗口是打断；面板的状态行已经会说
    /// 「需要麦克风权限」，那条路更轻。
    ///
    /// **环境本来就全绿也不弹**（2026-08-28 加）。原先只认 `isComplete`
    /// 这一个布尔标记：重装系统把 UserDefaults 清空后，`onboarding.complete`
    /// 键直接消失，而模型和权限一应俱全——向导却每次启动都糊在脸上。
    /// `next()` 早就会跳过已满足的权限步骤（"重装的人不该被再问一遍"），
    /// 但跳步只在向导**已经弹出来之后**才起作用，"要不要弹"这一层是漏的。
    ///
    /// **跳过时不写 `markComplete`**：这只是"此刻没什么可教你的"，不是
    /// "你走完了向导"。模型后来被删、权限后来被撤，下次启动它该回来帮忙。
    ///
    /// **输入语言不进判据**，尽管它是向导的一步。它有合理默认（中文）且
    /// 没有"未设置"态——读不到值就是中文，不设置照样能用，跟"没有模型就
    /// 没法听写"不是一回事。把它算进来，只会让每个配好环境的人为确认一个
    /// 他本来就满意的默认值而多走一遍向导。
    nonisolated static func shouldPresent(
        isComplete: Bool, hasModel: Bool, microphone: Bool, accessibility: Bool,
        forcePresent: Bool
    ) -> Bool {
        if forcePresent { return true }
        return !isComplete && !(hasModel && microphone && accessibility)
    }
}
