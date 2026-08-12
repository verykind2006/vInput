import Foundation
import Testing
@testable import vInput

/// 由测试代码手动驱动的音频源。
@MainActor
final class FakeAudioSource: AudioSource {
    var onFrame: (([Float]) -> Void)?
    var onStop: ((Error?) -> Void)?

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    /// 设置后，`start()` 会抛出该错误。
    var startError: Error?

    func start() throws {
        startCallCount += 1
        if let startError { throw startError }
    }

    func stop() {
        stopCallCount += 1
        onStop?(nil)
    }

    // MARK: - 测试驱动入口

    /// 模拟采集到一批样本。
    func emit(_ samples: [Float]) {
        onFrame?(samples)
    }

    /// 模拟采集到 `seconds` 秒的静音，用于凑时长。
    func emitSilence(seconds: Double) {
        emit(Array(repeating: 0, count: Int(seconds * AudioFormat.sampleRate)))
    }

    /// 模拟采集过程中出错。
    func fail(with error: Error) {
        onStop?(error)
    }
}

@Suite("FakeAudioSource")
@MainActor
struct FakeAudioSourceTests {
    @Test("emit 会把样本送到 onFrame")
    func emitDeliversFrames() {
        let source = FakeAudioSource()
        var received: [Float] = []
        source.onFrame = { received.append(contentsOf: $0) }

        source.emit([1, 2, 3])

        #expect(received == [1, 2, 3])
    }

    @Test("stop 会触发 onStop 且不带错误")
    func stopReportsCleanFinish() {
        let source = FakeAudioSource()
        var stopped = false
        var reportedError: Error?
        source.onStop = { stopped = true; reportedError = $0 }

        source.stop()

        #expect(stopped)
        #expect(reportedError == nil)
        #expect(source.stopCallCount == 1)
    }

    @Test("start 会抛出预设的错误")
    func startPropagatesError() {
        let source = FakeAudioSource()
        source.startError = AudioSourceError.microphonePermissionDenied

        #expect(throws: AudioSourceError.microphonePermissionDenied) {
            try source.start()
        }
    }
}
