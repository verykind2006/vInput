import Testing
@testable import vInput

/// 内存剪贴板，替代 NSPasteboard.general。
final class FakePasteboard: PasteboardWriting {
    var content: String?
    private(set) var writeCount = 0

    func string() -> String? { content }

    func write(_ value: String) {
        content = value
        writeCount += 1
    }
}

@Suite("ClipboardSink")
@MainActor
struct ClipboardSinkTests {
    private func makeSink(
        pasteboard: FakePasteboard,
        pasteRecorder: @escaping () -> Void = {}
    ) -> ClipboardSink {
        var sink = ClipboardSink(pasteboard: pasteboard)
        sink.isAccessibilityTrusted = { true }
        sink.sendPasteShortcut = pasteRecorder
        sink.restoreDelay = 0   // 测试里手动触发恢复
        return sink
    }

    @Test("把文本写入剪贴板并触发粘贴")
    func writesAndPastes() throws {
        let pasteboard = FakePasteboard()
        pasteboard.content = "原有内容"
        var pasteCount = 0
        let sink = makeSink(pasteboard: pasteboard) { pasteCount += 1 }

        try sink.send("新文本")

        #expect(pasteCount == 1)
        #expect(pasteboard.content == "新文本")
    }

    @Test("粘贴后恢复原剪贴板内容")
    func restoresPreviousContent() throws {
        let pasteboard = FakePasteboard()
        pasteboard.content = "原有内容"
        let sink = makeSink(pasteboard: pasteboard)

        try sink.send("新文本")
        sink.performPendingRestore()

        #expect(pasteboard.content == "原有内容")
    }

    @Test("若剪贴板在此期间被他人改写则放弃恢复")
    func skipsRestoreWhenClipboardChanged() throws {
        let pasteboard = FakePasteboard()
        pasteboard.content = "原有内容"
        let sink = makeSink(pasteboard: pasteboard)

        try sink.send("新文本")
        // 模拟用户在粘贴与恢复之间复制了别的东西
        pasteboard.write("用户复制的东西")
        sink.performPendingRestore()

        #expect(pasteboard.content == "用户复制的东西")
    }

    @Test("原本为空的剪贴板恢复为空")
    func restoresEmptyClipboard() throws {
        let pasteboard = FakePasteboard()
        pasteboard.content = nil
        let sink = makeSink(pasteboard: pasteboard)

        try sink.send("新文本")
        sink.performPendingRestore()

        #expect(pasteboard.content == "")
    }

    @Test("未授权时抛错且不改动剪贴板")
    func deniedWhenUntrusted() {
        let pasteboard = FakePasteboard()
        pasteboard.content = "原有内容"
        var sink = ClipboardSink(pasteboard: pasteboard)
        sink.isAccessibilityTrusted = { false }

        #expect(throws: TextSinkError.accessibilityDenied) {
            try sink.send("新文本")
        }
        #expect(pasteboard.content == "原有内容")
    }

    @Test("重复恢复不会二次改写剪贴板")
    func restoreIsIdempotent() throws {
        let pasteboard = FakePasteboard()
        pasteboard.content = "原有内容"
        let sink = makeSink(pasteboard: pasteboard)

        try sink.send("新文本")
        sink.performPendingRestore()
        let countAfterFirst = pasteboard.writeCount
        sink.performPendingRestore()

        #expect(pasteboard.writeCount == countAfterFirst)
        #expect(pasteboard.content == "原有内容")
    }
}
