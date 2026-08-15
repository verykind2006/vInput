import Foundation
import Testing

@testable import vInput

@Suite("一次性加载闸门")
struct OneShotLoaderTests {
    /// 闸门存在的头号理由：调用方（带 3 秒超时的校正）被取消时，
    /// 2 GB 模型的加载必须照常跑完，否则永远等不到就绪。
    @Test("加载不随调用方取消而中断")
    func loadSurvivesCallerCancellation() async throws {
        let counter = LoadCounter()
        let loader = OneShotLoader<Int> {
            await counter.noteStart()
            // 故意用可取消的 sleep：加载若是调用方的结构化子任务，
            // 这里会立刻抛错退出，finished 永远是 0。
            try await Task.sleep(for: .milliseconds(300))
            await counter.noteFinish()
            return 42
        }

        let caller = Task { try await loader.value() }
        try await Task.sleep(for: .milliseconds(50))
        caller.cancel()

        try await Task.sleep(for: .milliseconds(700))
        #expect(await counter.finished == 1)
        #expect(await loader.ready == 42)
    }

    /// 两次调用之间隔着 await，仅凭「值还是 nil」判重会漏掉在途的那次。
    @Test("并发调用只加载一次")
    func concurrentCallsLoadOnce() async {
        let counter = LoadCounter()
        let loader = OneShotLoader<Int> {
            await counter.noteStart()
            try await Task.sleep(for: .milliseconds(200))
            await counter.noteFinish()
            return 7
        }

        await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<8 {
                group.addTask { try? await loader.value() }
            }
            for await value in group {
                #expect(value == 7)
            }
        }

        #expect(await counter.started == 1)
        #expect(await counter.finished == 1)
    }

    /// 注入路径靠 `ready` 判断该不该校正，它一旦会等就失去意义。
    @Test("ready 在加载途中立即返回 nil")
    func readyNeverWaits() async throws {
        let loader = OneShotLoader<Int> {
            await uninterruptibleSleep(.milliseconds(600))
            return 1
        }
        let loading = Task { try await loader.value() }
        try await Task.sleep(for: .milliseconds(50))

        let start = ContinuousClock.now
        let ready = await loader.ready
        let elapsed = ContinuousClock.now - start

        #expect(ready == nil)
        #expect(elapsed < .milliseconds(200), "读 ready 等了加载，实际耗时 \(elapsed)")
        _ = try await loading.value
    }

    /// 失败不缓存：用户把指错的模型目录改对后，不该还要重启才生效。
    @Test("加载失败后可重试")
    func retriesAfterFailure() async {
        let counter = LoadCounter()
        let loader = OneShotLoader<Int> {
            await counter.noteStart()
            guard await counter.started > 1 else {
                throw CorrectorError.engineFailed("boom")
            }
            await counter.noteFinish()
            return 7
        }

        await #expect(throws: CorrectorError.engineFailed("boom")) {
            try await loader.value()
        }
        #expect(await loader.ready == nil)

        let retried = try? await loader.value()
        #expect(retried == 7)
        #expect(await counter.started == 2)
    }

    @Test("就绪后不再重复加载")
    func loadsOnceAcrossSequentialCalls() async throws {
        let counter = LoadCounter()
        let loader = OneShotLoader<Int> {
            await counter.noteStart()
            await counter.noteFinish()
            return 3
        }

        #expect(try await loader.value() == 3)
        #expect(try await loader.value() == 3)
        #expect(await counter.started == 1)
    }
}
