import Testing
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
}
