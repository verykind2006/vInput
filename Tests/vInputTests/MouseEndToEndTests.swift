import Foundation
import Testing

@testable import vInput

/// 从 BLE 字节一路走到 `AudioSourceRouter` 的 `onFrame`。
///
/// **为什么要有这一条**：前面几个套件各自钉住了一段，但接缝没人看——
/// 桥的 delegate 有没有接到协调器、协调器有没有把包给音频源、音频源有没有
/// 被路由器选中。M7 的真机验证要靠用户按鼠标上的键，实现方跑不了，
/// 接缝出问题只会在用户那一轮暴露。这里把整条线接起来喂真实字节。
///
/// 与 `AppModel` 的接线**一一对应**：这里的 `Wiring` 就是
/// `AppModel.startMouse()` 加 delegate 扩展的那几行的等价物。
@Suite("鼠标端到端：字节 → 样本")
@MainActor
struct MouseEndToEndTests {

    typealias Wiring = MouseWiringUnderTest

    private func controlFrame(code: UInt8) -> Data {
        Data([0x0A, 0x77, 0xFF, 0x34, 0x1B, code, 0x0A, 0x06, 0x07, 0x09,
              0xC9, 0x00, 0xA9, 0x10, 0x04, 0xC5, 0x44])
    }

    private func audioPackets(_ count: Int) throws -> [Data] {
        let stream = try SBCFixtures.stream("dev-16k-16blk-8sb-loudness-bp12")
        return (0..<count).map {
            stream.subdata(in: ($0 * 128)..<(($0 + 1) * 128))
        }
    }

    @Test("按住语音键说三秒：字节进去，Float 样本出来")
    func fullPressProducesSamples() throws {
        let wiring = Wiring()
        wiring.build()

        wiring.bridge.handleVoicePacket(controlFrame(code: 0x51))
        wiring.bridge.handleVoicePacket(controlFrame(code: 0x21))
        for packet in try audioPackets(10) { wiring.bridge.handleVoicePacket(packet) }
        wiring.bridge.handleVoicePacket(controlFrame(code: 0x22))

        #expect(wiring.startCount == 1)
        #expect(wiring.finishCount == 1)
        // 10 包 × 4 帧 × 128 样本
        #expect(wiring.routedSamples.count == 10 * 512)
        #expect(wiring.routedSamples.allSatisfy { $0 >= -1 && $0 <= 1 })
        #expect(wiring.router.active == .mouse)
    }

    /// 事故那一档：0x31 开的会话一个样本都不该走到路由器，
    /// 也就不该有任何东西被转写、被注入。
    @Test("0x31 的会话不产生任何样本")
    func unpairedSessionProducesNothing() throws {
        let wiring = Wiring()
        wiring.build()

        wiring.bridge.handleVoicePacket(controlFrame(code: 0x31))
        for packet in try audioPackets(10) { wiring.bridge.handleVoicePacket(packet) }

        #expect(wiring.startCount == 0)
        #expect(wiring.routedSamples.isEmpty)
    }

    @Test("撞到时长上限时会话收尾，之后的包一个都不进来")
    func durationLimitEndsSessionAndSilencesStream() throws {
        let wiring = Wiring()
        wiring.build()
        let after = Date().addingTimeInterval(MouseSessionLimits.dictation + 1)

        wiring.bridge.handleVoicePacket(controlFrame(code: 0x21))
        for packet in try audioPackets(5) { wiring.bridge.handleVoicePacket(packet) }
        let before = wiring.routedSamples.count
        #expect(before == 5 * 512)

        // 桥的 tick 由 Timer 驱动；测试直接推状态机再让桥消化动作
        for action in wiring.bridge.session.tick(at: after) {
            switch action {
            case .endDictation:
                wiring.coordinator.handleVoiceStop()
            default:
                break
            }
        }
        #expect(wiring.finishCount == 1)

        for packet in try audioPackets(5) { wiring.bridge.handleVoicePacket(packet) }
        #expect(wiring.routedSamples.count == before)
    }

    /// 遥控器正在录时按鼠标语音键：路由器运行中不许切源，
    /// 鼠标的样本一个都混不进遥控器那次会话的缓冲区。
    @Test("遥控器占着时鼠标的样本混不进去")
    func mouseCannotHijackRunningRemoteSession() throws {
        let wiring = Wiring()
        wiring.build()

        wiring.router.select(.bluetooth)
        try wiring.router.start()

        wiring.bridge.handleVoicePacket(controlFrame(code: 0x21))
        for packet in try audioPackets(5) { wiring.bridge.handleVoicePacket(packet) }

        #expect(wiring.router.active == .bluetooth)
        #expect(wiring.routedSamples.isEmpty)
    }

    @Test("录音期间断连以错误收尾")
    func disconnectDuringRecordingReportsError() throws {
        let wiring = Wiring()
        wiring.build()
        var stopError: Error?
        wiring.router.onStop = { stopError = $0 }

        wiring.bridge.handleVoicePacket(controlFrame(code: 0x21))
        for packet in try audioPackets(2) { wiring.bridge.handleVoicePacket(packet) }
        wiring.mouseBridgeDidDisconnect(wiring.bridge)

        #expect(stopError != nil)
    }
}

/// 把桥、协调器、音频源、路由器接起来，形状照抄 `AppModel.startMouse()`
/// 与它的 delegate 扩展。
@MainActor
final class MouseWiringUnderTest {
    let source = MouseAudioSource()
    let router: AudioSourceRouter
    var coordinator: MouseCoordinator!
    var bridge: MouseBluetoothBridge!

    var routedSamples: [Float] = []
    var startCount = 0
    var finishCount = 0

    init() {
        router = AudioSourceRouter(sources: [
            .microphone: FakeAudioSource(),
            .bluetooth: FakeAudioSource(),
            .mouse: source,
        ])
    }

    func build() {
        let coordinator = MouseCoordinator(source: source)
        coordinator.onStartSession = { [unowned self] in
            self.startCount += 1
            self.router.select(.mouse)
            try? self.router.start()
        }
        coordinator.onFinishSession = { [unowned self] in
            self.finishCount += 1
            self.router.stop()
        }
        self.coordinator = coordinator
        router.onFrame = { [unowned self] in self.routedSamples.append(contentsOf: $0) }
        // 传 FakeKeyPoster：默认的 SystemKeyPoster 会真的注入回车键。
        bridge = MouseBluetoothBridge(
            delegate: self, targetName: "iMouse", keyPoster: FakeKeyPoster()
        )
    }
}

/// delegate 的实现与 `AppModel` 的扩展逐条对应。
extension MouseWiringUnderTest: @MainActor MouseBluetoothBridgeDelegate {
    func mouseBridge(_ bridge: MouseBluetoothBridge, didChange state: MouseBridgeState) {}
    func mouseBridgeDidStartVoice(_ bridge: MouseBluetoothBridge) {
        coordinator.handleVoiceStart()
    }
    func mouseBridge(_ bridge: MouseBluetoothBridge, didStopVoice reason: MouseSessionEndReason) {
        coordinator.handleVoiceStop()
    }
    func mouseBridge(_ bridge: MouseBluetoothBridge, didReceiveAudio packet: Data) {
        coordinator.handleAudio(packet)
    }
    func mouseBridge(_ bridge: MouseBluetoothBridge, didUpdateBatteryLevel level: Int?) {}
    func mouseBridgeDidDisconnect(_ bridge: MouseBluetoothBridge) {
        coordinator.handleDisconnected()
    }
}
