import Foundation
import Testing

@testable import vInput

/// 模型下载包装：只下 turbo，带源与进度，失败说清是哪个源。
@MainActor
struct ModelDownloaderTests {
    @Test func progressBecomesHumanReadable() {
        #expect(ModelDownloader.percentText(0.0) == "0%")
        #expect(ModelDownloader.percentText(0.5) == "50%")
        #expect(ModelDownloader.percentText(1.0) == "100%")
        // 越界不许显示成 -3% 或 137%
        #expect(ModelDownloader.percentText(-0.2) == "0%")
        #expect(ModelDownloader.percentText(1.5) == "100%")
    }

    /// 下载哪个模型是定死的：用户 2026-08-21 定「只用 turbo」。
    @Test func downloadsTurboOnly() {
        #expect(ModelDownloader.variant == "openai_whisper-large-v3-v20240930_turbo")
    }

    /// 已经在本地就不下——重装的人不该再等 1.5GB。
    @Test func skipsWhenModelAlreadyPresent() async {
        let fake = FakeDownloadBackend()
        let outcome = await ModelDownloader.run(
            root: "/models", alreadyPresent: { _ in true }, backend: fake, source: .official)
        #expect(outcome == .alreadyPresent)
        #expect(fake.calls.isEmpty)
    }

    @Test func reportsSourceUsedOnSuccess() async {
        let fake = FakeDownloadBackend()
        let outcome = await ModelDownloader.run(
            root: "/models", alreadyPresent: { _ in false }, backend: fake, source: .mirror)
        #expect(outcome == .downloaded(source: .mirror))
        #expect(fake.calls == ["https://hf-mirror.com"])
    }

    /// 失败要带上是哪个源失败的——出问题时第一时间能分清是模型坏了
    /// 还是源坏了。
    @Test func failureCarriesTheSource() async {
        let fake = FakeDownloadBackend()
        fake.shouldFail = true
        let outcome = await ModelDownloader.run(
            root: "/models", alreadyPresent: { _ in false }, backend: fake, source: .mirror)
        #expect(outcome == .failed(source: .mirror))
    }

    /// 进度要真的转发到调用方——向导的进度条整个建立在这个闭包被转发上，
    /// fake 里 `onProgress(0.5)` 若被 `run` 悄悄丢掉，进度条会一直卡在 0%
    /// 却没有任何测试报红。不属于计划要求的 5 条，但值得补一条钉住。
    @Test func forwardsProgressToCaller() async {
        let fake = FakeDownloadBackend()
        var observed: [Double] = []
        _ = await ModelDownloader.run(
            root: "/models", alreadyPresent: { _ in false }, backend: fake, source: .official,
            onProgress: { observed.append($0) })
        #expect(observed == [0.5])
    }
}

@MainActor
private final class FakeDownloadBackend: ModelDownloadBackend {
    var calls: [String] = []
    var shouldFail = false
    func download(
        variant: String, into root: String, endpoint: String,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        calls.append(endpoint)
        onProgress(0.5)
        if shouldFail { throw ModelDownloadError.transportFailed }
    }
}
