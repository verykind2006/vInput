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

    /// 按调用顺序发放预置替身，并记录每次收到的 descriptor。
    ///
    /// 与 `Factory` 不同：同名 descriptor 也发新实例——rebuild 的测试
    /// 需要区分「重建前后是不是同一个底层转写器」。
    private final class SequencedFactory: @unchecked Sendable {
        private let queue: [FakeTranscriber]
        private var received: [ModelDescriptor] = []
        private let lock = NSLock()

        init(_ fakes: [FakeTranscriber]) { self.queue = fakes }

        func make(_ d: ModelDescriptor) -> Transcriber {
            lock.lock(); defer { lock.unlock() }
            received.append(d)
            precondition(received.count <= queue.count, "SequencedFactory 预置不足")
            return queue[received.count - 1]
        }

        var buildCount: Int {
            lock.lock(); defer { lock.unlock() }
            return received.count
        }

        var lastDescriptor: ModelDescriptor? {
            lock.lock(); defer { lock.unlock() }
            return received.last
        }
    }

    @Test("rebuild 用同一个 descriptor 无条件重建")
    func rebuildReconstructsWithSameDescriptor() async throws {
        // 输入语言是构造参数——换语言不换模型时 switchTo 的同名 guard
        // 直接返回，rebuild 必须无条件重建。
        let first = FakeTranscriber()
        first.result = "旧实例"
        let second = FakeTranscriber()
        second.result = "新实例"
        let factory = SequencedFactory([first, second])
        let initial = descriptor("base")
        let sut = SwitchableTranscriber(initial: initial, makeTranscriber: { @Sendable in factory.make($0) })

        try await sut.rebuild()

        // init 一次 + rebuild 一次，且第二次收到的 descriptor 与初始相同
        #expect(factory.buildCount == 2)
        #expect(factory.lastDescriptor == initial)
        // 关键：转写必须走新实例——只数构造次数抓不住「建了却没接上」
        let text = try await sut.transcribe([0.1])
        #expect(text == "新实例")
        #expect(await sut.descriptor == initial)
    }

    @Test("rebuild 挂在 prepare 时被并发 switchTo 超越——放弃提交，不覆盖新模型")
    func rebuildOvertakenBySwitchDoesNotClobber() async throws {
        // prepare 挂起窗口（真实场景里模型加载可达数十秒）内并发的
        // switchTo 会完整跑完并提交 current+descriptor；rebuild 恢复后
        // 必须放弃提交，否则 current 被换回旧 descriptor 的实例、与
        // descriptor 脱钩。
        let first = FakeTranscriber()
        first.result = "旧的"
        let rebuildCandidate = FakeTranscriber()
        rebuildCandidate.result = "rebuild 建的"
        rebuildCandidate.prepareDelay = .milliseconds(120)
        let switched = FakeTranscriber()
        switched.result = "来自新模型"
        let factory = SequencedFactory([first, rebuildCandidate, switched])
        let sut = SwitchableTranscriber(initial: descriptor("base"), makeTranscriber: { @Sendable in factory.make($0) })

        // 先让 rebuild 挂在慢 prepare 上
        async let slowRebuild: Void = sut.rebuild()
        try await Task.sleep(for: .milliseconds(20))
        // 挂起窗口内完成一次切换
        try await sut.switchTo(descriptor("large-v3"))
        try await slowRebuild

        // 转写必须走 switchTo 提交的新模型，不能被 rebuild 覆盖回去
        let text = try await sut.transcribe([0.1])
        #expect(text == "来自新模型")
        #expect(await sut.descriptor.name == "large-v3")
    }

    @Test("rebuild 失败时保持原转写器可用")
    func rebuildKeepsOldTranscriberWhenPrepareFails() async {
        // 与 switchTo 同一条保证：先建新的、prepare() 成功才替换。
        let first = FakeTranscriber()
        first.result = "老的还在"
        let broken = FakeTranscriber()
        broken.prepareError = TranscribeError.modelNotReady
        let factory = SequencedFactory([first, broken])
        let sut = SwitchableTranscriber(initial: descriptor("base"), makeTranscriber: { @Sendable in factory.make($0) })

        await #expect(throws: TranscribeError.modelNotReady) {
            try await sut.rebuild()
        }

        let text = try? await sut.transcribe([0.1])
        #expect(text == "老的还在")
    }
}
