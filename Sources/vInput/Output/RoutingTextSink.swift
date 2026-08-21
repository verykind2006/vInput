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
/// ## 改道闭包必须回答「这一次归我吗」，不能无条件吞
///
/// 返回 `Bool`，不是 `Void`。这一条是 2026-08-22 复审揪出来的一个 Critical，
/// 失效链完整记在这里，因为改回 `Void` 看上去更简洁：
///
/// 向导停在「试说一句」那一步时改道是挂着的。用户此刻**很可能切到微信去试**
/// 欢迎页刚承诺的那件事（「打进你正在用的那个窗口」）——他按 ⌥D 说了一句，
/// 而 `TargetAppGuard` 一路放行（捕获的是微信、微信仍在前台、`verify` 通过），
/// 于是这句话被吞进向导的输入框，微信里**什么都没出现**。文字凭空消失，
/// 正是这个应用最不能出的那一类事故，而且是从设计防守的反方向撞进来的。
///
/// 所以判据不是「向导停在第几步」，而是「这次听写是不是向导发起的」——
/// 由改道闭包自己回答（`OnboardingCoordinator` 的判据是它自己的窗口是不是
/// key window）。返回 `false` 时原样落回 `fallback`，行为与没挂改道时一致。
///
/// ## 谁负责摘掉
///
/// 谁挂谁摘（`OnboardingCoordinator` 在关窗与完成时都会摘）。忘了摘的后果
/// 已经被上面那个 `Bool` 兜住了一层，但仍然该摘干净：挂着的闭包会一直
/// 持有协调器。
@MainActor
final class RedirectableTextSink: TextSink {
    /// 平常那条路。改道闭包为 nil、或它说「这次不归我」时，原样转交。
    private let fallback: TextSink

    /// 接上它，**它说归自己的那几次**文本就不出应用。
    ///
    /// 返回值语义：`true` = 我收下了，别再往下送；`false` = 不归我，照常走。
    var redirect: ((String) -> Bool)?

    init(fallback: TextSink) {
        self.fallback = fallback
    }

    func send(_ text: String) throws {
        if let redirect, redirect(text) { return }
        try fallback.send(text)
    }
}
