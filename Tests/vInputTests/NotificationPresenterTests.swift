import Testing
import UserNotifications
@testable import vInput

/// 通知的测试替身。
///
/// 生产实现 `SystemNotifier` 一行都进不了测试（见 `Notifier` 的注释：
/// `UNUserNotificationCenter.current()` 没有真实 app bundle 就崩），
/// 所有关于「授权状态怎么处理」的断言都落在这个替身上。
@MainActor
final class FakeNotifier: Notifier {
    var status: NotificationAuthorization = .authorized
    /// 用户在系统弹窗上的选择，`requestAuthorization` 之后 `status` 变成它。
    var grantsWhenAsked = true
    /// 投递时抛这个错。模拟「授权拿到了但系统仍然没送出去」。
    var postError: Error?

    private(set) var statusQueries = 0
    private(set) var requestCount = 0
    private(set) var posted: [(title: String, body: String)] = []

    func authorizationStatus() async -> NotificationAuthorization {
        statusQueries += 1
        return status
    }

    func requestAuthorization() async -> NotificationAuthorization {
        requestCount += 1
        status = grantsWhenAsked ? .authorized : .denied
        return status
    }

    func post(title: String, body: String) async throws {
        if let postError { throw postError }
        posted.append((title, body))
    }
}

private enum FakeNotifierError: Error { case rejected }

@Suite("通知投递")
@MainActor
struct NotificationPresenterTests {
    private let content = NotificationContent(
        title: "标题", body: "正文", fallbackNotice: "退路提示"
    )

    private func makePresenter(
        _ notifier: FakeNotifier, fallback: @escaping @MainActor (String) -> Void = { _ in }
    ) -> NotificationPresenter {
        NotificationPresenter(notifier: notifier, fallback: fallback)
    }

    @Test("已授权时直接投递，不再请求授权")
    func postsWhenAuthorized() async {
        let notifier = FakeNotifier()
        notifier.status = .authorized
        var notices: [String] = []

        await makePresenter(notifier) { notices.append($0) }.present(content)

        #expect(notifier.statusQueries == 1)
        #expect(notifier.requestCount == 0)
        #expect(notifier.posted.count == 1)
        #expect(notifier.posted.first?.title == "标题")
        #expect(notifier.posted.first?.body == "正文")
        #expect(notices.isEmpty)
    }

    @Test("发通知之前必先查授权状态")
    func checksAuthorizationBeforePosting() async {
        let notifier = FakeNotifier()
        notifier.status = .denied

        await makePresenter(notifier).present(content)

        #expect(notifier.statusQueries == 1)
        // 没查到授权就不该有任何投递尝试。
        #expect(notifier.posted.isEmpty)
    }

    @Test("首次使用时请求授权，用户同意后照常投递")
    func requestsAuthorizationOnFirstUse() async {
        let notifier = FakeNotifier()
        notifier.status = .notDetermined
        notifier.grantsWhenAsked = true
        var notices: [String] = []

        await makePresenter(notifier) { notices.append($0) }.present(content)

        #expect(notifier.requestCount == 1)
        #expect(notifier.posted.count == 1)
        #expect(notices.isEmpty)
    }

    @Test("首次请求被拒时退回提示，不静默失败")
    func fallsBackWhenFirstRequestDenied() async {
        let notifier = FakeNotifier()
        notifier.status = .notDetermined
        notifier.grantsWhenAsked = false
        var notices: [String] = []

        await makePresenter(notifier) { notices.append($0) }.present(content)

        #expect(notifier.requestCount == 1)
        #expect(notifier.posted.isEmpty)
        #expect(notices == ["退路提示"])
    }

    @Test("此前已被拒时退回提示，且不再弹第二次系统弹窗")
    func fallsBackWhenDenied() async {
        let notifier = FakeNotifier()
        notifier.status = .denied
        var notices: [String] = []

        await makePresenter(notifier) { notices.append($0) }.present(content)

        // 已经拒过一次的授权再请求也不会弹窗，白问一次还会掩盖真实状态。
        #expect(notifier.requestCount == 0)
        #expect(notifier.posted.isEmpty)
        #expect(notices == ["退路提示"])
    }

    @Test("授权拿到了但投递失败，同样退回提示")
    func fallsBackWhenPostThrows() async {
        let notifier = FakeNotifier()
        notifier.status = .authorized
        notifier.postError = FakeNotifierError.rejected
        var notices: [String] = []

        await makePresenter(notifier) { notices.append($0) }.present(content)

        #expect(notices == ["退路提示"])
    }

    @Test("预请求授权只在从未问过时弹窗")
    func primeOnlyAsksWhenUndetermined() async {
        let undetermined = FakeNotifier()
        undetermined.status = .notDetermined
        await makePresenter(undetermined).primeAuthorization()
        #expect(undetermined.requestCount == 1)

        let authorized = FakeNotifier()
        authorized.status = .authorized
        await makePresenter(authorized).primeAuthorization()
        #expect(authorized.requestCount == 0)

        let denied = FakeNotifier()
        denied.status = .denied
        await makePresenter(denied).primeAuthorization()
        #expect(denied.requestCount == 0)
    }

    @Test("提醒样式是「无」时不投递，退回 HUD——post 会成功但用户看不见")
    func fallsBackWhenAlertsDisabled() async {
        let notifier = FakeNotifier()
        notifier.status = .alertsDisabled
        var notices: [String] = []

        await makePresenter(notifier) { notices.append($0) }.present(content)

        // **这一档此前是整个漏掉的**：authorizationStatus 报 authorized、
        // post 成功返回、屏幕上一个横幅都没有，退路从不触发，日志里只有
        // 「注入失败，已写入剪贴板」，一个字都没提示用户没被通知到。
        #expect(notifier.posted.isEmpty)
        #expect(notices == ["退路提示"])
        // 再请求授权也没用——总开关本来就是开的，系统不会为「样式」弹窗。
        #expect(notifier.requestCount == 0)
    }

    @Test("预请求不投递任何通知")
    func primeDoesNotPost() async {
        let notifier = FakeNotifier()
        notifier.status = .notDetermined
        var notices: [String] = []

        await makePresenter(notifier) { notices.append($0) }.primeAuthorization()

        #expect(notifier.posted.isEmpty)
        // 预请求只是把弹窗提前到启动时，被拒也不该在这时候提示什么——
        // 那时用户还没有任何文字需要救。
        #expect(notices.isEmpty)
    }

    @Test("样式是「无」时预请求不弹窗、也不提示")
    func primeStaysQuietWhenAlertsDisabled() async {
        let notifier = FakeNotifier()
        notifier.status = .alertsDisabled
        var notices: [String] = []

        await makePresenter(notifier) { notices.append($0) }.primeAuthorization()

        // 只写日志（见 primeAuthorization）：那时用户还没有文字需要救，
        // 弹一条提示只是噪音；但日志里必须有，否则这一档到第一次注入失败
        // 才显形，而那时人已经在别的应用里了。
        #expect(notifier.requestCount == 0)
        #expect(notices.isEmpty)
    }
}

/// 系统两个开关 → 我们这一档状态的折算。
///
/// 这是 `SystemNotifier` 里唯一能被单元测试碰到的部分（其余方法要求真实
/// app bundle，见 `Notifier` 的注释），而「通知发了但用户看不见」那一整档
/// 的成因就在这条判断上。
@Suite("通知授权状态的折算")
struct NotificationAuthorizationMappingTests {
    private func map(
        _ status: UNAuthorizationStatus, _ alert: UNNotificationSetting
    ) -> NotificationAuthorization {
        SystemNotifier.authorization(status: status, alert: alert)
    }

    @Test("允许 + 提醒样式开着才算真的能通知到")
    func authorizedWithAlerts() {
        #expect(map(.authorized, .enabled) == .authorized)
    }

    @Test("允许通知但提醒样式是「无」——这一档此前被判成 authorized")
    func authorizedWithoutAlerts() {
        // macOS 通知设置里「允许通知 = 开、提醒样式 = 无」是同一个面板里
        // 常见的一档。此前只读 authorizationStatus，于是 post 成功返回、
        // 没有任何横幅、退路不触发。
        #expect(map(.authorized, .disabled) == .alertsDisabled)
    }

    @Test("系统报告不支持提醒时按看不见处理")
    func notSupportedTreatedAsInvisible() {
        // 两侧代价不对称：白退到 HUD 只是提示弱一点且日志留得下痕迹，
        // 赌一把赌错则是用户什么都看不到——正是本条要修的病。
        #expect(map(.authorized, .notSupported) == .alertsDisabled)
    }

    @Test("临时授权也按同一把尺子量：看样式，不看它是哪种授权")
    func provisionalFollowsAlertSetting() {
        // 临时授权的通知只静悄悄进通知中心、不弹横幅，此前被当成 authorized。
        // （`.ephemeral` 在 macOS 上不可用，源码里列出它只是为了穷尽 switch，
        // 这里测不到，也不需要测。）
        #expect(map(.provisional, .disabled) == .alertsDisabled)
        #expect(map(.provisional, .enabled) == .authorized)
    }

    @Test("从未问过时样式无意义，仍是 notDetermined")
    func notDeterminedIgnoresAlertSetting() {
        // 授权之前系统报的样式是 .notSupported，此时据它下结论会把
        // 「还没问过」误判成「问过了但看不见」，从此再也不弹授权弹窗。
        #expect(map(.notDetermined, .notSupported) == .notDetermined)
        #expect(map(.notDetermined, .enabled) == .notDetermined)
    }

    @Test("拒绝一律是 denied，样式再好也没用")
    func deniedStaysDenied() {
        #expect(map(.denied, .enabled) == .denied)
    }
}
