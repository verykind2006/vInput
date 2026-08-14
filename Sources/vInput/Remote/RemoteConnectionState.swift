import Foundation

/// 遥控器的连接状态，供菜单栏展示。
///
/// 与蓝牙桥内部的 `BluetoothBridgeState` 分开：那个是协议层的细粒度状态
/// （扫描、连接、发现服务、协商能力……），这里只保留用户需要知道的四种。
enum RemoteConnectionState: Equatable {
    case disconnected
    case scanning
    case connected
    /// 蓝牙不可用，附带已译成中文的原因。
    case unavailable(String)

    var isUsable: Bool { self == .connected }

    var menuLabel: String { menuLabel(battery: nil) }

    func menuLabel(battery: Int?) -> String {
        switch self {
        case .disconnected:
            return "遥控器：未连接"
        case .scanning:
            return "遥控器：搜索中…"
        case .connected:
            if let battery {
                return "遥控器：已连接（电量 \(battery)%）"
            }
            return "遥控器：已连接"
        case .unavailable(let reason):
            return "遥控器：\(reason)"
        }
    }

    /// 把蓝牙桥的细粒度协议状态收敛成用户看得懂的四种。
    ///
    /// 每个 case 都显式列出、**不用 `default`**：上游若新增状态，
    /// 用 `default` 会让它被静默归到错误的类别里，而显式穷举会编译报错。
    init(bridgeState: BluetoothBridgeState) {
        switch bridgeState {
        case .stopped:
            self = .disconnected
        case .scanning, .connecting, .discovering, .reconnecting:
            // 这四个都是"正在往连上走"的中间态，用户只需知道还没好
            self = .scanning
        case .ready:
            self = .connected
        case .bluetoothUnavailable(let message), .failed(let message):
            self = .unavailable(Self.translate(message))
        }
    }

    /// 把 i18n key 译成中文。
    ///
    /// 上游的本地化系统未移植（那会牵进整套设置与语言切换），
    /// `LocalizedMessage` 只剩 key。直接展示会是 "bluetooth.status.off"
    /// 这种字符串，所以在这里做一次映射。
    private static func translate(_ message: LocalizedMessage) -> String {
        switch message.key {
        case "bluetooth.status.off":
            return "蓝牙已关闭"
        case "bluetooth.status.permission_denied":
            return "未授予蓝牙权限"
        case "bluetooth.status.unsupported":
            return "本机不支持蓝牙"
        case "bluetooth.status.resetting":
            return "蓝牙重置中"
        case "bluetooth.status.initializing":
            return "蓝牙初始化中"
        case "bluetooth.status.unavailable":
            return "蓝牙不可用"
        case "connection.error.voice_service_missing":
            return "遥控器不支持语音"
        case "connection.error.voice_channel_incomplete":
            return "语音通道不完整"
        default:
            // 上游新增状态时的兜底。宁可笼统也不要把 i18n key 甩给用户，
            // 具体原因已经记在日志里。
            return "连接异常"
        }
    }
}
