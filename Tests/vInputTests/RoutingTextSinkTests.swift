import Testing
@testable import vInput

/// 记录调用的 sink 替身。Task 11 的 DictationSession 测试也会用到它。
@MainActor
final class SpySink: TextSink {
    private(set) var received: [String] = []
    var error: Error?

    func send(_ text: String) throws {
        received.append(text)
        if let error { throw error }
    }
}

@Suite("RoutingTextSink")
@MainActor
struct RoutingTextSinkTests {
    @Test("短文本走打字通道")
    func shortTextUsesTyping() throws {
        let typing = SpySink()
        let clipboard = SpySink()
        let sink = RoutingTextSink(typing: typing, clipboard: clipboard, threshold: 100)

        try sink.send("短文本")

        #expect(typing.received == ["短文本"])
        #expect(clipboard.received.isEmpty)
    }

    @Test("超过阈值的文本走剪贴板")
    func longTextUsesClipboard() throws {
        let typing = SpySink()
        let clipboard = SpySink()
        let sink = RoutingTextSink(typing: typing, clipboard: clipboard, threshold: 10)
        let long = String(repeating: "字", count: 11)

        try sink.send(long)

        #expect(typing.received.isEmpty)
        #expect(clipboard.received == [long])
    }

    @Test("恰好等于阈值时仍走打字通道")
    func exactThresholdUsesTyping() throws {
        let typing = SpySink()
        let clipboard = SpySink()
        let sink = RoutingTextSink(typing: typing, clipboard: clipboard, threshold: 10)
        let text = String(repeating: "字", count: 10)

        try sink.send(text)

        #expect(typing.received == [text])
    }

    @Test("打字失败时降级到剪贴板")
    func fallsBackToClipboardOnTypingFailure() throws {
        let typing = SpySink()
        typing.error = TextSinkError.eventCreationFailed
        let clipboard = SpySink()
        let sink = RoutingTextSink(typing: typing, clipboard: clipboard, threshold: 100)

        try sink.send("短文本")

        #expect(typing.received == ["短文本"])
        #expect(clipboard.received == ["短文本"])
    }

    @Test("两条通道都失败时抛出剪贴板的错误")
    func throwsWhenBothFail() {
        let typing = SpySink()
        typing.error = TextSinkError.eventCreationFailed
        let clipboard = SpySink()
        clipboard.error = TextSinkError.accessibilityDenied
        let sink = RoutingTextSink(typing: typing, clipboard: clipboard, threshold: 100)

        #expect(throws: TextSinkError.accessibilityDenied) {
            try sink.send("短文本")
        }
    }

    @Test("长文本走剪贴板失败时不再回退到打字")
    func longTextDoesNotFallBackToTyping() {
        let typing = SpySink()
        let clipboard = SpySink()
        clipboard.error = TextSinkError.accessibilityDenied
        let sink = RoutingTextSink(typing: typing, clipboard: clipboard, threshold: 10)

        #expect(throws: TextSinkError.accessibilityDenied) {
            try sink.send(String(repeating: "字", count: 50))
        }
        // 长文本逐字符注入本就不可靠，回退没有意义。
        #expect(typing.received.isEmpty)
    }
}

@Suite("TargetAppGuard")
struct TargetAppGuardTests {
    @Test("捕获当前前台应用的 bundle ID")
    func capturesFrontmost() {
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }

        #expect(guardian.capture() == "com.apple.Notes")
    }

    @Test("前台应用未变时校验通过")
    func passesWhenUnchanged() throws {
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }
        let token = guardian.capture()

        try guardian.verify(token)
    }

    @Test("前台应用改变时抛出并带上两侧标识")
    func failsWhenChanged() {
        var current = "com.apple.Notes"
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { current }
        let token = guardian.capture()

        current = "com.tencent.xinWeChat"

        #expect(throws: TextSinkError.targetApplicationChanged(
            expected: "com.apple.Notes",
            actual: "com.tencent.xinWeChat"
        )) {
            try guardian.verify(token)
        }
    }

    @Test("捕获时无前台应用则跳过校验")
    func skipsWhenNothingCaptured() throws {
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { nil }
        let token = guardian.capture()

        guardian.frontmostBundleID = { "com.apple.Notes" }
        // 没有基准可比，不应阻断注入
        try guardian.verify(token)
    }

    @Test("校验时前台应用消失则抛出")
    func failsWhenFrontmostDisappears() {
        var current: String? = "com.apple.Notes"
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { current }
        let token = guardian.capture()

        current = nil

        #expect(throws: TextSinkError.targetApplicationChanged(
            expected: "com.apple.Notes",
            actual: nil
        )) {
            try guardian.verify(token)
        }
    }
}
