import Foundation

/// 在打字与剪贴板两条输入通道之间路由。
///
/// 路由规则：
/// - 长度超过阈值 → 剪贴板（逐字符注入长文本在终端与 Electron 中不可靠）
/// - 否则 → 打字；失败则降级到剪贴板
///
/// 长文本走剪贴板失败后不再回退到打字，因为那条路对长文本本就不可靠。
@MainActor
struct RoutingTextSink: TextSink {
    let typing: TextSink
    let clipboard: TextSink
    /// 超过该字符数改走剪贴板。见 spec 第六节规则三。
    var threshold: Int = 100

    func send(_ text: String) throws {
        if text.count > threshold {
            try clipboard.send(text)
            return
        }

        do {
            try typing.send(text)
        } catch {
            try clipboard.send(text)
        }
    }
}
