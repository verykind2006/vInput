import Testing
@testable import vInput

struct MenuPanelModelTests {
    // MARK: 设备卡：连谁显示谁

    @Test func noDevicesMeansNoCards() {
        let cards = MenuPanelModel.deviceCards(
            remote: .disconnected, remoteBattery: nil,
            mouseEnabled: true, mouse: .stopped, mouseBattery: nil)
        #expect(cards.isEmpty)
    }

    /// 搜索中/连接中等过渡态不出卡——「连谁显示谁」，没连上就不算。
    @Test func transientStatesShowNothing() {
        #expect(MenuPanelModel.deviceCards(
            remote: .scanning, remoteBattery: nil,
            mouseEnabled: true, mouse: .searching, mouseBattery: nil).isEmpty)
    }

    @Test func remoteOnlyShowsOneCard() {
        let cards = MenuPanelModel.deviceCards(
            remote: .connected, remoteBattery: 78,
            mouseEnabled: true, mouse: .stopped, mouseBattery: nil)
        #expect(cards.count == 1)
        #expect(cards[0].kind == .remote)
        #expect(cards[0].title == "遥控器")
        #expect(cards[0].detail == "电量 78%")
        #expect(cards[0].tone == .ok)
    }

    /// 电量未知（刚连上、还没读到电量特征）是遥控器的常态开局，不该拼出
    /// 「电量 nil%」这种字符串——退回「已连接」。
    @Test func remoteBatteryUnknownShowsConnectedOnly() {
        let cards = MenuPanelModel.deviceCards(
            remote: .connected, remoteBattery: nil,
            mouseEnabled: true, mouse: .stopped, mouseBattery: nil)
        #expect(cards.count == 1)
        #expect(cards[0].detail == "已连接")
    }

    @Test func bothConnectedShowsTwoCardsRemoteFirst() {
        let cards = MenuPanelModel.deviceCards(
            remote: .connected, remoteBattery: 78,
            mouseEnabled: true, mouse: .ready("iMouse"), mouseBattery: 65)
        #expect(cards.count == 2)
        #expect(cards[0].kind == .remote)
        #expect(cards[0].title == "遥控器")
        #expect(cards[1].kind == .mouse)
        #expect(cards[1].title == "鼠标")
        #expect(cards[1].detail == "电量 65%")
        #expect(cards[1].tone == .ok)
    }

    @Test func mouseDisabledNeverShowsMouseCard() {
        let cards = MenuPanelModel.deviceCards(
            remote: .disconnected, remoteBattery: nil,
            mouseEnabled: false, mouse: .ready("iMouse"), mouseBattery: 65)
        #expect(cards.isEmpty)
    }

    /// **`.muted` 必须出卡且带警示**——2026-08-18 那次 11 分钟环境音事故
    /// 正是靠菜单栏可见性发现的，隐藏它等于把那个教训删了。
    @Test func mutedMouseStaysVisibleAsWarning() {
        let cards = MenuPanelModel.deviceCards(
            remote: .disconnected, remoteBattery: nil,
            mouseEnabled: true, mouse: .muted(30), mouseBattery: nil)
        #expect(cards.count == 1)
        #expect(cards[0].kind == .mouse)
        #expect(cards[0].title == "鼠标")
        #expect(cards[0].tone == .error)
    }

    /// `.muted` 卡的文案必须复用 `MouseBridgeState.detailLabel(battery:)`——
    /// 不带「鼠标：」前缀的那一半，因为卡片 title 已经是「鼠标」，重复前缀
    /// 会把这张卡的一行文字撑成两行、跟旁边的卡高度对不齐（QA 复核
    /// 2026-08-21 抓到的真实渲染问题：「鼠标 / 鼠标：已超时静音，30 秒后
    /// 恢复」）。
    ///
    /// 断言点钉的是 `detailLabel(battery:)` 对 `.muted(30)` 真实吐出来的
    /// 那句话里的一段独有子串（"已超时静音"），读的是
    /// `Sources/vInput/Mouse/MouseBluetoothBridge.swift` 的真实实现；另外
    /// 明确断言 detail 里不含「鼠标：」，堵死「不小心又拼回 menuLabel」的
    /// 回归。
    @Test func mutedCardDetailComesFromDetailLabel() {
        let cards = MenuPanelModel.deviceCards(
            remote: .disconnected, remoteBattery: nil,
            mouseEnabled: true, mouse: .muted(30), mouseBattery: nil)
        #expect(cards.count == 1)
        #expect(cards[0].detail == MouseBridgeState.muted(30).detailLabel(battery: nil))
        #expect(cards[0].detail.contains("已超时静音"))
        #expect(!cards[0].detail.contains("鼠标："))
    }

    // MARK: 头部状态行（文案零增减：与旧 MenuContent.statusText 逐字相同）

    @Test func headerCopiesAreUnchanged() {
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: "qwen", phase: .idle, permission: .ready
        ) == .init(text: "正在加载模型 qwen…首次可能需要一两分钟", tone: .busy))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .idle, permission: .ready
        ) == .init(text: "就绪", tone: .ok))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .idle, permission: .microphoneMissing
        ) == .init(text: "需要麦克风权限", tone: .error))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .idle, permission: .accessibilityMissing
        ) == .init(text: "需要辅助功能权限", tone: .error))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .listening, permission: .ready
        ) == .init(text: "正在聆听…", tone: .recording))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .working, permission: .ready
        ) == .init(text: "正在转写…", tone: .busy))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .error("坏了"), permission: .ready
        ) == .init(text: "出错：坏了", tone: .error))
    }

    /// 加载中要短路**每一个** phase，不只是 `.idle`。
    ///
    /// 补这条的由来：`headerCopiesAreUnchanged` 里唯一带 loading 的用例
    /// phase 恰好是 `.idle`，于是「把 loading 判断挪进 `.idle` 分支内部」
    /// 这个变异压不中任何断言——短路契约实际上没被钉住。照
    /// `StatusIconTests.loadingOverridesEverything` 的写法补齐三个 phase。
    @Test func loadingOverridesEveryPhase() {
        let loading = MenuPanelModel.HeaderStatus(
            text: "正在加载模型 qwen…首次可能需要一两分钟", tone: .busy)
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: "qwen", phase: .idle, permission: .ready) == loading)
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: "qwen", phase: .listening, permission: .ready) == loading)
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: "qwen", phase: .working, permission: .ready) == loading)
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: "qwen", phase: .error("x"), permission: .ready) == loading)
    }

    /// 绊线测试：`HUDViewModel.statusLabel`（源 `DictationSession.State`）
    /// 与 `MenuPanelModel.headerStatus`（源 `AppModel.Phase`）在「聆听」
    /// 「转写」两处的措辞**故意**只差一个省略号——`AppModel` 把校正/翻译/
    /// 输入等好几个处理态全并成一个 `.working`，菜单栏只能笼统地说
    /// 「正在转写…」；`DictationSession.State` 则必须逐一区分校正/翻译，
    /// HUD 用的是不带省略号的「正在转写」「正在校正」……
    ///
    /// 这条测试钉的不是「两边永远一致」，而是「这份有意的分歧长什么样」：
    /// 任何一边改了文案——哪怕只是加/去一个省略号——这条测试就会红，
    /// 逼下一个动文案的人回来想一遍，这次的分歧还是不是「有意的」那个。
    @Test func headerAndHUDStayInSync() {
        // .idle：两边完全没有分歧——都是「就绪」，不带省略号。
        #expect(HUDViewModel.statusLabel(for: .idle, previewDegraded: false) == "就绪")
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .idle, permission: .ready
        ).text == "就绪")

        // .listening：菜单栏比 HUD 多一个省略号，这是唯一允许的差异。
        #expect(HUDViewModel.statusLabel(for: .listening, previewDegraded: false) == "正在聆听")
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .listening, permission: .ready
        ).text == "正在聆听" + "…")

        // AppModel 的 .working 对应 DictationSession 处理态里的 .transcribing
        // （四个处理态之一，菜单栏只能笼统概括）：同样只差一个省略号。
        #expect(HUDViewModel.statusLabel(for: .transcribing, previewDegraded: false) == "正在转写")
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .working, permission: .ready
        ).text == "正在转写" + "…")
    }
}
