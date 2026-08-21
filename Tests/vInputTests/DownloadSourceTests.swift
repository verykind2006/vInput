import Foundation
import Testing

@testable import vInput

/// 下载源选择：官方与国内镜像并发探测，谁先响应用谁。
///
/// 用户 2026-08-21 在国内，9 月 1 日去西班牙——**同一套代码两边都要能用，
/// 且都不该问用户任何问题**。
struct DownloadSourceTests {
    @Test func endpointsAreStable() {
        #expect(DownloadSource.official.endpoint == "https://huggingface.co")
        #expect(DownloadSource.mirror.endpoint == "https://hf-mirror.com")
    }

    @Test func picksWhicheverRespondsFirst() async {
        let picked = await DownloadSource.choose(
            probe: { source in source == .mirror ? .responded(millis: 120) : .responded(millis: 900) },
            forced: nil)
        #expect(picked == .mirror)
    }

    @Test func picksOfficialWhenItWinsAbroad() async {
        let picked = await DownloadSource.choose(
            probe: { source in source == .official ? .responded(millis: 80) : .responded(millis: 400) },
            forced: nil)
        #expect(picked == .official)
    }

    /// 一个不通：用通的那个，不要因为「主源优先」而失败。
    @Test func fallsBackWhenOneIsUnreachable() async {
        let picked = await DownloadSource.choose(
            probe: { source in source == .official ? .unreachable : .responded(millis: 700) },
            forced: nil)
        #expect(picked == .mirror)
    }

    /// 都不通：返回 nil，让调用方去说「两个源都连不上」并给手动导入入口，
    /// 而不是硬选一个然后卡在下载里。
    @Test func returnsNilWhenBothUnreachable() async {
        let picked = await DownloadSource.choose(probe: { _ in .unreachable }, forced: nil)
        #expect(picked == nil)
    }

    /// 钉住「并发」本身，而不只是钉「结果相同」——把 `async let` 悄悄改回
    /// 顺序 `await` 之后，前面几条单靠结果值的用例测不出区别（结果确实一样，
    /// 只是不再并发），所以单独测「两次探测有没有同时在飞过」。
    ///
    /// 不量毫秒：`async let` 在声明处就立刻启动子任务，不等第一次 `await`，
    /// 所以只要探测体里有一次 `Task.yield()`，并发版必然会在某一刻让两个
    /// 探测都处于「进行中」；顺序版第一个探测会跑到底（`await` 完）才叫
    /// 第二个，峰值永远是 1。这测的是调度结构，不是「谁比谁快多少毫秒」，
    /// 所以不脆弱。
    @Test func probesRunConcurrently() async {
        let recorder = ConcurrencyPeakRecorder()
        _ = await DownloadSource.choose(
            probe: { _ in
                await recorder.enter()
                // 让出**三次**而不是一次：一次 `Task.yield()` 只给一次调度
                // 机会，若执行器恰好又立刻恢复了本任务、另一个探测一次都没
                // 排上，peak 会是 1 而测试假红。多让几次把这个概率压下去，
                // 代价为零。（这不是在等时间——判据仍是调度结构，不是毫秒。）
                for _ in 0..<3 { await Task.yield() }
                await recorder.exit()
                return .responded(millis: 1)
            },
            forced: nil)
        let peak = await recorder.observedPeak
        #expect(peak == 2)
    }

    /// 用户在设置里强制指定时，不再探测——探测只是「不用问用户」的手段，
    /// 用户真的表达了偏好就该照办。
    ///
    /// `probe` 参数类型是 `@Sendable`，不能直接捕获、修改一个普通的
    /// `var probed`（严格并发下编译器会拒绝跨 actor 边界共享可变状态）。
    /// 用一个 actor 当计数器：它天然是并发安全的，且不需要改
    /// `DownloadSource.choose` 的签名或语义。
    @Test func forcedChoiceSkipsProbing() async {
        let recorder = ProbeCallRecorder()
        let picked = await DownloadSource.choose(
            probe: { _ in
                await recorder.record()
                return .unreachable
            },
            forced: .official)
        #expect(picked == .official)
        let probed = await recorder.wasCalled
        #expect(!probed)
    }
}

/// 记录 `probe` 有没有被调用过。用 actor 而不是普通 `var`，因为
/// `DownloadSource.choose` 的 `probe` 参数标了 `@Sendable`——普通可变变量
/// 跨这个边界会被编译器拒绝（或在非严格模式下产生数据竞争警告）。
private actor ProbeCallRecorder {
    private(set) var wasCalled = false

    func record() {
        wasCalled = true
    }
}

/// 记录探测的「同时在飞」峰值，见 `probesRunConcurrently` 的注释。
private actor ConcurrencyPeakRecorder {
    private var inFlight = 0
    private(set) var observedPeak = 0

    func enter() {
        inFlight += 1
        observedPeak = max(observedPeak, inFlight)
    }

    func exit() {
        inFlight -= 1
    }
}
