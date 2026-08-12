import Foundation
import Testing
@testable import vInput

/// 由测试代码手动驱动的预览引擎。
final class FakePreviewEngine: PreviewEngine, @unchecked Sendable {
    var onUpdate: (@Sendable (PreviewText) -> Void)?

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    /// 记录 stop 被调用时的时刻，用于断言「先停预览再转写」。
    private(set) var stopOrder: Int?

    /// 设置后，`start()` 抛出该错误。
    var startError: Error?
    /// `stop()` 的人为耗时，用于验证调用方确实在等它。
    var stopDelay: Duration = .zero

    /// 供测试统计全局调用顺序。
    static let orderCounter = OrderCounter()

    func start() async throws {
        startCallCount += 1
        if let startError { throw startError }
    }

    func stop() async {
        stopCallCount += 1
        stopOrder = Self.orderCounter.next()
        if stopDelay > .zero { try? await Task.sleep(for: stopDelay) }
    }

    /// 模拟产出一次预览。
    func emit(confirmed: String, unconfirmed: String = "", energy: [Float] = []) {
        onUpdate?(PreviewText(confirmed: confirmed, unconfirmed: unconfirmed, energy: energy))
    }
}

/// 线程安全的自增计数器，用于断言调用先后顺序。
final class OrderCounter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        value = 0
    }
}

@Suite("FakePreviewEngine")
struct FakePreviewEngineTests {
    @Test("emit 会把预览推给 onUpdate")
    func emitDeliversPreview() {
        let engine = FakePreviewEngine()
        var received: PreviewText?
        engine.onUpdate = { received = $0 }

        engine.emit(confirmed: "已确认", unconfirmed: "未确认", energy: [0.5])

        #expect(received == PreviewText(confirmed: "已确认", unconfirmed: "未确认", energy: [0.5]))
    }

    @Test("start 抛出预设的错误")
    func startPropagatesError() async {
        let engine = FakePreviewEngine()
        engine.startError = PreviewEngineError.notReady

        await #expect(throws: PreviewEngineError.notReady) {
            try await engine.start()
        }
    }

    @Test("stop 记录调用次数")
    func stopCounts() async {
        let engine = FakePreviewEngine()
        await engine.stop()
        await engine.stop()
        #expect(engine.stopCallCount == 2)
    }
}
