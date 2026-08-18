import Foundation
import Testing

@testable import vInput

/// 桥的**分流链路**验收：喂字节进去，看会话状态机与 delegate 的反应。
///
/// 构造桥不碰 CoreBluetooth（`CBCentralManager` 要到 `start()` 才建），
/// 所以这一整条「长度分流 → 控制帧解析 → 会话状态机 → delegate 回调」
/// 可以在 CI 里跑得到。**真机验证要靠用户按鼠标上的键，实现方跑不了**，
/// 能自动化的这部分就必须自动化。
@Suite("MouseBluetoothBridge 分流")
struct MouseBluetoothBridgeTests {

    private final class FakeDelegate: MouseBluetoothBridgeDelegate {
        var events: [String] = []
        var audioPackets: [Data] = []
        var battery: Int?

        func mouseBridge(_ bridge: MouseBluetoothBridge, didChange state: MouseBridgeState) {
            events.append("state")
        }
        func mouseBridgeDidStartVoice(_ bridge: MouseBluetoothBridge) {
            events.append("start")
        }
        func mouseBridge(_ bridge: MouseBluetoothBridge, didStopVoice reason: MouseSessionEndReason) {
            events.append("stop:\(reason)")
        }
        func mouseBridge(_ bridge: MouseBluetoothBridge, didReceiveAudio packet: Data) {
            audioPackets.append(packet)
        }
        func mouseBridge(_ bridge: MouseBluetoothBridge, didUpdateBatteryLevel level: Int?) {
            battery = level
        }
        func mouseBridgeDidDisconnect(_ bridge: MouseBluetoothBridge) {
            events.append("disconnect")
        }
    }

    private func makeBridge() -> (MouseBluetoothBridge, FakeDelegate) {
        let delegate = FakeDelegate()
        let bridge = MouseBluetoothBridge(delegate: delegate, targetName: "iMouse")
        return (bridge, delegate)
    }

    private func controlFrame(code: UInt8) -> Data {
        Data([0x0A, 0x77, 0xFF, 0x34, 0x1B, code, 0x0A, 0x06, 0x07, 0x09,
              0xC9, 0x00, 0xA9, 0x10, 0x04, 0xC5, 0x44])
    }

    private func audioPacket() throws -> Data {
        try SBCFixtures.stream("dev-16k-16blk-8sb-loudness-bp12").subdata(in: 0..<128)
    }

    // MARK: - 长度分流

    @Test("17 字节是控制帧、128 字节是音频、其余不认识")
    func routesByLength() {
        #expect(MouseVoiceProtocol.kind(ofLength: 17) == .control)
        #expect(MouseVoiceProtocol.kind(ofLength: 128) == .audio)
        #expect(MouseVoiceProtocol.kind(ofLength: 9) == .unknown(9))
        #expect(MouseVoiceProtocol.kind(ofLength: 0) == .unknown(0))
    }

    @Test("语音键的一次完整按键走通开始与结束")
    func fullVoicePress() throws {
        let (bridge, delegate) = makeBridge()

        bridge.handleVoicePacket(controlFrame(code: 0x51))
        #expect(delegate.events.isEmpty)   // 0x51 只是准备信号

        bridge.handleVoicePacket(controlFrame(code: 0x21))
        #expect(delegate.events == ["start"])

        bridge.handleVoicePacket(try audioPacket())
        #expect(delegate.audioPackets.count == 1)

        bridge.handleVoicePacket(controlFrame(code: 0x22))
        #expect(delegate.events.count == 2)
        #expect(delegate.events.last?.hasPrefix("stop:") == true)
    }

    /// 第一道过滤在桥这里：不是听写会话就一个字节都不往下送。
    /// 0x31 / 0x23 / 0x27 开的会话到不了音频源，也就到不了转写与注入。
    @Test("没有会话时音频包不往下送")
    func dropsAudioWithoutSession() throws {
        let (bridge, delegate) = makeBridge()
        bridge.handleVoicePacket(try audioPacket())
        #expect(delegate.audioPackets.isEmpty)
    }

    @Test("0x31 开的会话不启动听写，音频也不往下送")
    func unpairedSessionDeliversNothing() throws {
        let (bridge, delegate) = makeBridge()

        bridge.handleVoicePacket(controlFrame(code: 0x31))
        bridge.handleVoicePacket(try audioPacket())
        bridge.handleVoicePacket(try audioPacket())

        #expect(delegate.events.isEmpty)
        #expect(delegate.audioPackets.isEmpty)
    }

    @Test("其他功能键开的会话同样不往下送")
    func foreignKeySessionDeliversNothing() throws {
        let (bridge, delegate) = makeBridge()
        for code: UInt8 in [0x23, 0x27] {
            bridge.handleVoicePacket(controlFrame(code: code))
            bridge.handleVoicePacket(try audioPacket())
        }
        #expect(delegate.events.isEmpty)
        #expect(delegate.audioPackets.isEmpty)
    }

    /// 一个 17 字节但布局不同的包意味着固件换了协议。把第 6 字节当控制码
    /// 是在猜，猜错会让「开始会话」凭空出现。
    @Test("布局不对的 17 字节帧不会开会话")
    func malformedControlFrameIsIgnored() {
        let (bridge, delegate) = makeBridge()
        var bytes = [UInt8](controlFrame(code: 0x21))
        bytes[0] = 0x0B
        bridge.handleVoicePacket(Data(bytes))
        #expect(delegate.events.isEmpty)
    }

    @Test("长度不认识的包不会开会话")
    func unknownLengthIsIgnored() {
        let (bridge, delegate) = makeBridge()
        bridge.handleVoicePacket(Data(repeating: 0, count: 9))
        bridge.handleVoicePacket(Data(repeating: 0, count: 64))
        #expect(delegate.events.isEmpty)
        #expect(delegate.audioPackets.isEmpty)
    }

    // MARK: - 时长上限落到桥上

    /// 2026-08-18 事故：0x31 之后鼠标持续送流 11 分钟。
    /// 这条测的是「状态机说停之后，桥真的不再往下送音频」。
    @Test("0x31 撞上限后桥进入静默，音频彻底断掉")
    func limitMutesBridge() throws {
        let (bridge, delegate) = makeBridge()
        // 桥用真实时钟（handleVoicePacket 内部取 Date()），所以推进时刻
        // 要留一点余量，否则 elapsed 会差那么几微秒撞不到线。
        let after = Date().addingTimeInterval(MouseSessionLimits.unpaired + 1)

        bridge.handleVoicePacket(controlFrame(code: 0x31))
        // 真实的 0x31 是在送流的——先过一个音频包，否则会走「按键，静默
        // 收掉」那条路（见 MouseVoiceSession.silentForeignGrace），
        // 测的就不是这个事故了。这一包本身仍然不该到达 delegate。
        bridge.handleVoicePacket(try audioPacket())
        #expect(delegate.audioPackets.isEmpty, "非听写会话的音频不该往下送")

        let actions = bridge.session.tick(at: after)
        #expect(actions.count == 1)
        #expect(actions.first == .stopReceiving(cooldown: MouseSessionLimits.initialCooldown))

        bridge.handleVoicePacket(try audioPacket())
        #expect(delegate.audioPackets.isEmpty)
        #expect(!bridge.session.acceptsAudio)
    }

    @Test("听写撞上限时把已经录到的那段交出去再静默")
    func dictationLimitFinishesSession() throws {
        let (bridge, delegate) = makeBridge()
        let after = Date().addingTimeInterval(MouseSessionLimits.dictation + 1)

        bridge.handleVoicePacket(controlFrame(code: 0x21))
        bridge.handleVoicePacket(try audioPacket())
        #expect(delegate.audioPackets.count == 1)

        // 桥的 tick 由 Timer 驱动，测试直接推状态机再让桥消化
        let actions = bridge.session.tick(at: after)
        #expect(actions.count == 2)
        if case .endDictation(.durationLimit) = actions[0] {} else {
            Issue.record("撞线时该先收尾听写，实际是 \(actions[0])")
        }
        #expect(actions[1] == .stopReceiving(cooldown: MouseSessionLimits.initialCooldown))

        bridge.handleVoicePacket(try audioPacket())
        #expect(delegate.audioPackets.count == 1)   // 撞线之后一个包都不再送
    }

    /// 断连要把进行中的听写收掉，否则重连后 `acceptsAudio` 还留在 true，
    /// 下一次连上来的第一个包就会被当成上一次会话的一部分。
    @Test("断连收尾进行中的听写")
    func disconnectEndsSession() throws {
        let (bridge, delegate) = makeBridge()
        bridge.handleVoicePacket(controlFrame(code: 0x21))
        #expect(bridge.session.acceptsAudio)

        _ = bridge.session.handleDisconnected()
        #expect(!bridge.session.acceptsAudio)

        bridge.handleVoicePacket(try audioPacket())
        #expect(delegate.audioPackets.isEmpty)
    }
}

@Suite("鼠标连接状态的菜单文案")
struct MouseBridgeStateTests {

    @Test("每种状态都有一句人话，没有一句是 case 名字")
    func everyStateHasLabel() {
        let states: [MouseBridgeState] = [
            .stopped,
            .bluetoothUnavailable("蓝牙已关闭"),
            .searching,
            .connecting,
            .discovering,
            .reconnecting,
            .muted(10),
            .ready("iMouse"),
        ]
        for state in states {
            let label = state.menuLabel(battery: nil)
            #expect(label.hasPrefix("鼠标："))
            #expect(!label.contains("MouseBridgeState"))
            #expect(label.count > 3)
        }
    }

    @Test("已连接时显示电量")
    func showsBattery() {
        #expect(MouseBridgeState.ready("iMouse").menuLabel(battery: 73) == "鼠标：已连接（电量 73%）")
        #expect(MouseBridgeState.ready("iMouse").menuLabel(battery: nil) == "鼠标：已连接")
    }

    /// 主动掐断一段流之后什么都不显示的话，用户只会觉得「语音键突然不好使
    /// 了」然后去重启应用。2026-08-18 那次他也是靠菜单栏才发现的。
    @Test("超时静音要写明还要等多久")
    func mutedStateIsVisible() {
        let label = MouseBridgeState.muted(40).menuLabel(battery: nil)
        #expect(label.contains("静音"))
        #expect(label.contains("40"))
    }
}
