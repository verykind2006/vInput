import Foundation

/// 注入没成功时，把用户说的话救回来。
///
/// 抽成协议只为一件事：`DictationSession` 的测试要能断言「这条路走到了」，
/// 而真实实现会碰剪贴板与系统通知。
@MainActor
protocol TextRescuing {
    func rescue(_ text: String, error: Error) async
}

/// 剪贴板兜底 + 系统通知。M6 ① 的两条触发路径共用它。
///
/// 规则二（注入失败，如 `accessibilityDenied`）与规则三（目标应用改变）
/// 此前都让文本**直接蒸发**：不入剪贴板、不提示，只在日志里留一行
/// 「会话出错」。2026-08-17 真机上撞到过——打包重签名作废了辅助功能授权，
/// 说的话没落地也没留下副本。
///
/// **通知只提示、不代劳。** 刻意不做「点通知自动重新注入」：点通知会把
/// vInput 拉到前台，**反而把注入目标变成我们自己**，时序脆弱且容易注错
/// 地方。文字已在剪贴板，由用户自己按 ⌘V。
///
/// **走系统通知而不是只让 HUD 变红**：规则三触发时用户人已经在别的应用
/// 里，HUD 未必在视野内，通知是唯一还能触达的方式。通知权限拿不到时才
/// 退回 HUD，见 `NotificationPresenter`。
@MainActor
struct TextRescue: TextRescuing {
    private let clipboard: ClipboardSink
    private let presenter: NotificationPresenter

    init(clipboard: ClipboardSink, presenter: NotificationPresenter) {
        self.clipboard = clipboard
        self.presenter = presenter
    }

    func rescue(_ text: String, error: Error) async {
        guard !text.isEmpty else { return }

        // **先写剪贴板再发通知。** 救回文字是这条路唯一不能失败的事；
        // 通知那一侧要查授权、要走系统队列，任何一次卡顿或失败都不该
        // 连累它。反过来排的话，通知被拒时文字就又没了。
        clipboard.stash(text)
        AppLogger.shared.logTranscript(text, context: "注入失败，已写入剪贴板：\(error)")

        await presenter.present(Self.content(for: text, error: error))
    }

    /// 通知里最多带多少字的开头。
    ///
    /// 通知横幅两三行就满了，整段塞进去只会被系统截断在随机位置。
    /// 20 字够认出「是刚才那句话」，这是它唯一要回答的问题。
    static let previewLength = 20

    /// 组装文案。纯函数，好把边界穷举掉。
    static func content(for text: String, error: Error) -> NotificationContent {
        let preview = text.count > previewLength
            ? text.prefix(previewLength) + "…"
            : text[...]

        // 标题分两种：规则三触发时用户人在别的应用里，得先让他知道是焦点
        // 变了而不是程序坏了；权限那条则要指向一个他能去做的动作。
        let title: String = switch error {
        case let sinkError as TextSinkError:
            switch sinkError {
            case .targetApplicationChanged: "焦点已切到别的应用，文字没有输入"
            case .accessibilityDenied: "没有辅助功能权限，文字没有输入"
            case .eventCreationFailed: "文字没有输入"
            }
        default: "文字没有输入"
        }

        return NotificationContent(
            title: title,
            // 正文必须带上文字开头：剪贴板已被直接覆盖，用户有权知道现在
            // 里面是什么，否则「⌘V 粘出来的是不是我要的那句」无从判断。
            body: "已复制到剪贴板，按 ⌘V 粘贴：「\(preview)」",
            // HUD 状态行只有一行，且内容已经在剪贴板里，这里只说动作。
            fallbackNotice: "文字未输入，已复制（⌘V）"
        )
    }
}
