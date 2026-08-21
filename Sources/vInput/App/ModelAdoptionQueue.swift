import Foundation

/// 「下载好的模型什么时候真的换上去」。
///
/// ## 为什么需要它
///
/// 向导关掉**不取消下载**（扔掉几百 MB 更糟），于是下载会在用户已经开始
/// 正常使用应用之后才完成，完成时调 `adoptModelFolder` → `refreshAvailableModels()`
/// + `selectModelFromFolder()` → `selectModel`。而 `selectModel` 的第一道门是
/// `canSwitchModel`（录音或转写途中为 false）。两种坏结果各占一半：
///
/// - **正录着的时候下载完**：`selectModel` 打一行日志就返回，此后**再也没有
///   人重试**。用户刚下了 1.5GB，说完这句话之后用的还是老模型，菜单里也不会
///   自己切过去——只有重启或手动去列表里点一下才认。这是本类型要修的那一半。
/// - **没在录音的时候下载完**：换是换了，但整个过程只有一行日志。用户会看到
///   菜单栏图标忽然变成加载态、主按钮灰掉一两分钟，而他刚才什么都没点。
///   这一半修在文案侧（`MenuPanelModel.downloadLine` / `pendingModelLine`），
///   本类型只负责把「待启用」这个状态**留下来给面板读**。
///
/// ## 为什么单独一个类型而不是 `AppModel` 里两个字段
///
/// `AppModel` 在测试进程里构造不出来（init 就要真麦克风、真 CGEvent tap），
/// 长在那里等于零覆盖——`correctionApplyPending` 那条补挂逻辑就是先例，
/// 变异实测全绿（见 `AppModel.translationCoordinator` 上那段注释）。
/// 搬到这里之后，「被拒时记住了没有」「回到 idle 补没补上」两条都跑得到。
@MainActor
final class ModelAdoptionQueue {
    /// 等着被换上去的目录。nil 表示没有欠账。面板据此显示「结束后自动启用」。
    private(set) var pendingFolder: String?

    /// 下载/导入完成，请求换上去。
    ///
    /// 返回**现在就该换上去的目录**；返回 nil 表示这次先记下来，等会话结束。
    /// 把「能不能换」当参数传进来而不是自己去问：判据（`canSwitchModel`）
    /// 长在 `AppModel` 上，而本类型要能在没有 `AppModel` 的地方被驱动。
    func request(folder: String, canSwitchNow: Bool) -> String? {
        guard canSwitchNow else {
            pendingFolder = folder
            AppLogger.shared.log("模型换用被推迟（会话进行中），已记下待启用目录：\(folder)")
            return nil
        }
        pendingFolder = nil
        return folder
    }

    /// 会话回到 idle 时问一次：有欠账就还。
    ///
    /// **拿走就清**（返回之前把 `pendingFolder` 置空）：换模型本身是异步的，
    /// 不清的话下一次回到 idle 会再换一遍同一个目录——而那时用户可能已经手动
    /// 选了别的模型，等于被这条补挂悄悄改回去。
    ///
    /// `canSwitchNow` 仍然要问：回到 idle 与「能换模型」不是同一件事
    /// （`loadingModelName` 非空时也不能换）。不能换就原样留着，下次再问。
    func resume(canSwitchNow: Bool) -> String? {
        guard let folder = pendingFolder, canSwitchNow else { return nil }
        pendingFolder = nil
        AppLogger.shared.log("会话已结束，补上此前被推迟的模型换用：\(folder)")
        return folder
    }
}
