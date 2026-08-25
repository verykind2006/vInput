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
    /// （当前状态在设置行右侧的值上，见 `correctionRowValue`）。
    nonisolated static func correctionToggleTitle(enabled: Bool) -> String {
        enabled ? "关闭校正" : "开启校正"
    }

    /// 校正设置行右侧的当前值。
    ///
    /// **非中文输入下不许显示「开」**：那时管线已被 `makeCorrectionPipeline`
    /// 的语言门摘掉，偏好里的「开」一个字都不会生效——收起态还写「开」
    /// 与「云端：开（其实没在译）」同构，显示与行为不一致就是在骗人
    /// （`AppModel.translationBackendStatus` 记着同一条原则）。展开区里的
    /// 整句解释走 `AppModel.correctionUnavailableNote`，这里只给收起态的短值。
    nonisolated static func correctionRowValue(enabled: Bool, input: Language) -> String {
        guard input == .chinese else { return "不可用（非中文输入）" }
        return enabled ? "开" : "关"
    }

    /// 输出语言区「不翻译」那一格的文案。括号里写**当前输入语言**——
    /// 「保持中文原样」和「保持英文原样」是两句不同的承诺，写死一个就会
    /// 在另一种输入下撒谎。随状态变的文案不在视图里拼（与本文件其余
    /// 纯函数同一条分工），拼在视图里就没有任何测试守得住它。
    nonisolated static func noTranslationLabel(input: Language) -> String {
        "不翻译（保持\(input.displayName)原样）"
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
    ///
    /// **目录还不存在时要明说。** 首次下载之前 `ModelCatalog.resolveRoot`
    /// 照样返回应用支持目录里那个路径（它不判断存不存在），于是用户点
    /// 「在访达中显示」会得到一个上级目录、或者干脆什么都不发生——
    /// 而他刚刚才在上一行读到「位置：~/Library/…」。把「还没建」写出来，
    /// 那一下就不再像是坏了。
    nonisolated static func storageLocationLine(root: String, exists: (String) -> Bool) -> String {
        guard !root.isEmpty else { return "位置：尚未确定" }
        let shown = (root as NSString).abbreviatingWithTildeInPath
        return exists(root) ? "位置：\(shown)" : "位置：\(shown)（还没建，下载模型后出现）"
    }

    /// 「在访达中显示」该真正打开哪个路径。
    ///
    /// 目标目录不存在时逐级往上找**最近一个存在的祖先**：Finder 拿到一个不
    /// 存在的路径是静默无反应的，而静默无反应与「这个按钮坏了」分不开。
    /// 退到上级至少回答了「它将来会出现在哪」。
    ///
    /// 不选「按需创建」：一个叫「显示」的按钮不该在磁盘上留下东西。
    /// 也不选「置灰」：置灰之后用户既看不到位置、也不知道为什么点不动。
    ///
    /// `exists` 注入进来是为了能测——真机上根目录几乎总是存在，
    /// 而要守的恰恰是它不存在的那条路。`/` 一定存在，所以循环必然收敛。
    nonisolated static func revealTarget(root: String, exists: (String) -> Bool) -> String? {
        guard !root.isEmpty else { return nil }
        var candidate = root
        while !exists(candidate) {
            let parent = (candidate as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != candidate else { return nil }
            candidate = parent
        }
        return candidate
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

    /// 零模型时头部那句话。
    ///
    /// 头部只有一行、`lineLimit(1)`、面板 320pt 宽——放不下「怎么办」，
    /// 所以这里只负责说清「是什么」，怎么办由模型列表那一格的
    /// `emptyModelListLine` 接着说。
    nonisolated static let noModelText = "还没有语音模型"

    /// 模型列表为空时那一行。
    ///
    /// 原文是「vendor/models 下没有模型」——`vendor/models` 是**开发机上的
    /// 仓库路径**，这一批已经把模型搬到 `~/Library/Application Support/
    /// vInput/huggingface` 了。而读到这句话的人，正是此刻手上一个模型都
    /// 没有的那个人：给她一个她机器上根本不存在的目录名，等于没说。
    ///
    /// 现在只说事实加去处，路径本身在同一个面板的「高级 → 位置：…」那一行，
    /// 不在这里重复一遍（重复的两处迟早各说各的）。
    nonisolated static let emptyModelListLine = "还没有模型（下载完成后出现在这里）"

    /// 文案与旧 MenuContent.statusText **逐字相同**（迁移守则：零增减），
    /// 搬到 model 层是为了让测试钉得住它。
    ///
    /// **`hasModel` 没有默认值，是有意的。** 给它一个 `= true` 的话，漏掉
    /// 任何一个调用点都不会有编译错误，而漏掉的表现正是这一条要修的东西：
    /// 面板在零模型时说「就绪」。
    nonisolated static func headerStatus(
        loadingModelName: String?,
        phase: AppModel.Phase,
        permission: Permissions.Status,
        hasModel: Bool
    ) -> HeaderStatus {
        if let loading = loadingModelName {
            return HeaderStatus(text: "正在加载模型 \(loading)…首次可能需要一两分钟", tone: .busy)
        }
        switch phase {
        case .idle:
            switch permission {
            case .ready:
                // 权限齐了、也没有东西在加载，但**盘上一个模型都没有**——
                // 这一格原先说「就绪」。那句话是这一批最贵的一句谎：向导
                // 下载失败的用户关掉向导，看到的是一个绿点加「就绪」，
                // 于是他按下「开始听写」，而按下去会开始下载另一个他没要过
                // 的模型（见 `MissingModelTranscriber`）。
                // 权限那两句排在前面：它们更早、也更可操作。
                guard hasModel else { return HeaderStatus(text: noModelText, tone: .error) }
                return HeaderStatus(text: "就绪", tone: .ok)
            case .microphoneMissing: return HeaderStatus(text: "需要麦克风权限", tone: .error)
            case .accessibilityMissing: return HeaderStatus(text: "需要辅助功能权限", tone: .error)
            }
        case .listening: return HeaderStatus(text: "正在聆听…", tone: .recording)
        case .working: return HeaderStatus(text: "正在转写…", tone: .busy)
        case .error(let message): return HeaderStatus(text: "出错：\(message)", tone: .error)
        }
    }
}
