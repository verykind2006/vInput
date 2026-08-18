import Testing
@testable import vInput

@Suite("注入失败的剪贴板兜底")
@MainActor
struct TextRescueTests {
    private func makeRescue(
        pasteboard: FakePasteboard,
        notifier: FakeNotifier,
        fallback: @escaping @MainActor (String) -> Void = { _ in }
    ) -> TextRescue {
        TextRescue(
            clipboard: ClipboardSink(pasteboard: pasteboard),
            presenter: NotificationPresenter(notifier: notifier, fallback: fallback)
        )
    }

    @Test("注入失败时把文字写进剪贴板")
    func writesTextToClipboard() async {
        let pasteboard = FakePasteboard()
        pasteboard.content = "用户原有内容"
        let notifier = FakeNotifier()

        await makeRescue(pasteboard: pasteboard, notifier: notifier)
            .rescue("说的这句话", error: TextSinkError.accessibilityDenied)

        #expect(pasteboard.content == "说的这句话")
    }

    @Test("不代劳粘贴：不需要辅助功能授权也能救回文字")
    func doesNotNeedAccessibility() async {
        // ClipboardSink.send 会因为没有辅助功能授权而抛错，而这条兜底路径
        // 恰恰常常就是被 accessibilityDenied 触发的——它必须绕开那道检查。
        let pasteboard = FakePasteboard()
        var sink = ClipboardSink(pasteboard: pasteboard)
        sink.isAccessibilityTrusted = { false }
        var pasted = false
        sink.sendPasteShortcut = { pasted = true }

        sink.stash("说的这句话")

        #expect(pasteboard.content == "说的这句话")
        #expect(!pasted)
    }

    @Test("写进去就不再恢复原内容")
    func doesNotRestore() async {
        let pasteboard = FakePasteboard()
        pasteboard.content = "用户原有内容"
        var sink = ClipboardSink(pasteboard: pasteboard)
        sink.restoreDelay = 0

        sink.stash("说的这句话")
        // send 那条路会在粘贴之后还原剪贴板；stash 这条路没有粘贴，
        // 还原等于把刚救下来的文字又丢掉。
        sink.performPendingRestore()

        #expect(pasteboard.content == "说的这句话")
    }

    @Test("空文本不动剪贴板")
    func ignoresEmptyText() async {
        let pasteboard = FakePasteboard()
        pasteboard.content = "用户原有内容"

        await makeRescue(pasteboard: pasteboard, notifier: FakeNotifier())
            .rescue("", error: TextSinkError.accessibilityDenied)

        #expect(pasteboard.content == "用户原有内容")
    }

    @Test("写完剪贴板发一条通知")
    func postsNotification() async {
        let notifier = FakeNotifier()
        notifier.status = .authorized

        await makeRescue(pasteboard: FakePasteboard(), notifier: notifier)
            .rescue("说的这句话", error: TextSinkError.accessibilityDenied)

        #expect(notifier.posted.count == 1)
    }

    @Test("通知发不出去时文字仍然在剪贴板里")
    func clipboardSurvivesNotificationFailure() async {
        let pasteboard = FakePasteboard()
        let notifier = FakeNotifier()
        notifier.status = .denied
        var notices: [String] = []

        await makeRescue(pasteboard: pasteboard, notifier: notifier) { notices.append($0) }
            .rescue("说的这句话", error: TextSinkError.accessibilityDenied)

        // 先写剪贴板再发通知：顺序反过来的话，通知这条路上任何一次卡顿或
        // 失败都会连累「救回文字」这件真正重要的事。
        #expect(pasteboard.content == "说的这句话")
        #expect(notices.count == 1)
    }

    // MARK: - 文案

    @Test("通知正文带上文字开头，让用户知道剪贴板现在是什么")
    func bodyCarriesTextPrefix() {
        let content = TextRescue.content(
            for: "今天下午三点开会", error: TextSinkError.accessibilityDenied
        )

        #expect(content.body.contains("今天下午三点开会"))
        // 覆盖用户原有剪贴板是已定的代价，正文必须说清粘贴动作。
        #expect(content.body.contains("⌘V"))
    }

    @Test("长文本只取开头，通知横幅放不下整段")
    func bodyTruncatesLongText() {
        let long = String(repeating: "字", count: 200)
        let content = TextRescue.content(for: long, error: TextSinkError.accessibilityDenied)

        #expect(content.body.count < 100)
        #expect(content.body.contains("…"))
    }

    @Test("目标应用改变与注入失败给不同的标题")
    func titleDistinguishesReasons() {
        let changed = TextRescue.content(
            for: "文字",
            error: TextSinkError.targetApplicationChanged(expected: "a", actual: "b")
        )
        let denied = TextRescue.content(for: "文字", error: TextSinkError.accessibilityDenied)

        #expect(changed.title != denied.title)
        // 规则三触发时用户人已经在别的应用里，标题要说清是焦点变了。
        #expect(changed.title.contains("应用"))
        #expect(denied.title.contains("权限"))
    }

    @Test("退路提示一行放得下，且不含文字内容")
    func fallbackNoticeIsShort() {
        let content = TextRescue.content(
            for: String(repeating: "字", count: 200),
            error: TextSinkError.accessibilityDenied
        )

        // HUD 状态行只有一行；内容已经在剪贴板里，退路提示只需说清动作。
        #expect(content.fallbackNotice.count <= 24)
        #expect(!content.fallbackNotice.contains("字字字"))
        #expect(content.fallbackNotice.contains("⌘V"))
    }
}
