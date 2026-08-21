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
        #expect(cards[0].title == "遥控器")
        #expect(cards[0].detail.contains("78"))
        #expect(!cards[0].warning)
    }

    @Test func bothConnectedShowsTwoCardsRemoteFirst() {
        let cards = MenuPanelModel.deviceCards(
            remote: .connected, remoteBattery: 78,
            mouseEnabled: true, mouse: .ready("iMouse"), mouseBattery: 65)
        #expect(cards.count == 2)
        #expect(cards[0].title == "遥控器")
        #expect(cards[1].title == "鼠标")
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
        #expect(cards[0].title == "鼠标")
        #expect(cards[0].warning)
    }

    /// `.muted` 卡的文案必须复用 `MouseBridgeState.menuLabel(battery:)`，
    /// 不能在 model 层另拼一份字符串——那份措辞已经被
    /// `MouseBluetoothBridgeTests` 之类的测试钉住，改一处两处都要同步。
    /// 断言点钉的是 `menuLabel(battery:)` 对 `.muted(30)` 真实吐出来的
    /// 那句话里的一段独有子串（"已超时静音"），读的是
    /// `Sources/vInput/Mouse/MouseBluetoothBridge.swift` 的真实实现。
    @Test func mutedCardDetailComesFromMenuLabel() {
        let cards = MenuPanelModel.deviceCards(
            remote: .disconnected, remoteBattery: nil,
            mouseEnabled: true, mouse: .muted(30), mouseBattery: nil)
        #expect(cards.count == 1)
        #expect(!cards[0].detail.isEmpty)
        #expect(cards[0].detail == MouseBridgeState.muted(30).menuLabel(battery: nil))
        #expect(cards[0].detail.contains("已超时静音"))
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
}
