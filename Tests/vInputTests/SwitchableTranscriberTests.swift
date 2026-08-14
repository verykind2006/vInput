import Foundation
import Testing
@testable import vInput

@Suite("SwitchableTranscriber")
struct SwitchableTranscriberTests {

    private func descriptor(_ name: String) -> ModelDescriptor {
        ModelDescriptor(name: name, folder: "/models/\(name)")
    }

    /// 记录每个模型被构造了几次，并让测试能拿到对应的替身。
    private final class Factory: @unchecked Sendable {
        var fakes: [String: FakeTranscriber] = [:]
        private(set) var buildCount: [String: Int] = [:]
        private let lock = NSLock()

        func make(_ d: ModelDescriptor) -> Transcriber {
            lock.lock(); defer { lock.unlock() }
            buildCount[d.name, default: 0] += 1
            if let existing = fakes[d.name] { return existing }
            let fake = FakeTranscriber()
            fake.result = "来自 \(d.name)"
            fakes[d.name] = fake
            return fake
        }

        func count(_ name: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return buildCount[name] ?? 0
        }
    }

    @Test("转写委托给当前模型")
    func delegatesToCurrent() async throws {
        let factory = Factory()
        let sut = SwitchableTranscriber(initial: descriptor("base"), makeTranscriber: { @Sendable in factory.make($0) })

        let text = try await sut.transcribe([0.1, 0.2, 0.3])

        #expect(text == "来自 base")
        #expect(await sut.descriptor.name == "base")
    }

    @Test("切换后转写走新模型")
    func switchChangesBackend() async throws {
        let factory = Factory()
        let sut = SwitchableTranscriber(initial: descriptor("base"), makeTranscriber: { @Sendable in factory.make($0) })

        try await sut.switchTo(descriptor("large-v3"))
        let text = try await sut.transcribe([0.1])

        #expect(text == "来自 large-v3")
        #expect(await sut.descriptor.name == "large-v3")
    }

    @Test("切换到同一个模型不重复构造")
    func switchingToSameIsNoop() async throws {
        let factory = Factory()
        let sut = SwitchableTranscriber(initial: descriptor("base"), makeTranscriber: { @Sendable in factory.make($0) })

        try await sut.switchTo(descriptor("base"))

        // 只有初始化时构造过那一次
        #expect(factory.count("base") == 1)
    }

    @Test("新模型加载失败时保持原模型可用")
    func failedSwitchKeepsPreviousModel() async throws {
        let factory = Factory()
        let sut = SwitchableTranscriber(initial: descriptor("base"), makeTranscriber: { @Sendable in factory.make($0) })

        // 预置一个 prepare 会失败的替身
        let broken = FakeTranscriber()
        broken.prepareError = TranscribeError.modelNotReady
        factory.fakes["坏模型"] = broken

        await #expect(throws: TranscribeError.modelNotReady) {
            try await sut.switchTo(self.descriptor("坏模型"))
        }

        // 关键：原模型仍然能用，没有被换成半死状态
        #expect(await sut.descriptor.name == "base")
        let text = try await sut.transcribe([0.1])
        #expect(text == "来自 base")
    }

    @Test("切换会排在进行中的转写之后，不打断它")
    func switchWaitsForInFlightTranscription() async throws {
        let factory = Factory()
        let sut = SwitchableTranscriber(initial: descriptor("base"), makeTranscriber: { @Sendable in factory.make($0) })
        factory.fakes["base"]?.delay = .milliseconds(120)

        // 先发起一次慢转写
        async let slow = sut.transcribe([0.1])
        // 再立刻请求切换
        try await Task.sleep(for: .milliseconds(20))
        async let swap: Void = sut.switchTo(descriptor("large-v3"))

        let text = try await slow
        try await swap

        // 进行中的那次必须仍然返回旧模型的结果，不能被换掉
        #expect(text == "来自 base")
        #expect(await sut.descriptor.name == "large-v3")
    }

    @Test("prepare 委托给当前模型")
    func prepareDelegates() async throws {
        let factory = Factory()
        let sut = SwitchableTranscriber(initial: descriptor("base"), makeTranscriber: { @Sendable in factory.make($0) })

        try await sut.prepare()

        #expect(factory.fakes["base"]?.prepareCallCount == 1)
    }
}
