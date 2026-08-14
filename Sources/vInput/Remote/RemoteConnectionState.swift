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

    /// i18n key 到中文的映射表。
    ///
    /// 上游的本地化系统未移植（那会牵进整套设置与语言切换），
    /// `LocalizedMessage` 只剩 key。直接展示会是 "bluetooth.status.off"
    /// 这种字符串，所以在这里做一次映射。
    ///
    /// **必须覆盖所有会进入 `.failed` / `.bluetoothUnavailable` 的 key。**
    /// `RemoteConnectionStateTests` 会扫描源码里全部 `LocalizedMessage(...)`
    /// 的构造点，任何新 key 若既不在本表、也不在测试的「不作为故障展示」
    /// 白名单里，测试就会失败——上游新增状态时不会静默退化成「连接异常」。
    static let translations: [String: String] = [
        "bluetooth.status.off": "蓝牙已关闭",
        "bluetooth.status.permission_denied": "未授予蓝牙权限",
        "bluetooth.status.unsupported": "本机不支持蓝牙",
        "bluetooth.status.resetting": "蓝牙重置中",
        "bluetooth.status.initializing": "蓝牙初始化中",
        "bluetooth.status.unavailable": "蓝牙不可用",
        "connection.error.voice_service_missing": "遥控器不支持语音",
        "connection.error.voice_channel_incomplete": "语音通道不完整",
        // 以下五项经 failInitialization / rejectUnsupportedAudio 间接进入
        // .failed，同样会显示给用户。此前漏映射，一律退化成「连接异常」，
        // 把「遥控器不支持 16kHz」这类可操作的信息也一并抹平了。
        "connection.error.voice_service_timeout": "遥控器语音服务无响应",
        "connection.error.invalid_voice_response": "遥控器语音响应无法解析",
        "connection.error.unsupported_16khz_codec": "遥控器不支持 16kHz 编码",
        "connection.error.unsupported_8khz_codec": "遥控器不支持 8kHz 编码",
        "connection.error.voice_channel_subscription_inactive": "语音通道订阅未生效",
        // 这三项是跨行构造的，手工 grep 与真机验收都漏了，由覆盖测试抓出。
        "connection.error.voice_service_discovery_failed": "未找到遥控器的语音服务",
        "connection.error.voice_channel_discovery_failed": "未找到语音数据通道",
        "connection.error.voice_channel_subscription_failed": "语音通道订阅失败",
    ]

    /// 未映射 key 的兜底文案。宁可笼统也不要把 i18n key 甩给用户，
    /// 具体原因已经记在日志里。
    static let untranslatedFallback = "连接异常"

    static func translate(_ message: LocalizedMessage) -> String {
        translations[message.key] ?? untranslatedFallback
    }
}
