import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import vInput

/// 面板的排版尺寸（R-2 底栏显示不全、R-3 字号偏小，2026-08-21 用户真机实测）。
///
/// # 为什么这一份不是扫源码
///
/// `MenuPanelViewWiringTests` 那一套扫源码，是因为视图跑不起来。但**尺寸不是
/// 视图**：`panelWidth` / `edgeGutter` / `TypeScale` 都是纯常量，可以直接断言。
/// R-3 要的「放大但保持层级」本来就是常量之间的大小关系，扫源码反而看不见。
///
/// 这也正是把字号从视图里的十几处字面量收成一张表的理由：字面量没有任何
/// 测试守得住，而这一批恰恰是用户点名要改、并且会亲自复看的。
///
/// # 这里证明不了什么
///
/// 证明不了「它长得好看」，也证明不了底栏在真机上不再被裁——后者取决于
/// `MenuBarExtra` 宿主窗口怎么内缩，那在进程内没有可观测量。能钉的是：
/// 底栏不再是整块面板里最靠边的那一个（R-2 的判断依据），字号不再退回旧档。
@Suite("菜单面板排版尺寸")
struct MenuPanelLayoutTests {
    typealias Scale = MenuPanelView.TypeScale

    // MARK: - R-3：放大之后层级还在

    /// 层级：头部 > 正文 > 次要 > 更次一级 ≥ 设备卡说明行。
    ///
    /// **「整体调大」最容易出的错是把层级压平**——比如为了让说明行看清而
    /// 把它也提到 13，于是行标题和说明行一样大，一整块面板变成一片同样
    /// 粗细的字。这条链式断言把每一层的相对关系都钉住。
    @Test("字号层级：头部 > 正文 > 次要 > 细节")
    func typeScaleKeepsHierarchy() {
        let headerOverBody = Scale.header > Scale.body
        #expect(
            headerOverBody,
            "头部字号 \(Scale.header) 没有大于正文 \(Scale.body)，头部不再是头部。")

        let bodyOverSecondary = Scale.body > Scale.secondary
        #expect(
            bodyOverSecondary,
            "正文 \(Scale.body) 没有大于次要信息 \(Scale.secondary)，设置行的标题和它的当前值会一样重。")

        let secondaryOverDetail = Scale.secondary > Scale.detail
        #expect(
            secondaryOverDetail,
            "次要 \(Scale.secondary) 没有大于细节 \(Scale.detail)。")

        let detailOverCardDetail = Scale.detail >= Scale.cardDetail
        #expect(
            detailOverCardDetail,
            "细节 \(Scale.detail) 小于设备卡说明行 \(Scale.cardDetail)，最小的那一档跑到中间去了。")
    }

    /// 正文必须至少是系统菜单的默认字号 13pt。
    ///
    /// 这是 R-3 的原话（「字体稍微放大一些，目前太小了」）能被机器检查的那
    /// 一半：旧版正文散在 11–12pt，比系统菜单小一档；用户是拿它跟别的菜单
    /// 比出来的。低于 13 就等于回到那个状态。
    @Test("正文不小于系统菜单默认的 13pt")
    func bodyMatchesSystemMenuDefault() {
        let bigEnough = Scale.body >= 13
        #expect(
            bigEnough,
            """
            面板正文字号是 \(Scale.body)，小于系统菜单默认的 13pt。
            用户真机反馈「字体稍微放大一些，目前太小了」正是拿系统菜单
            比出来的（R-3）。
            """
        )
    }

    /// 面板里最小的**文字**字号不许回到 11 以下。
    ///
    /// 旧版有 10pt 的「上次转写」小标题和 10pt 的设备卡说明行——两处都是
    /// 灰字压 #1D1D1F 深底，是「太小了」这句反馈里最刺眼的两处。
    /// `glyph`（✓ 与 ›）不在此列：它们是 SF Symbol，不是要读的字。
    @Test("最小的文字字号不小于 11pt")
    func smallestTextIsAtLeast11() {
        let smallest = min(Scale.cardDetail, Scale.detail, Scale.secondary, Scale.body, Scale.header)
        let bigEnough = smallest >= 11
        #expect(
            bigEnough,
            """
            面板里最小的文字字号是 \(smallest)，小于 11pt。
            旧版那两处 10pt（「上次转写」小标题、设备卡说明行）是灰字压深底，
            正是 R-3 里最刺眼的两处，不许退回去。
            """
        )
    }

    // MARK: - R-2：底栏不再是最靠边的那一个

    /// 头部与底栏离面板边缘的距离，不许小于卡片里文字离面板边缘的距离。
    ///
    /// **这就是 R-2 的整个判断依据。** 底栏横向从来不缺地方（离屏实测：
    /// 300 宽的面板里底栏只要 102pt），它与面板里其他所有文字的唯一区别是
    /// 离边更近——卡片外边距 12 + 卡内边距 8 = 20pt，而头部/底栏原来直接
    /// 写 14pt。宿主窗口的圆角与内缩吃掉的正是最外面那几点，于是整块面板
    /// 里只有底栏（和头部最右那两个字）会被啃掉一角。
    ///
    /// 把这条写成断言而不是注释：14 这个数字是「随手写的合理值」，正是
    /// 以后重构会顺手写回去的那种。
    @Test("头部与底栏不比卡片内文字更靠边")
    func edgeGutterIsNotTighterThanCardContent() {
        // 卡片：外边距 12（`.padding(.horizontal, 12)`）+ 卡内边距 8（`.padding(8)`）
        let cardTextInset: CGFloat = 12 + 8
        let notTighter = MenuPanelView.edgeGutter >= cardTextInset
        #expect(
            notTighter,
            """
            头部/底栏的左右留白是 \(MenuPanelView.edgeGutter)，比卡片内文字的
            \(cardTextInset)pt 更靠边。整块面板里最先被宿主窗口圆角/内缩啃掉的
            就是它——用户真机实测底栏两个按钮「显示不全」（R-2）。
            """
        )
    }

    /// 常量光对还不够——头部和底栏必须真的用它。
    ///
    /// 上一条断的是 `edgeGutter` 这个数；这一条断的是「有人把底栏改回写死
    /// 的 14，而常量原封不动地留在那里」——那样上一条照样绿，而用户看到的
    /// 还是被啃掉一角的底栏。两处（头部、底栏）各一次，少一处就红。
    @Test("头部与底栏真的在用 edgeGutter")
    func headerAndFooterUseTheGutterConstant() throws {
        let source = try MenuPanelViewWiringTests.codeOnly(
            MenuPanelViewWiringTests.source("Sources/vInput/UI/MenuPanelView.swift"))
        let uses = source.components(separatedBy: "leading: Self.edgeGutter").count - 1
        #expect(
            uses == 2,
            """
            MenuPanelView 里用到 Self.edgeGutter 的地方是 \(uses) 处，不是 2 处
            （头部一处、底栏一处）。少一处就意味着那一处又写回了贴边的字面量，
            而 edgeGutter 常量本身还是对的——上面那条断言察觉不到。
            """
        )
    }

    /// 面板宽度要放得下最长的那一行设置值。
    ///
    /// 算式（13pt 行标题 + 12pt 当前值，中日文字形按 1.0 em、拉丁字形按
    /// 0.55 em 估）：最长的一行是「翻译后端」+「云端（缺 API key，未生效）」
    ///
    ///     行标题 4 字 × 13            = 52
    ///     当前值 9 个全角 × 12         = 108
    ///     当前值 " API key" 8 字 × 6.6 ≈ 53
    ///     Spacer 最小 8 + › 约 12 + 间距 6 = 26
    ///     行内左右各 10                = 20
    ///     合计                        ≈ 259
    ///
    /// 加上设置卡自己的左右外边距 12×2 = 24，面板至少要 283pt 才不截断。
    /// 300 只剩 17pt 余量（且设备卡的说明行会折成两行），320 留 37pt。
    @Test("面板宽度放得下最长的设置行")
    func panelIsWideEnoughForLongestRow() {
        let longestRow: CGFloat = 259
        let settingsCardMargins: CGFloat = 12 * 2
        let required = longestRow + settingsCardMargins
        let wideEnough = MenuPanelView.panelWidth >= required
        #expect(
            wideEnough,
            """
            面板宽 \(MenuPanelView.panelWidth)，放不下最长的设置行（约 \(required)pt：
            「翻译后端」+「云端（缺 API key，未生效）」在 13/12pt 下）。
            窄了的表现是当前值被 truncationMode(.tail) 悄悄截掉后半句，
            而「（缺 API key，未生效）」正是那半句。
            """
        )
    }
}

// MARK: - 高度：离屏渲染真量，不估

/// 面板到底有多高——**量出来的**。
///
/// # 为什么必须量
///
/// `.window` 面板不滚动：超出屏幕的部分够不到，而作者的屏幕大，怎么点都撞
/// 不上。13 寸的可用高度约 850pt（菜单栏下沿到屏幕底），这是整块面板唯一
/// 会真正伤到人的排版指标。
///
/// R-3 那次的估算偏了 50pt（估 666、实测 719），所以这一批不再写估算值：
/// `NSHostingView` 在测试进程里能布局（没有窗口服务器也行），
/// `MenuPanelView(model:initiallyOpen:)` 的第二个参数就是为这几条用例开的。
///
/// # 这里量不到什么（都会抬高真机上的数字）
///
/// 四样东西在测试进程里摆不出来，它们的状态全是 `private(set)`、
/// 只能由真设备/真会话写进去：
///
/// - **设备卡**（遥控器/鼠标连上时）：一行卡片 + 下边距。
/// - **上次转写卡**：最多两行正文 + 标题行。
/// - **模型列表里的条目**：这里 `availableModels` 是空的（`modelRoot` 没解析），
///   真机上每个模型一行。
/// - **云端后端展开 + 嵌套的「选择模型」也展开**：`useCloudBackend()` 要
///   协调器（`bootstrap()` 才有），这里切不过去，量到的是本机档。
///   R-3 实测的 719pt 就是那一档（且含设备卡与上次转写）。
///
/// 所以下面断言的是**能量到的那部分**要留足余量，剩下的余量给上面四样。
/// 真机目检仍在 Task 9 的清单上，但现在它去核对的是一个具体数字。
@MainActor
@Suite("菜单面板高度（离屏实测）")
struct MenuPanelHeightTests {
    /// 13 寸屏（1440×900 缩放档）菜单栏下沿到屏幕底部的可用高度，约 850pt。
    /// 这个数字来自 R-3 那次实测，本批沿用。
    static let available: CGFloat = 850

    /// 能量到的那部分的预算。
    ///
    /// 850 − 640 = 210pt 留给上面列的四样量不到的东西（设备卡约 52、
    /// 上次转写约 60、模型列表 1–3 行约 22–66、云端嵌套若干）。
    /// 手风琴保证**一次只开一行**，所以「高级展开」与「云端嵌套展开」
    /// 不会同时发生——这条预算是按前者算的。
    static let budget: CGFloat = 640

    private func height(_ view: MenuPanelView) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// 本批新增的「高级」是**最深的那一行**（本机档下），这件事要写下来。
    ///
    /// 2026-08-22 实测（离屏，`fittingSize`）：
    /// 收起 310、模型 363、校正 339、输出语言 459、翻译后端（本机）476、
    /// **高级 511**。也就是说本批把「最深一档」从 476 抬到了 511。
    @Test("高级是本机档下最深的一行，且各行深度符合实测")
    func advancedIsTheDeepestRow() {
        let model = AppModel()
        let base = height(MenuPanelView(model: model))
        let advanced = height(MenuPanelView(model: model, initiallyOpen: .advanced))
        let others = [
            MenuPanelView.SettingRow.model, .correction, .inputLanguage, .outputLanguage, .backend,
        ].map { height(MenuPanelView(model: model, initiallyOpen: $0)) }

        let deepest = others.allSatisfy { advanced >= $0 }
        #expect(
            deepest,
            """
            「高级」不再是最深的一行（高级 \(advanced)，其余 \(others)）。
            这不是错，但**最深一档变了就得重新量一次**：面板不滚动，
            13 寸屏的可用高度只有约 \(Self.available)pt。
            """
        )
        // 收起态也钉一下：多一行设置行的代价（约 35pt）不该悄悄膨胀。
        let collapsedIsSane = base < 400
        #expect(collapsedIsSane, "收起态已经 \(base)pt 了，比实测的 310 高出一大截。")
    }

    /// **最坏的可构造情形**：高级展开 + 两行在飞状态（正在下载 + 待启用）。
    ///
    /// 2026-08-22 实测 585pt。两行状态卡本身要 74pt（下载那行 41、
    /// 待启用那行 56——模型名 39 个字符会折到第三行；名字换成 5 个字符时
    /// 是 41）。这一格是本批新加的，且**叠在任何展开行之上**。
    @Test("最坏的可构造高度留得下量不到的那几样")
    func worstConstructibleDepthFitsWithMarginForTheUnmeasurable() {
        let model = AppModel()
        model.reportModelDownload(progress: 0.42)
        _ = model.modelAdoption.request(
            folder: "/Users/x/Library/Application Support/vInput/\(ModelDownloader.variant)",
            canSwitchNow: false)
        model.syncPendingModelMirror()

        let worst = height(MenuPanelView(model: model, initiallyOpen: .advanced))
        #expect(
            worst <= Self.budget,
            """
            最坏的可构造高度 \(worst)pt 超了预算 \(Self.budget)pt。
            预算不是屏幕高度（约 \(Self.available)pt）——差额留给测试进程里
            摆不出来的四样：设备卡、上次转写、模型列表条目、云端嵌套。
            超了就意味着真机上那几样叠上来会够不到面板底部，而面板不滚动。
            """
        )
    }

    /// 两行在飞状态的代价单独钉一条。
    ///
    /// 它们的文案随时可能被改长（`MenuPanelModel.downloadLine` /
    /// `pendingModelLine`），而 `infoLine` 是**不截断、只长高**的
    /// （`.fixedSize(horizontal: false, vertical: true)`）——多写一句话就是
    /// 多两行高度，且没有任何东西会提醒你。实测 74pt。
    @Test("在飞状态那一格的高度代价不超过 90pt")
    func downloadStatusCardStaysCheap() {
        let model = AppModel()
        let without = height(MenuPanelView(model: model))
        model.reportModelDownload(progress: 0.42)
        _ = model.modelAdoption.request(
            folder: "/Users/x/Library/Application Support/vInput/\(ModelDownloader.variant)",
            canSwitchNow: false)
        model.syncPendingModelMirror()
        let with = height(MenuPanelView(model: model))

        let cost = with - without
        #expect(
            cost <= 90,
            """
            在飞状态那一格要 \(cost)pt（实测基线 74）。文案改长了？
            infoLine 不截断、只长高，这一格又叠在任何展开行之上——
            它涨多少，最坏情况就跟着涨多少。
            """
        )
        // 反向：它必须真的占了地方，否则这条测试是空的。
        #expect(cost > 0, "两行状态一点高度都没占——多半是根本没渲染出来。")
    }
}
