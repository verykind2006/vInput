import Foundation
import UserNotifications

/// 通知授权状态。
///
/// `UNAuthorizationStatus` 的 `provisional` 与 `ephemeral` 不单列——对本产品
/// 没有区别，能送出去就是能送出去，送不出去就得走退路。
///
/// **`alertsDisabled` 是第四种，2026-08-17 补的，它此前被整个漏掉了。**
/// 系统设置里「允许通知」与「提醒样式」是同一个面板里的两个独立开关，
/// 「允许 = 开、样式 = 无」是常见的一档。那时 `authorizationStatus`
/// 照样是 `.authorized`、`post` 照样成功返回，**但屏幕上一个横幅都不会出现**，
/// 于是退路（`fallback`）永远不被调用，日志里只有「注入失败，已写入剪贴板」
/// 一行，一个字都没提示用户其实没被通知到。**兜底自己无声失效**，正是
/// M6 ① 要消灭的那一类。
enum NotificationAuthorization: Equatable {
    /// 从未问过用户，可以弹一次系统弹窗。
    case notDetermined
    /// 可以投递，且投递出去用户看得见。
    case authorized
    /// 授权在，但提醒样式是「无」（或系统报告不支持提醒）。
    ///
    /// **不能当成 `.authorized`**：post 会成功，用户看不见。
    /// 也不该合并进 `.denied`：两者要做的事一样（走退路），但日志里必须
    /// 分得开——「用户拒了通知」和「用户把提醒样式关成无」在系统设置里是
    /// 两个不同的开关，排查时指向的修法也不同。
    case alertsDisabled
    /// 用户拒了，或系统层面不可用。**再请求也不会弹窗**，只会白问一次。
    case denied
}

extension NotificationAuthorization {
    /// 这一档发出去的通知用户看得见吗。只有它为真才走通知，否则走退路。
    var deliversVisibly: Bool { self == .authorized }
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
    /// 进程有没有真实的 app bundle。
    ///
    /// 没有的话 `UNUserNotificationCenter.current()` 会直接终止进程——
    /// **不是抛错，是 crash**。生产上永远是 `dist/vInput.app`
    /// （`scripts/build-app.sh`），走不到这里；留这道 guard 是因为它的代价
    /// 是一行，而漏掉它的代价是「有人直接跑二进制，应用一启动就没了，
    /// 日志里什么都没有」。查不出来的崩溃比降级贵得多。
    private var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    func authorizationStatus() async -> NotificationAuthorization {
        guard hasBundle else {
            AppLogger.shared.log("没有 app bundle，通知不可用（是不是直接跑了二进制？）")
            return .denied
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return Self.authorization(
            status: settings.authorizationStatus, alert: settings.alertSetting
        )
    }

    /// 把系统的两个开关折算成我们这一档状态。**抽成纯函数是为了能测**——
    /// `SystemNotifier` 本身一行都进不了单元测试（见 `Notifier` 的注释），
    /// 而这条判断正是「通知发了但用户看不见」那一整档的成因所在。
    ///
    /// 两个开关必须一起看：
    ///
    /// - `authorizationStatus` 回答「允许不允许发」；
    /// - `alertSetting` 回答「发了会不会有横幅」。macOS 的通知设置面板里
    ///   「提醒样式：无 / 横幅 / 提醒」与上面那个总开关是分开的，
    ///   「允许 = 开、样式 = 无」这一档下 `post` 成功返回、屏幕上什么都没有。
    ///
    /// 各档的处理：
    ///
    /// | `authorizationStatus` | `alertSetting` | 结果 | 理由 |
    /// |---|---|---|---|
    /// | `.notDetermined` | 任意 | `.notDetermined` | 还没问过，样式此时无意义（系统会报 `.notSupported`）；问完再看 |
    /// | `.authorized` / `.provisional` / `.ephemeral` | `.enabled` | `.authorized` | 唯一「送得出去且看得见」的一档 |
    /// | 同上 | `.disabled` | `.alertsDisabled` | 用户在设置里明确关掉了横幅 |
    /// | 同上 | `.notSupported` | `.alertsDisabled` | **看不见就当看不见**：系统说它给不了提醒，我们就不该赌 |
    /// | 同上 | 将来新增 | `.alertsDisabled` | 同上，未知一律按看不见处理 |
    /// | `.denied` / 将来新增 | 任意 | `.denied` | 不确定能不能送达时，走退路比赌一把安全 |
    ///
    /// `.notSupported` 归到看不见这一侧是有代价的：真出现在某个 macOS 版本上
    /// 而横幅其实是好的，我们会白白退到 HUD。选它是因为两侧的代价不对称——
    /// 退到 HUD 只是提示弱一点，且**日志里留得下痕迹**；赌一把赌错则是用户
    /// 什么都看不到，而这正是本条要修的病。`provisional` 也顺带归了位：
    /// 临时授权的通知只静悄悄进通知中心、不弹横幅，此前被当成 `.authorized`。
    nonisolated static func authorization(
        status: UNAuthorizationStatus, alert: UNNotificationSetting
    ) -> NotificationAuthorization {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .authorized, .provisional, .ephemeral:
            return alert == .enabled ? .authorized : .alertsDisabled
        default:
            return .denied
        }
    }

    func requestAuthorization() async -> NotificationAuthorization {
        guard hasBundle else { return .denied }
        do {
            // 不要 .sound：这条通知的意义是「你刚才说的话在剪贴板里」，
            // 用户此刻正在别的应用里打字，响一声只是打扰。
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge])
            guard granted else { return .denied }
            // 拿到授权之后**回头再读一次 settings**，而不是直接返回
            // `.authorized`：能不能被看见由 `alertSetting` 说了算，而这个
            // 方法看不到它。两处各自下结论就会出现「请求那条路报 authorized、
            // 查询那条路报 alertsDisabled」的分叉。
            return await authorizationStatus()
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
        let status = await notifier.authorizationStatus()
        // 启动时就把「样式=无」记一笔。这一档下通知全程静默失效，而它要到
        // 用户第一次注入失败时才会显形——那时人在别的应用里，日志是唯一线索。
        if status == .alertsDisabled {
            AppLogger.shared.log(
                "通知已授权，但系统设置里的提醒样式是「无」，横幅不会出现，本次运行的通知一律退回 HUD"
            )
        }
        guard status == .notDetermined else { return }
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

        // 判据是「用户看不看得见」，不是「post 会不会成功」。样式设成「无」
        // 那一档 post 是成功的，横幅却不存在——照 post 就等于兜底静默失效。
        guard status.deliversVisibly else {
            let reason = status == .alertsDisabled
                ? "通知已授权但提醒样式是「无」，横幅不会出现"
                : "通知未授权（\(status)）"
            AppLogger.shared.log("\(reason)，退回 HUD 提示：\(content.fallbackNotice)")
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
