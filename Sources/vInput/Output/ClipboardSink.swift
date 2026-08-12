import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 剪贴板读写的最小抽象，便于测试时替换掉全局单例。
protocol PasteboardWriting: AnyObject {
    func string() -> String?
    func write(_ value: String)
}

/// 包装 NSPasteboard.general。
final class SystemPasteboard: PasteboardWriting {
    private let pasteboard = NSPasteboard.general

    func string() -> String? {
        pasteboard.string(forType: .string)
    }

    func write(_ value: String) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

/// 通过剪贴板 + Cmd+V 输入文本。
///
/// 用于两种情形：文本过长（逐字符注入不可靠），
/// 以及 TypingSink 失败后的降级。
@MainActor
struct ClipboardSink: TextSink {
    /// 粘贴到恢复原内容之间的等待时长。
    /// 太短会在目标应用读取剪贴板之前就恢复，导致粘贴到旧内容。
    var restoreDelay: TimeInterval = 0.6

    var isAccessibilityTrusted: () -> Bool = { AXIsProcessTrusted() }
    var sendPasteShortcut: () -> Void = ClipboardSink.postCommandV

    private let pasteboard: PasteboardWriting
    /// 待恢复的状态。用引用类型是因为本类型是 struct，
    /// 而 send 需要在其后的异步闭包里读到写入的状态。
    private let pending = PendingRestore()

    init(pasteboard: PasteboardWriting = SystemPasteboard()) {
        self.pasteboard = pasteboard
    }

    func send(_ text: String) throws {
        guard !text.isEmpty else { return }
        guard isAccessibilityTrusted() else {
            throw TextSinkError.accessibilityDenied
        }

        let previous = pasteboard.string()
        pasteboard.write(text)
        pending.set(written: text, previous: previous)

        sendPasteShortcut()

        let delay = restoreDelay
        if delay > 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                performPendingRestore()
            }
        }
    }

    /// 恢复原剪贴板内容。仅当剪贴板仍是我们写入的那份时才执行——
    /// 否则说明用户在这期间复制了别的东西，不应覆盖。
    func performPendingRestore() {
        guard let state = pending.take() else { return }
        guard pasteboard.string() == state.written else { return }
        if let previous = state.previous {
            pasteboard.write(previous)
        } else {
            pasteboard.write("")
        }
    }

    /// nonisolated：CGEvent 的发送是线程安全的，且它要作为
    /// 非隔离闭包类型 `() -> Void` 的默认值使用。
    nonisolated private static func postCommandV() {
        let vKeyCode: CGKeyCode = 9  // kVK_ANSI_V
        guard
            let down = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}

/// 承载待恢复状态。
@MainActor
private final class PendingRestore {
    struct State {
        let written: String
        let previous: String?
    }

    private var state: State?

    func set(written: String, previous: String?) {
        state = State(written: written, previous: previous)
    }

    func take() -> State? {
        defer { state = nil }
        return state
    }
}
