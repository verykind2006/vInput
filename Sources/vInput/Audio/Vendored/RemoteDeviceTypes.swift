//  移植自 HD838A/remote-mic-app（GPL-3.0-only）
//  https://github.com/HD838A/remote-mic-app
//
//  仅摘取 RemoteDeviceProfile.swift 的前 56 行——即 XiaomiRemoteModel 与
//  RemotePowerState 两个类型，蓝牙桥的 delegate 回调用得到。其后的
//  RemoteDeviceMappings 与 RemoteDeviceProfile 属于按键映射体系，
//  本项目明确不做。
//
//  相对上游的适配：
//  （在此逐条记录你实际做的改动）
//

import Foundation

enum XiaomiRemoteModel: String, Codable, CaseIterable, Identifiable {
    case rc001
    case rc003
    case unknown

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .rc001: return "remote.device.model.rc001"
        case .rc003: return "remote.device.model.rc003"
        case .unknown: return "remote.device.model.unknown"
        }
    }

    static func identified(by modelNumber: String) -> XiaomiRemoteModel? {
        switch modelNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "RC001": return .rc001
        case "RC003": return .rc003
        default: return nil
        }
    }
}

enum RemotePowerState: Equatable {
    case onBattery
    case externalPower
    case charging
    case unknown

    static func decodeBatteryLevelStatus(_ data: Data) -> RemotePowerState? {
        guard data.count >= 3 else { return nil }
        let powerState = UInt16(data[data.startIndex + 1]) |
            UInt16(data[data.startIndex + 2]) << 8
        let batteryPresent = powerState & 0x0001 == 0x0001
        guard batteryPresent else { return .unknown }

        let wiredExternalPower = (powerState >> 1) & 0x0003
        let wirelessExternalPower = (powerState >> 3) & 0x0003
        let chargeState = (powerState >> 5) & 0x0003

        if chargeState == 0x0001 {
            return .charging
        }
        if wiredExternalPower == 0x0001 || wirelessExternalPower == 0x0001 {
            return .externalPower
        }
        if wiredExternalPower == 0 && wirelessExternalPower == 0 {
            return .onBattery
        }
        return .unknown
    }
}
