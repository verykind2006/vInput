import Testing
@testable import vInput

@Suite("AudioSourceRouter")
@MainActor
struct AudioSourceRouterTests {

    private func makeRouter() -> (AudioSourceRouter, FakeAudioSource, FakeAudioSource) {
        let mic = FakeAudioSource()
        let bluetooth = FakeAudioSource()
        let router = AudioSourceRouter(sources: [.microphone: mic, .bluetooth: bluetooth])
        return (router, mic, bluetooth)
    }

    @Test("默认选中麦克风")
    func defaultsToMicrophone() {
        let (router, _, _) = makeRouter()
        #expect(router.active == .microphone)
    }

    @Test("start 只启动当前选中的源")
    func startsOnlySelectedSource() throws {
        let (router, mic, bluetooth) = makeRouter()

        router.select(.bluetooth)
        try router.start()

        #expect(bluetooth.startCallCount == 1)
        #expect(mic.startCallCount == 0)
    }

    @Test("只转发当前源的帧")
    func forwardsOnlyActiveSourceFrames() throws {
        let (router, mic, bluetooth) = makeRouter()
        var received: [Float] = []
        router.onFrame = { received.append(contentsOf: $0) }

        router.select(.bluetooth)
        try router.start()

        bluetooth.emit([1, 2, 3])
        mic.emit([9, 9, 9])   // 非活跃源的帧必须被丢弃

        #expect(received == [1, 2, 3])
    }

    @Test("stop 只停当前源")
    func stopsOnlyActiveSource() throws {
        let (router, mic, bluetooth) = makeRouter()

        router.select(.bluetooth)
        try router.start()
        router.stop()

        #expect(bluetooth.stopCallCount == 1)
        #expect(mic.stopCallCount == 0)
    }

    @Test("转发当前源的结束事件")
    func forwardsStopFromActiveSource() throws {
        let (router, _, bluetooth) = makeRouter()
        var reported: Error?
        router.onStop = { reported = $0 }

        router.select(.bluetooth)
        try router.start()
        bluetooth.fail(with: AudioSourceError.engineFailedToStart("device lost"))

        #expect(reported != nil)
    }

    @Test("非活跃源的结束事件不转发")
    func ignoresStopFromInactiveSource() throws {
        let (router, mic, _) = makeRouter()
        var reported: Error?
        router.onStop = { reported = $0 }

        router.select(.bluetooth)
        try router.start()
        mic.fail(with: AudioSourceError.engineFailedToStart("irrelevant"))

        #expect(reported == nil)
    }

    @Test("运行中不允许切换源")
    func cannotSwitchWhileRunning() throws {
        let (router, _, bluetooth) = makeRouter()

        router.select(.bluetooth)
        try router.start()
        router.select(.microphone)   // 应被忽略

        #expect(router.active == .bluetooth)
        #expect(bluetooth.stopCallCount == 0)
    }

    @Test("stop 之后可以切换到另一个源")
    func canSwitchAfterStop() throws {
        let (router, mic, bluetooth) = makeRouter()

        router.select(.bluetooth)
        try router.start()
        router.stop()

        router.select(.microphone)
        try router.start()

        #expect(router.active == .microphone)
        #expect(mic.startCallCount == 1)
        #expect(bluetooth.startCallCount == 1)
    }

    @Test("启动失败时向上抛出")
    func propagatesStartError() {
        let (router, mic, _) = makeRouter()
        mic.startError = AudioSourceError.microphonePermissionDenied

        #expect(throws: AudioSourceError.microphonePermissionDenied) {
            try router.start()
        }
    }

    @Test("缺少某个源时选择它会被忽略")
    func selectingMissingSourceIsIgnored() {
        let mic = FakeAudioSource()
        // 遥控器未接入时，路由表里只有麦克风
        let router = AudioSourceRouter(sources: [.microphone: mic])

        router.select(.bluetooth)

        #expect(router.active == .microphone)
    }
}
