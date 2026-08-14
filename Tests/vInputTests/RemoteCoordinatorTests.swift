import Testing
@testable import vInput

@Suite("RemoteCoordinator")
@MainActor
struct RemoteCoordinatorTests {

    private final class Recorder {
        var actions: [String] = []
    }

    private func makeCoordinator() -> (RemoteCoordinator, Recorder, BluetoothRemoteSource) {
        let recorder = Recorder()
        let source = BluetoothRemoteSource()
        let coordinator = RemoteCoordinator(source: source)
        coordinator.onStartSession = { recorder.actions.append("start") }
        coordinator.onFinishSession = { recorder.actions.append("finish") }
        coordinator.onCancelSession = { recorder.actions.append("cancel") }
        return (coordinator, recorder, source)
    }

    @Test("语音键按下请求开始会话")
    func voiceKeyDownStartsSession() {
        let (coordinator, recorder, _) = makeCoordinator()

        coordinator.handleVoiceStart()

        #expect(recorder.actions == ["start"])
    }

    @Test("语音键松开请求结束会话")
    func voiceKeyUpFinishesSession() {
        let (coordinator, recorder, _) = makeCoordinator()

        coordinator.handleVoiceStart()
        coordinator.handleVoiceStop()

        #expect(recorder.actions == ["start", "finish"])
    }

    @Test("返回键请求取消会话")
    func backKeyCancels() {
        let (coordinator, recorder, _) = makeCoordinator()

        coordinator.handleVoiceStart()
        coordinator.handleCancelPressed()

        #expect(recorder.actions == ["start", "cancel"])
    }

    @Test("未在会话中时返回键不触发取消")
    func backKeyIgnoredWhenIdle() {
        let (coordinator, recorder, _) = makeCoordinator()

        coordinator.handleCancelPressed()

        #expect(recorder.actions.isEmpty)
    }

    @Test("解码出的样本转发给音频源")
    func forwardsSamplesToSource() throws {
        let (coordinator, _, source) = makeCoordinator()
        var received: [Float] = []
        source.onFrame = { received.append(contentsOf: $0) }

        coordinator.handleVoiceStart()
        try source.start()
        coordinator.handleDecoded([32_767, 0])

        #expect(received.count == 2)
    }

    @Test("重复的语音开始事件只触发一次")
    func duplicateStartIsIgnored() {
        let (coordinator, recorder, _) = makeCoordinator()

        coordinator.handleVoiceStart()
        coordinator.handleVoiceStart()

        #expect(recorder.actions == ["start"])
    }

    @Test("未开始时的停止事件被忽略")
    func stopWithoutStartIsIgnored() {
        let (coordinator, recorder, _) = makeCoordinator()

        coordinator.handleVoiceStop()

        #expect(recorder.actions.isEmpty)
    }

    @Test("取消后语音停止事件不再触发结束")
    func stopAfterCancelIsIgnored() {
        let (coordinator, recorder, _) = makeCoordinator()

        coordinator.handleVoiceStart()
        coordinator.handleCancelPressed()
        // 用户按了取消，然后才松开语音键——不该再触发一次 finish
        coordinator.handleVoiceStop()

        #expect(recorder.actions == ["start", "cancel"])
    }

    @Test("取消后可以开始新一轮")
    func canStartAgainAfterCancel() {
        let (coordinator, recorder, _) = makeCoordinator()

        coordinator.handleVoiceStart()
        coordinator.handleCancelPressed()
        coordinator.handleVoiceStart()

        #expect(recorder.actions == ["start", "cancel", "start"])
    }

    @Test("断连时通知音频源")
    func disconnectNotifiesSource() throws {
        let (coordinator, _, source) = makeCoordinator()
        var reported: Error?
        source.onStop = { reported = $0 }

        coordinator.handleVoiceStart()
        try source.start()
        coordinator.handleDisconnected()

        #expect(reported != nil)
    }

    @Test("断连后语音停止事件不再触发结束")
    func stopAfterDisconnectIsIgnored() {
        let (coordinator, recorder, _) = makeCoordinator()

        coordinator.handleVoiceStart()
        coordinator.handleDisconnected()
        coordinator.handleVoiceStop()

        #expect(recorder.actions == ["start"])
    }
}
