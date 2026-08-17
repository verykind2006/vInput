import Foundation
import UserNotifications

/// 通知授权状态。
///
/// 只留三种。`UNAuthorizationStatus` 还有 `provisional` 与 `ephemeral`，
/// 对本产品没有区别——能送出去就是能送出去，送不出去就得走退路。
enum NotificationAuthorization: Equatable {
    /// 从未问过用户，可以弹一次系统弹窗。
    case notDetermined
    /// 可以投递。
    case authorized
    /// 用户拒了，或系统层面不可用。**再请求也不会弹窗**，只会白问一次。
    case denied
}

/// 发系统通知的最小抽象。
///
/// **做成 protocol 不是为了将来换实现，是为了这块能被测到。**
/// `UNUserNotificationCenter.current()` 要求进程有真实的 app bundle
/// （bundle identifier + Info.plist），`swift test` 的宿主进程没有——
/// 调它不是抛错，是直接终止整个测试进程。于是生产实现一行都进不了单元
/// 测试，只能把它藏在协议后面，用替身测「授权状态怎么处理」这部分逻辑。
///
/// 这是仓库里 `TextSink` / `AudioSource` 的同一条路子：协议 + 生产实现
/// + 测试替身，把碰系统全局状态的那一层压到最薄。
@MainActor
protocol Notifier {
    /// 当前授权状态。
    func authorizationStatus() async -> NotificationAuthorization
    /// 弹系统授权弹窗，返回用户选择之后的状态。
    func requestAuthorization() async -> NotificationAuthorization
    /// 投递一条通知。
    ///
    /// **失败必须抛错，不许吞。** 这条路本身就是「文字没落地」的兜底，
    /// 它要是也无声失效，用户就再没有任何线索了。
    func post(title: String, body: String) async throws
}

/// `UNUserNotificationCenter` 的包装。**不进单元测试**，理由见 `Notifier`。
///
/// 刻意不在 init 里碰 `.current()`：构造它本身必须是安全的，
/// 否则连「在测试里 new 一个」都做不到，出问题时也无从二分。
@MainActor
final class SystemNotifier: Notifier {
    func authorizationStatus() async -> NotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return switch settings.authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorized, .provisional, .ephemeral: .authorized
        // .denied 与将来可能新增的取值都归到 denied：
        // 不确定能不能送达时，走退路比赌一把安全。
        default: .denied
        }
    }

    func requestAuthorization() async -> NotificationAuthorization {
        do {
            // 不要 .sound：这条通知的意义是「你刚才说的话在剪贴板里」，
            // 用户此刻正在别的应用里打字，响一声只是打扰。
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge])
            return granted ? .authorized : .denied
        } catch {
            AppLogger.shared.log("通知授权请求失败：\(error)")
            return .denied
        }
    }

    func post(title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        // trigger 为 nil = 立即投递。
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        try await UNUserNotificationCenter.current().add(request)
    }
}

/// 一条通知的内容。
///
/// `fallbackNotice` 与 `body` 分开写，是因为两处的可用空间差一个数量级：
/// 通知横幅能放两三行并带上文字开头，HUD 状态行只有一行。
struct NotificationContent: Equatable {
    let title: String
    let body: String
    /// 通知这条路走不通时改用的短提示。
    let fallbackNotice: String
}

/// 「发通知，发不出去就走退路」这条策略。
///
/// 单独成一个类型而不是写在调用方里，是因为它是本轮 M6 ① 唯一需要判断的
/// 逻辑，而调用方（`AppModel` 的接线）一行都测不了。
@MainActor
struct NotificationPresenter {
    private let notifier: Notifier
    /// 通知送不出去时的退路：把一句话交给别处显示（生产里是 HUD）。
    ///
    /// **这个退路是本条设计的重点，不是补丁。** 通知权限是个新弹窗，用户
    /// 划掉或拒掉之后，这条兜底就会静默失效——而它兜的正是「说的话没落地
    /// 也没留下副本」那类问题。兜底自己无声失效是最坏的一种。
    private let fallback: @MainActor (String) -> Void

    init(notifier: Notifier, fallback: @escaping @MainActor (String) -> Void) {
        self.notifier = notifier
        self.fallback = fallback
    }

    /// 把授权弹窗提前到启动时问掉。
    ///
    /// 不这么做的话，弹窗会恰好出现在「注入失败」的那一刻——那时用户人在
    /// 别的应用里、手上还有一句话要救，是最不该被打断的时机。
    ///
    /// 被拒也不提示：那时用户还没有任何文字需要救，提示只是噪音。
    func primeAuthorization() async {
        guard await notifier.authorizationStatus() == .notDetermined else { return }
        let result = await notifier.requestAuthorization()
        AppLogger.shared.log("通知授权请求结果：\(result)")
    }

    /// 发一条通知；任何一环走不通都退回 `fallback` 并写日志。
    func present(_ content: NotificationContent) async {
        var status = await notifier.authorizationStatus()

        // 只有「从未问过」才请求。已经拒过的再请求不会弹窗，白问一次，
        // 还会让日志里的状态看起来像是刚被拒。
        if status == .notDetermined {
            status = await notifier.requestAuthorization()
            AppLogger.shared.log("通知授权请求结果：\(status)")
        }

        guard status == .authorized else {
            AppLogger.shared.log("通知未授权（\(status)），退回 HUD 提示：\(content.fallbackNotice)")
            fallback(content.fallbackNotice)
            return
        }

        do {
            try await notifier.post(title: content.title, body: content.body)
        } catch {
            AppLogger.shared.log("通知投递失败：\(error)，退回 HUD 提示")
            fallback(content.fallbackNotice)
        }
    }
}
