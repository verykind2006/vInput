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
