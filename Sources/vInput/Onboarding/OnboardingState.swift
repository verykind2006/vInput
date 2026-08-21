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
        case testDictation
    }

    static let stepKey = "onboarding.step"
    static let completeKey = "onboarding.complete"

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
            return .testDictation
        case .testDictation:
            return nil
        }
    }

    /// 要不要弹向导。
    ///
    /// **完成过就永远不再弹**，哪怕权限后来被撤销：撤销的那一刻用户正在
    /// 系统设置里，弹一个抢焦点的窗口是打断；面板的状态行已经会说
    /// 「需要麦克风权限」，那条路更轻。
    nonisolated static func shouldPresent(isComplete: Bool) -> Bool {
        !isComplete
    }
}
