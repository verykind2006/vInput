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

    // MARK: - 搬家：WhisperKit 落在哪 → 目录扫描去哪找

    /// **本批最贵的一条失效链，此前没有任何测试守着。**
    ///
    /// `WhisperKit.download` 把模型落在
    /// `downloadBase/models/argmaxinc/whisperkit-coreml/<variant>`（嵌套写死在
    /// `HubApi.localRepoLocation`），而 `ModelCatalog.discover(in:)` 只看
    /// `root` 的**直接子目录**。不搬家的话，用户下完 1.5GB，面板上一个模型
    /// 都没有——正是这一批存在的理由本身。
    ///
    /// 那几行原本长在 `WhisperKitDownloadBackend.download` 里，而那个函数要真
    /// 联网才跑得到：QA 收尾复验把整段搬家删掉，1316 条测试一条都没红。
    /// 现在真造一份 WhisperKit 的落盘形状跑一遍。
    @Test func relocatesWhisperKitOutputToWhereTheCatalogLooks() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("relocate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let variant = ModelDownloader.variant
        let nested =
            root
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
        for entry in ModelCatalog.requiredEntries {
            try fm.createDirectory(
                at: nested.appendingPathComponent(entry, isDirectory: true),
                withIntermediateDirectories: true)
        }

        // 搬家之前：目录扫描什么都看不见。这一行就是那个 bug 的样子。
        #expect(
            ModelCatalog.discover(in: root.path).isEmpty,
            "WhisperKit 的嵌套落盘位置本来就不该被 discover 看见，这条前提垮了后面都不成立")

        try ModelDownloader.relocate(downloaded: nested, into: root, variant: variant)

        #expect(ModelCatalog.discover(in: root.path).map(\.name) == [variant])

        // 而且必须正好落在 `run` 里 `alreadyPresent` 查的那个位置——差一层的话
        // 重装的人会被要求再下一遍 1.5GB。
        var probed: [String] = []
        let outcome = await ModelDownloader.run(
            root: root.path, alreadyPresent: { probed.append($0); return true },
            backend: UnusedBackend(), source: .official)
        #expect(outcome == .alreadyPresent)
        #expect(probed == [root.appendingPathComponent(variant).path])
    }

    /// 脚手架清掉了，但**tokenizer 缓存不许误伤**。
    ///
    /// tokenizer 也落在 `downloadBase` 下（`models/openai/whisper-large-v3`）。
    /// 一刀 `removeItem(downloadBase/models)` 的话，下一次加载模型就得重新联网
    /// 取 tokenizer——离线用户当场失败。这条约束此前只写在注释里。
    @Test func scaffoldCleanupSparesTheTokenizerCache() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scaffold-\(UUID().uuidString)", isDirectory: true)
        let variant = ModelDownloader.variant
        let nested =
            root
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
        let tokenizer = root
            .appendingPathComponent("models/openai/whisper-large-v3", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try fm.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        fm.createFile(
            atPath: tokenizer.appendingPathComponent("tokenizer.json").path, contents: Data())
        defer { try? fm.removeItem(at: root) }

        try ModelDownloader.relocate(downloaded: nested, into: root, variant: variant)

        #expect(
            fm.fileExists(atPath: tokenizer.appendingPathComponent("tokenizer.json").path),
            "tokenizer 缓存被脚手架清理误伤了——离线用户下一次加载模型会直接失败")
        // 挪空的那条链自己收干净，不留空壳。
        #expect(
            !fm.fileExists(
                atPath: root.appendingPathComponent("models/argmaxinc").path))
    }
}

/// 上面那两条只用到 `alreadyPresent` 的短路，后端一次都不该被调到。
@MainActor
private struct UnusedBackend: ModelDownloadBackend {
    func download(
        variant: String, into root: String, endpoint: String,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        Issue.record("已经在本地了，不该再走下载后端")
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
