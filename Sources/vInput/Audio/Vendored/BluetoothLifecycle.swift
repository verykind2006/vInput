//  移植自 HD838A/remote-mic-app（GPL-3.0-only）
//  https://github.com/HD838A/remote-mic-app
//

import Foundation

enum XiaomiVoiceRemoteNameMatcher {
    private static let approvedNames: Set<String> = [
        "mi rc",
        "xiaomi bluetooth remote 2",
        "xiaomi bluetooth remote 2 pro",
        "小米蓝牙语音遥控器",
    ]

    static func matches(_ rawName: String?) -> Bool {
        guard let rawName else { return false }
        let normalized = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return approvedNames.contains(normalized)
    }
}

enum BluetoothLifecyclePhase: Equatable {
    case stopped
    case scanning(UInt64)
    case connecting(UInt64)
    case discovering(UInt64)
    case awaitingCapabilities(UInt64)
    case ready(UInt64)
    case disconnecting(UInt64)
    case waitingReconnect(UInt64)

    var generation: UInt64? {
        switch self {
        case .connecting(let value),
             .scanning(let value),
             .discovering(let value),
             .awaitingCapabilities(let value),
             .ready(let value),
             .disconnecting(let value),
             .waitingReconnect(let value):
            return value
        case .stopped:
            return nil
        }
    }

    func acceptsDidConnect(generation: UInt64) -> Bool {
        self == .connecting(generation)
    }

    func acceptsDidFailToConnect(generation: UInt64) -> Bool {
        self == .connecting(generation) || self == .disconnecting(generation)
    }

    func acceptsInitializationCallback(generation: UInt64) -> Bool {
        self == .discovering(generation)
    }

    func acceptsNotificationUpdate(generation: UInt64) -> Bool {
        switch self {
        case .discovering(generation),
             .awaitingCapabilities(generation),
             .ready(generation):
            return true
        default:
            return false
        }
    }

    func acceptsCapabilities(generation: UInt64) -> Bool {
        self == .awaitingCapabilities(generation)
    }

    func acceptsProtocolData(generation: UInt64) -> Bool {
        self == .ready(generation)
    }

    func acceptsDisconnect(generation: UInt64) -> Bool {
        switch self {
        case .connecting(generation),
             .discovering(generation),
             .awaitingCapabilities(generation),
             .ready(generation),
             .disconnecting(generation):
            return true
        default:
            return false
        }
    }
}

enum ATVVSessionGate {
    static let cancelledOpenSuppressionInterval: TimeInterval = 2

    static func canOpenMicrophone(
        phase: BluetoothLifecyclePhase,
        generation: UInt64,
        capabilitiesConfirmed: Bool,
        sampleRate: Double
    ) -> Bool {
        phase.acceptsProtocolData(generation: generation) &&
            capabilitiesConfirmed &&
            ATVVProtocol.supportsAudio(sampleRate: sampleRate)
    }

    static func cancelledOpenDate(
        microphoneOpened: Bool,
        streaming: Bool,
        now: Date = Date()
    ) -> Date? {
        microphoneOpened && !streaming ? now : nil
    }

    /// 能否为当前会话发送 `MIC_EXTEND` 续期。
    ///
    /// **只看 `streaming`，不看 `microphoneOpened`。** 后者只在主机主动开麦
    /// （`requestMicrophoneOpen`）时置位；而 RC003 的实际用法是用户按遥控器
    /// 上的实体语音键，由**设备主动**发起会话——那条路径只置 `streaming`。
    /// 若把 `microphoneOpened` 也纳入条件，保活在真实场景下永远发不出去。
    ///
    /// 真机日志证据：一次 42 秒的会话里只有 `STREAM START`，没有任何
    /// `MIC_OPEN host_request`，四次续期全部被自己的 guard 拦下。
    ///
    /// 语义上也该如此：`MIC_EXTEND` 延长的是一个正在进行的音频流，
    /// 这个流由谁发起与能否延长无关。
    static func canExtendMicrophone(streaming: Bool) -> Bool {
        streaming
    }

    static func shouldIgnoreStreamAfterCancelledOpen(
        cancelledAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let cancelledAt else { return false }
        return now < cancelledAt.addingTimeInterval(cancelledOpenSuppressionInterval)
    }
}
