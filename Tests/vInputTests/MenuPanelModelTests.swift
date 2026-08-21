import Foundation
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

    // MARK: 随状态变的文案（两句话的那几处）

    /// 主按钮：只有 `.listening` 说「结束」。
    ///
    /// `.working`（正在转写）也说「开始听写」是对的——那一刻确实可以再开
    /// 一段。四个 phase 全列，免得「把判断写成 != .idle」这种变异压不中。
    @Test func primaryButtonTitleSwitchesOnlyWhenListening() {
        #expect(MenuPanelModel.primaryButtonTitle(phase: .listening) == "结束听写")
        #expect(MenuPanelModel.primaryButtonTitle(phase: .idle) == "开始听写")
        #expect(MenuPanelModel.primaryButtonTitle(phase: .working) == "开始听写")
        #expect(MenuPanelModel.primaryButtonTitle(phase: .error("坏了")) == "开始听写")
    }

    /// 重试：**禁用那一句必须说出为什么点不动。**
    ///
    /// 这条是一次真事故的守卫：迁移时这两句话在视图里被并成一句「重试 ↻」，
    /// 括号那半截没了，全仓 1121 条测试一条没红（1a0989b 才补回来）。
    /// 括号原文逐字钉住——只置灰的话，用户分不清是「没有可重试的」还是
    /// 「坏了」。
    @Test func retryTitleSaysWhyItIsDisabled() {
        #expect(MenuPanelModel.retryTitle(canRetry: true) == "重试 ↻")
        #expect(MenuPanelModel.retryTitle(canRetry: false) == "重试 ↻（没有可重试的）")
    }

    /// 校正开关说的是**按下去会发生什么**，不是当前状态
    /// （当前状态在设置行右侧的「开 / 关」上）。写反了的话，
    /// 一个开着校正的人会看到「开启校正」，点一下把它关了。
    @Test func correctionToggleTitleDescribesTheAction() {
        #expect(MenuPanelModel.correctionToggleTitle(enabled: true) == "关闭校正")
        #expect(MenuPanelModel.correctionToggleTitle(enabled: false) == "开启校正")
    }

    /// 校正模型那一行。未指定时**不许**说成「默认（首次使用时下载）」：
    /// 开启校正现在必须先有一个本地合法目录，那句话会让人以为不选也能用。
    @Test func correctionModelLineTellsWhenUnset() {
        #expect(MenuPanelModel.correctionModelLine(name: "qwen3-4b") == "模型：qwen3-4b")
        #expect(
            MenuPanelModel.correctionModelLine(name: nil)
                == "模型：未指定（开启校正时选择）")
    }

    /// API Key 按钮：有 key 是「更换」不是「输入」。
    /// 写反的后果不是措辞问题——已存 key 的人点「输入」会以为在新增，
    /// 而 `TranslationKey.write` 写的是同一个 Keychain 条目，是覆盖。
    @Test func apiKeyButtonTitleDistinguishesReplaceFromEnter() {
        #expect(MenuPanelModel.apiKeyButtonTitle(hasKey: true) == "更换 API Key…")
        #expect(MenuPanelModel.apiKeyButtonTitle(hasKey: false) == "输入 API Key…")
    }

    // MARK: 头部状态行（文案零增减：与旧 MenuContent.statusText 逐字相同）

    @Test func headerCopiesAreUnchanged() {
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: "qwen", phase: .idle, permission: .ready, hasModel: true
        ) == .init(text: "正在加载模型 qwen…首次可能需要一两分钟", tone: .busy))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .idle, permission: .ready, hasModel: true
        ) == .init(text: "就绪", tone: .ok))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .idle, permission: .microphoneMissing,
            hasModel: true
        ) == .init(text: "需要麦克风权限", tone: .error))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .idle, permission: .accessibilityMissing,
            hasModel: true
        ) == .init(text: "需要辅助功能权限", tone: .error))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .listening, permission: .ready, hasModel: true
        ) == .init(text: "正在聆听…", tone: .recording))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .working, permission: .ready, hasModel: true
        ) == .init(text: "正在转写…", tone: .busy))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .error("坏了"), permission: .ready, hasModel: true
        ) == .init(text: "出错：坏了", tone: .error))
    }

    /// **零模型时不许说「就绪」。**
    ///
    /// 这是本批最贵的一句谎。失效链是完整的：向导下载失败 → 用户关掉向导 →
    /// 面板一个绿点加「就绪」 → 她按下「开始听写」 → 一个她没要过的 140MB
    /// 模型从官方源开始下（忽略她刚被指定的源），头部还写着「正在加载模型…」。
    /// 头部原先只认识 `loadingModelName` / `phase` / `permission` 三样，
    /// 它们在零模型时全都是「一切正常」的取值。
    @Test func zeroModelsIsNotReady() {
        let noModel = MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .idle, permission: .ready, hasModel: false)
        #expect(noModel == .init(text: "还没有语音模型", tone: .error))

        // 有模型时那句话必须消失——否则「永远说没有模型」也能过上面那条。
        let ready = MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .idle, permission: .ready, hasModel: true)
        #expect(ready == .init(text: "就绪", tone: .ok))
    }

    /// 权限那两句排在缺模型之前，且**缺模型不许把它们盖掉**。
    ///
    /// 顺序是有意的：权限更早、也更可操作（点一下就去系统设置了），
    /// 而这两件事在第一次启动时同时为真的概率很高——向导没走完就被关掉，
    /// 既没给权限也没有模型。
    @Test func permissionOutranksMissingModel() {
        let micFirst = MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .idle, permission: .microphoneMissing,
            hasModel: false)
        #expect(micFirst == .init(text: "需要麦克风权限", tone: .error))

        let axFirst = MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .idle, permission: .accessibilityMissing,
            hasModel: false)
        #expect(axFirst == .init(text: "需要辅助功能权限", tone: .error))
    }

    /// 缺模型只管 `.idle` 那一格，别的 phase 一个都不许被它顶掉。
    ///
    /// 补这条的由来与 `loadingOverridesEveryPhase` 同源：把 `hasModel` 判断
    /// 提到 `switch phase` 外面是个很自然的写法，而那样写的话，
    /// 「正在加载模型…」和「出错：…」会在零模型时全变成「还没有语音模型」
    /// ——用户永远看不到真正的错误原因。
    @Test func missingModelDoesNotSwallowOtherPhases() {
        #expect(
            MenuPanelModel.headerStatus(
                loadingModelName: "turbo", phase: .idle, permission: .ready, hasModel: false)
                == .init(text: "正在加载模型 turbo…首次可能需要一两分钟", tone: .busy))
        #expect(
            MenuPanelModel.headerStatus(
                loadingModelName: nil, phase: .listening, permission: .ready, hasModel: false)
                == .init(text: "正在聆听…", tone: .recording))
        #expect(
            MenuPanelModel.headerStatus(
                loadingModelName: nil, phase: .working, permission: .ready, hasModel: false)
                == .init(text: "正在转写…", tone: .busy))
        #expect(
            MenuPanelModel.headerStatus(
                loadingModelName: nil, phase: .error("坏了"), permission: .ready,
                hasModel: false)
                == .init(text: "出错：坏了", tone: .error))
    }

    /// 空模型列表那一行**不许再提 `vendor/models`**。
    ///
    /// 那是开发机上的仓库路径；这一批已经把模型搬到应用支持目录了。
    /// 而读到这句话的人，恰恰是此刻一个模型都没有的那个新用户——
    /// 给她一个她机器上根本不存在的目录名，等于没说。
    @Test func emptyModelListDoesNotMentionTheDeveloperPath() {
        let line = MenuPanelModel.emptyModelListLine
        #expect(line == "还没有模型（下载完成后出现在这里）")
        let mentionsRepoPath = line.contains("vendor")
        #expect(mentionsRepoPath == false, "空列表提示又提到了开发机才有的 vendor/models：\(line)")
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
            loadingModelName: "qwen", phase: .idle, permission: .ready,
            hasModel: true) == loading)
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: "qwen", phase: .listening, permission: .ready,
            hasModel: true) == loading)
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: "qwen", phase: .working, permission: .ready,
            hasModel: true) == loading)
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: "qwen", phase: .error("x"), permission: .ready,
            hasModel: true) == loading)
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
            loadingModelName: nil, phase: .idle, permission: .ready, hasModel: true
        ).text == "就绪")

        // .listening：菜单栏比 HUD 多一个省略号，这是唯一允许的差异。
        #expect(HUDViewModel.statusLabel(for: .listening, previewDegraded: false) == "正在聆听")
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .listening, permission: .ready, hasModel: true
        ).text == "正在聆听" + "…")

        // AppModel 的 .working 对应 DictationSession 处理态里的 .transcribing
        // （四个处理态之一，菜单栏只能笼统概括）：同样只差一个省略号。
        #expect(HUDViewModel.statusLabel(for: .transcribing, previewDegraded: false) == "正在转写")
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .working, permission: .ready, hasModel: true
        ).text == "正在转写" + "…")
    }

    // MARK: - 在飞的下载 / 待启用的模型

    /// 没有下载在跑时那一行整个不出现（nil，不是空字符串）。
    ///
    /// 空字符串会在面板上留一条看不见的空行，而这一格的位置就在主按钮下面。
    @Test func noDownloadMeansNoLine() {
        #expect(MenuPanelModel.downloadLine(progress: nil) == nil)
    }

    /// 百分比走 `ModelDownloader.percentText`，与向导里是同一个函数。
    ///
    /// 不断言「42%」这个字面量，而断言两处**算出来的是同一个串**：
    /// 各写一份取整的话，迟早一个 round 一个截断，同一次下载在两个界面上
    /// 显示成两个数字。
    @Test func downloadLineUsesTheSharedPercentFormatter() {
        let line = MenuPanelModel.downloadLine(progress: 0.4242)
        #expect(line == "正在下载模型 \(ModelDownloader.percentText(0.4242))")
        #expect(line?.contains("42%") == true)
    }

    /// 刚开始下（0%）也要出现这一行：探测那几秒里面板上必须有话说，
    /// 否则用户看到「什么都没发生」，然后忽然从 30% 开始。
    @Test func zeroProgressStillShowsTheLine() {
        #expect(MenuPanelModel.downloadLine(progress: 0) == "正在下载模型 0%")
    }

    /// 没有待启用的模型时不出现。
    @Test func noPendingModelMeansNoLine() {
        #expect(MenuPanelModel.pendingModelLine(folder: nil) == nil)
    }

    /// 待启用那句话要说清**两件事**：已经下好了、以及什么时候会生效。
    ///
    /// 只说「已下载」的话，用户看到的是「下完了但菜单里还是老模型」，
    /// 与「下载失败了」在界面上长得一模一样。
    @Test func pendingModelLineSaysWhenItWillTakeEffect() {
        let line = MenuPanelModel.pendingModelLine(
            folder: "/Users/x/Library/Application Support/vInput/openai_whisper-large-v3")
        let namesTheModel = line?.contains("openai_whisper-large-v3") == true
        #expect(namesTheModel, "待启用那行没说是哪个模型：\(line ?? "nil")")
        let saysWhen = line?.contains("结束") == true && line?.contains("自动启用") == true
        #expect(saysWhen, "待启用那行没说什么时候生效：\(line ?? "nil")")
        // 只放最后一段路径：面板 320pt 宽，整条绝对路径会挤成三行。
        let dropsThePath = line?.contains("/Users/x") == false
        #expect(dropsThePath)
    }

    // MARK: - 高级：储存位置与下载源

    /// 家目录缩成 `~`：面板只有 320pt 宽，前半截对用户没有信息量。
    @Test func storageLocationAbbreviatesHome() {
        let root = NSHomeDirectory() + "/Library/Application Support/vInput"
        let line = MenuPanelModel.storageLocationLine(root: root, exists: { _ in true })
        #expect(line == "位置：~/Library/Application Support/vInput")
    }

    /// 还没解析出根目录时说「尚未确定」，不留空行——空行会让人以为
    /// 「什么都没存」，而这一格存在的理由恰恰是让用户看见那几个 GB 在哪。
    @Test func emptyRootSaysSo() {
        let line = MenuPanelModel.storageLocationLine(root: "", exists: { _ in true })
        #expect(line.contains("尚未确定"))
        #expect(!line.hasSuffix("："))
    }

    /// **目录还没建时必须明说。** 首次下载之前 `resolveRoot` 照样返回那个
    /// 路径，用户点「在访达中显示」只会看到上级目录——而他刚在这行读到
    /// 「位置：~/Library/…」。不写这半句的话，那一下就像是按钮坏了。
    @Test func storageLocationSaysWhenFolderIsNotThereYet() {
        let line = MenuPanelModel.storageLocationLine(
            root: "/Users/x/Library/Application Support/vInput", exists: { _ in false })
        let warns = line.contains("还没建")
        #expect(warns, "目录不存在却没说：\(line)")
        // 路径本身仍然要给全——「将来会出现在哪」是这一行的主要信息。
        #expect(line.contains("Library/Application Support/vInput"))
    }

    // MARK: - 在访达中显示：目录还不存在时退到最近的祖先

    @Test func revealTargetIsTheFolderItselfWhenItExists() {
        let root = "/Users/x/Library/Application Support/vInput"
        #expect(MenuPanelModel.revealTarget(root: root, exists: { _ in true }) == root)
    }

    /// 首次下载之前的常态：目标不存在，退到最近一个存在的祖先。
    ///
    /// Finder 拿到不存在的路径是**静默无反应**的，而静默无反应与「这个按钮
    /// 坏了」在用户那里分不开。
    @Test func revealTargetFallsBackToNearestExistingAncestor() {
        let existing = "/Users/x/Library"
        let target = MenuPanelModel.revealTarget(
            root: "/Users/x/Library/Application Support/vInput",
            exists: { $0 == existing })
        #expect(target == existing)
    }

    /// 一个祖先都不存在（外接盘拔了、家目录换了）时返回 nil，
    /// 由调用方什么都不做——总比把 Finder 打开在一个莫名其妙的地方好。
    @Test func revealTargetGivesUpWhenNothingExists() {
        #expect(
            MenuPanelModel.revealTarget(
                root: "/Volumes/gone/vInput", exists: { _ in false }) == nil)
        #expect(MenuPanelModel.revealTarget(root: "", exists: { _ in true }) == nil)
    }

    /// 「自动」那一项必须说清它做了什么，否则用户无从判断该不该去动它。
    @Test func automaticChoiceExplainsItself() {
        let label = MenuPanelModel.downloadSourceChoiceLabel(nil)
        #expect(label.hasPrefix("自动"))
        let explains = label.contains("快")
        #expect(explains, "「自动」那一项没解释它是怎么选的：\(label)")
    }

    /// 三项文案两两不同——重复的话勾选在哪一项上就看不出来了。
    @Test func downloadSourceChoicesAreDistinct() {
        let labels = [
            MenuPanelModel.downloadSourceChoiceLabel(nil),
            MenuPanelModel.downloadSourceChoiceLabel(.official),
            MenuPanelModel.downloadSourceChoiceLabel(.mirror),
        ]
        #expect(Set(labels).count == 3, "下载源三项文案有重复：\(labels)")
    }
}
