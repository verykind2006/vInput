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

/// 可临时改道的注入口：接上改道闭包时，文本**不再离开本应用**。
///
/// ## 为什么需要它
///
/// 首次启动向导最后一步是「试说一句」，要求转写结果落进**向导自己的输入框**。
/// 走平常那条路（`RoutingTextSink` → `TypingSink` → `CGEvent`）做不到这件事：
/// `TypingSink` 往「当前焦点」合成键盘事件，而「当前焦点」是谁由系统说了算。
/// 向导窗口此刻确实是前台，看上去也能落进去，但那是**碰巧**——用户在录音
/// 途中点一下别的窗口，这句话就打进了别人的文档里。向导是给第一次用这个
/// 应用的人看的，不能拿「碰巧」当保证。
///
/// 而且那条路还要辅助功能授权（`TypingSink` 第一件事就是查 `AXIsProcessTrusted`）。
/// 向导第三步刚教用户去开这个权限，第五步就依赖它，等于把「验证一下能用了」
/// 变成「再验证一次刚才那步」。
///
/// 改道之后：`DictationSession` 照常走完录音→转写→校正→翻译，只有最后
/// 「送出去」这一下被换成一次闭包调用。**没有 CGEvent 被投递**，
/// 因此不存在打进别的应用的可能——不是「大概率不会」，是这条路上没有那个动作。
///
/// ## 为什么是 class
///
/// `DictationSession.sink` 是 `let`，会话建好之后换不掉。装一个引用类型进去，
/// 之后改它的 `redirect` 属性即可——不必为了向导去动会话的生命周期。
///
/// ## 谁负责摘掉
///
/// 谁挂谁摘（`OnboardingCoordinator` 在离开该步骤与关窗时都会摘）。
/// 忘了摘的后果很难查：此后每一次听写都静默消失，日志里还写着「注入成功」。
@MainActor
final class RedirectableTextSink: TextSink {
    /// 平常那条路。改道闭包为 nil 时原样转交。
    private let fallback: TextSink

    /// 接上它，文本就交给它而不出应用。
    var redirect: ((String) -> Void)?

    init(fallback: TextSink) {
        self.fallback = fallback
    }

    func send(_ text: String) throws {
        if let redirect {
            redirect(text)
            return
        }
        try fallback.send(text)
    }
}
