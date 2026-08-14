import Testing
@testable import vInput

@Suite("遥控器连接状态")
struct RemoteConnectionStateTests {

    // MARK: - 文案

    @Test("各状态的菜单栏文案")
    func menuLabels() {
        #expect(RemoteConnectionState.disconnected.menuLabel == "遥控器：未连接")
        #expect(RemoteConnectionState.scanning.menuLabel == "遥控器：搜索中…")
        #expect(RemoteConnectionState.connected.menuLabel == "遥控器：已连接")
        #expect(RemoteConnectionState.unavailable("蓝牙已关闭").menuLabel == "遥控器：蓝牙已关闭")
    }

    @Test("只有已连接才算可用")
    func onlyConnectedIsUsable() {
        #expect(RemoteConnectionState.connected.isUsable)
        #expect(!RemoteConnectionState.disconnected.isUsable)
        #expect(!RemoteConnectionState.scanning.isUsable)
        #expect(!RemoteConnectionState.unavailable("x").isUsable)
    }

    @Test("电量在已连接时附加显示")
    func batteryShownWhenConnected() {
        #expect(RemoteConnectionState.connected.menuLabel(battery: 87) == "遥控器：已连接（电量 87%）")
        #expect(RemoteConnectionState.connected.menuLabel(battery: nil) == "遥控器：已连接")
    }

    @Test("未连接时不显示电量")
    func batteryHiddenWhenDisconnected() {
        #expect(RemoteConnectionState.disconnected.menuLabel(battery: 87) == "遥控器：未连接")
    }

    // MARK: - 从蓝牙桥状态映射

    @Test("ready 映射为已连接")
    func readyMapsToConnected() {
        #expect(RemoteConnectionState(bridgeState: .ready("MI RC")) == .connected)
    }

    @Test("扫描与连接过程都归为搜索中")
    func inProgressStatesMapToScanning() {
        #expect(RemoteConnectionState(bridgeState: .scanning) == .scanning)
        #expect(RemoteConnectionState(bridgeState: .connecting) == .scanning)
        #expect(RemoteConnectionState(bridgeState: .discovering) == .scanning)
        #expect(RemoteConnectionState(bridgeState: .reconnecting) == .scanning)
    }

    @Test("stopped 映射为未连接")
    func stoppedMapsToDisconnected() {
        #expect(RemoteConnectionState(bridgeState: .stopped) == .disconnected)
    }

    @Test("蓝牙不可用时把 i18n key 译成中文")
    func translatesUnavailableKeys() {
        // LocalizedMessage 只有 key，上游的本地化系统未移植，
        // 直接展示 key 给用户会是 "bluetooth.status.off" 这种字符串
        #expect(
            RemoteConnectionState(bridgeState: .bluetoothUnavailable(LocalizedMessage("bluetooth.status.off")))
                == .unavailable("蓝牙已关闭")
        )
        #expect(
            RemoteConnectionState(bridgeState: .bluetoothUnavailable(LocalizedMessage("bluetooth.status.permission_denied")))
                == .unavailable("未授予蓝牙权限")
        )
    }

    @Test("连接失败时把 i18n key 译成中文")
    func translatesFailureKeys() {
        #expect(
            RemoteConnectionState(bridgeState: .failed(LocalizedMessage("connection.error.voice_service_missing")))
                == .unavailable("遥控器不支持语音")
        )
    }

    @Test("未知的 key 有兜底文案，不把原始 key 甩给用户")
    func unknownKeyHasFallback() {
        let state = RemoteConnectionState(bridgeState: .failed(LocalizedMessage("some.unmapped.key")))
        guard case .unavailable(let text) = state else {
            Issue.record("应为 unavailable，实际 \(state)")
            return
        }
        // 上游若新增状态，用户看到的应是可读文案而非 i18n key
        #expect(!text.contains("."))
        #expect(!text.isEmpty)
    }

    @Test("全部八个已知 key 都有中文译文")
    func allKnownKeysTranslated() {
        let keys = [
            "bluetooth.status.off",
            "bluetooth.status.permission_denied",
            "bluetooth.status.unsupported",
            "bluetooth.status.resetting",
            "bluetooth.status.initializing",
            "bluetooth.status.unavailable",
            "connection.error.voice_service_missing",
            "connection.error.voice_channel_incomplete",
        ]
        for key in keys {
            let state = RemoteConnectionState(bridgeState: .failed(LocalizedMessage(key)))
            guard case .unavailable(let text) = state else {
                Issue.record("\(key) 应映射为 unavailable")
                continue
            }
            #expect(!text.contains("."), "\(key) 未被译成中文，仍是 i18n key")
        }
    }
}
