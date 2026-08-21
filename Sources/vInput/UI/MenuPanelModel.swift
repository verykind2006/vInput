import Foundation

/// 菜单面板的展示逻辑。全部纯函数，视图只画（与 HUDViewModel 同一条分工）。
enum MenuPanelModel {
    /// 展示的语气。设备卡与头部状态行共用同一套——设备卡目前只会用到
    /// `.ok`（正常连接）与 `.error`（`.muted` 警示）两档，`.recording` /
    /// `.busy` 是头部状态行专用的。视图侧用同一个 `toneColor(_:)` 取色，
    /// 免得在视图里再手写一份颜色判断。
    enum Tone: Equatable { case ok, recording, busy, error }

    // MARK: - 设备卡

    struct DeviceCard: Equatable, Identifiable {
        /// 卡片对应哪个设备。**不用中文标题当身份**：`title` 目前恰好
        /// 「遥控器」与「鼠标」不同才让 `ForEach(cards, id: \.title)` 凑巧
        /// 能用，拿易变的展示文案当身份是个坑，所以另开一个稳定的 `kind`。
        enum Kind: Hashable { case remote, mouse }

        let kind: Kind
        var id: Kind { kind }
        let title: String
        let detail: String
        let tone: Tone
    }

    /// 连谁显示谁（用户 2026-08-20 定的：不是每台机器都同时连着两个设备）。
    /// 全断开 → 空数组，面板整块隐藏；内置麦是默认路径，不占卡。
    /// **遥控器在前**（视图按数组顺序摆）——顺序是契约，不是巧合。
    ///
    /// 例外：鼠标 `.muted` 出警示卡。2026-08-18 的 11 分钟环境音事故靠的
    /// 就是菜单栏可见性，「没连上就不显示」不适用于「被我们主动踢掉」。
    nonisolated static func deviceCards(
        remote: RemoteConnectionState,
        remoteBattery: Int?,
        mouseEnabled: Bool,
        mouse: MouseBridgeState,
        mouseBattery: Int?
    ) -> [DeviceCard] {
        var cards: [DeviceCard] = []
        if remote == .connected {
            cards.append(DeviceCard(
                kind: .remote, title: "遥控器", detail: batteryDetail(remoteBattery), tone: .ok))
        }
        if mouseEnabled {
            switch mouse {
            case .ready:
                cards.append(DeviceCard(
                    kind: .mouse, title: "鼠标", detail: batteryDetail(mouseBattery), tone: .ok))
            case .muted:
                // 文案复用 model 层现成的（被测试钉着的）detailLabel——不带
                // 「鼠标：」前缀那半截，title 已经是「鼠标」，不重复拼前缀。
                cards.append(DeviceCard(
                    kind: .mouse, title: "鼠标",
                    detail: mouse.detailLabel(battery: mouseBattery), tone: .error))
            case .stopped, .bluetoothUnavailable, .searching, .connecting,
                 .discovering, .reconnecting:
                break
            }
        }
        return cards
    }

    private nonisolated static func batteryDetail(_ battery: Int?) -> String {
        battery.map { "电量 \($0)%" } ?? "已连接"
    }

    // MARK: - 随状态变的文案

    // 下面五条都是「同一个控件按状态说两句话」。搬进 model 层的理由是
    // 一次真事故：迁移时「重试上次转写（没有可重试的）」在视图里被改成
    // 纯置灰的「重试 ↻」，禁用理由整句丢失，全仓 1121 条测试一条没红
    // （1a0989b 才补回来）。文案留在视图里就没有任何东西守得住它。
    //
    // **文案逐字照搬旧 `MenuContent`，一个字都不许改。**

    /// 主按钮：听写中说「结束」，其余一律「开始」。
    ///
    /// 判据是 `.listening` 而不是「非 idle」：`.working`（正在转写）时按钮
    /// 说「开始听写」是对的——那一刻确实可以再开一段。
    nonisolated static func primaryButtonTitle(phase: AppModel.Phase) -> String {
        phase == .listening ? "结束听写" : "开始听写"
    }

    /// 重试：禁用时把「为什么点不动」写进文案。
    ///
    /// 只置灰的话，用户分不清是「没有可重试的」还是「坏了」——这与旧菜单
    /// 「禁用而不隐藏」是同一条道理（时有时无的话用户根本不知道有这么个
    /// 东西），而括号里那半句是那条道理在文案上的落点。
    nonisolated static func retryTitle(canRetry: Bool) -> String {
        canRetry ? "重试 ↻" : "重试 ↻（没有可重试的）"
    }

    /// 校正开关按钮。说的是**按下去会发生什么**，不是当前状态
    /// （当前状态在设置行右侧的「开 / 关」上）。
    nonisolated static func correctionToggleTitle(enabled: Bool) -> String {
        enabled ? "关闭校正" : "开启校正"
    }

    /// 校正模型那一行。
    ///
    /// 让用户知道当前用的是哪个模型——校正效果好坏几乎全由它决定。
    /// 未指定时不再说「默认（首次使用时下载）」：开启校正现在必须先有一个
    /// 本地合法目录，那句话会让人以为不选也能用。
    ///
    /// 与 `AppModel.translationModelMenuLine` / `cloudModelMenuLine` 对齐：
    /// 三行「模型：…」全部由纯函数算出，没道理只有这一行在视图里插值拼。
    nonisolated static func correctionModelLine(name: String?) -> String {
        name.map { "模型：\($0)" } ?? "模型：未指定（开启校正时选择）"
    }

    /// API Key 那个按钮：有 key 是「更换」，没有是「输入」。
    ///
    /// 文案区分这两档不是修辞：已存了 key 的人点「输入」会以为自己在新增，
    /// 而实际是覆盖（`TranslationKey.write` 是写同一个 Keychain 条目）。
    nonisolated static func apiKeyButtonTitle(hasKey: Bool) -> String {
        hasKey ? "更换 API Key…" : "输入 API Key…"
    }

    // MARK: - 在飞的下载 / 待启用的模型

    /// 「正在下载模型 42%」。`nil` 表示此刻没有下载在跑，那一行整个不出现。
    ///
    /// **这一行是本批补上的一个洞**：关掉向导**不会**取消下载（扔掉几百 MB
    /// 更糟），于是它变成一个完全看不见的后台任务——菜单栏图标的加载态说的
    /// 是「模型正在加载」，不是「正在下载」，两者差着十几分钟。用户看到的是
    /// 一个若无其事的面板，直到某一刻应用忽然自己进入加载态。
    ///
    /// 百分比走 `ModelDownloader.percentText`，与向导里那一处同一个函数：
    /// 两处各自 `Int(fraction * 100)` 的话，取整方式迟早一个 round 一个截断，
    /// 同一次下载在两个界面上显示成两个数。
    nonisolated static func downloadLine(progress: Double?) -> String? {
        guard let progress else { return nil }
        return "正在下载模型 \(ModelDownloader.percentText(progress))"
    }

    /// 「新模型已下载好（…），这次听写结束后自动启用」。
    ///
    /// 下载在录音/转写途中完成时，换模型会被 `canSwitchModel` 挡下来
    /// （挡是对的：换掉正在用的引擎更糟）。挡下来之后由
    /// `ModelAdoptionQueue` 记着、会话结束时补上——**而用户必须知道这件事
    /// 正在等**，否则他看到的是「下完了但菜单里还是老模型」，
    /// 与「下载失败了」在界面上长得一模一样。
    nonisolated static func pendingModelLine(folder: String?) -> String? {
        guard let folder else { return nil }
        let name = (folder as NSString).lastPathComponent
        return "新模型已下载好（\(name)），这次听写结束后自动启用"
    }

    // MARK: - 高级：储存位置与下载源

    /// 模型与缓存放在哪。**把家目录缩成 `~`**：面板只有 320pt 宽，
    /// 而 `/Users/<很长的用户名>/Library/…` 前半截对用户没有信息量。
    ///
    /// 根目录为空（bootstrap 还没跑完）时说「尚未确定」，不显示一个空行——
    /// 空行会让人以为「什么都没存」，而这一格存在的理由恰恰是让用户看见
    /// 那几个 GB 在哪。
    nonisolated static func storageLocationLine(root: String) -> String {
        guard !root.isEmpty else { return "位置：尚未确定" }
        return "位置：\((root as NSString).abbreviatingWithTildeInPath)"
    }

    /// 三选一里的每一项。
    ///
    /// 「自动」后面那半句不是装饰：不写的话，用户无从判断「自动」到底做了
    /// 什么，也就无从判断自己该不该去动它（真实机理是并发探测两个源、
    /// 谁先响应用谁，见 `DownloadSource.choose`）。
    nonisolated static func downloadSourceChoiceLabel(_ forced: DownloadSource?) -> String {
        guard let forced else { return "自动（两个源都探一下，谁快用谁）" }
        return "强制\(forced.displayName)"
    }

    // MARK: - 头部状态行

    struct HeaderStatus: Equatable {
        let text: String
        let tone: Tone
    }

    /// 文案与旧 MenuContent.statusText **逐字相同**（迁移守则：零增减），
    /// 搬到 model 层是为了让测试钉得住它。
    nonisolated static func headerStatus(
        loadingModelName: String?,
        phase: AppModel.Phase,
        permission: Permissions.Status
    ) -> HeaderStatus {
        if let loading = loadingModelName {
            return HeaderStatus(text: "正在加载模型 \(loading)…首次可能需要一两分钟", tone: .busy)
        }
        switch phase {
        case .idle:
            switch permission {
            case .ready: return HeaderStatus(text: "就绪", tone: .ok)
            case .microphoneMissing: return HeaderStatus(text: "需要麦克风权限", tone: .error)
            case .accessibilityMissing: return HeaderStatus(text: "需要辅助功能权限", tone: .error)
            }
        case .listening: return HeaderStatus(text: "正在聆听…", tone: .recording)
        case .working: return HeaderStatus(text: "正在转写…", tone: .busy)
        case .error(let message): return HeaderStatus(text: "出错：\(message)", tone: .error)
        }
    }
}
