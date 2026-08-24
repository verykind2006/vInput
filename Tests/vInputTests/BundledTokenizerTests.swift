import Foundation
import Testing
import WhisperKit

@testable import vInput

/// 随 app 分发的 tokenizer：包里有没有、种到的是不是 WhisperKit 查的那个位置。
///
/// 背景（2026-08-23 太太的机器）：模型齐了，`prepare()` 为 2.8 MB 的 tokenizer
/// 联网两分钟后失败。真正的验收（`HF_ENDPOINT` 指向死地址、`prepare()` 仍过）
/// 要真模型，测试进程跑不到，列在真机清单里；这里守的是能守的三件事。
struct BundledTokenizerTests {

    // MARK: - 包里真的有

    /// `Bundle.module` 里必须有 large-v3 的三个文件，且 `tokenizer.json` 是
    /// 真的那份（2.4 MB），不是占位符。
    ///
    /// 这一条守着 `Package.swift` 的 `resources:` 声明的**一半**：删掉它，
    /// `Bundle.module` 编译都过不了（变异 N8 实测）。
    ///
    /// **另一半它守不住**：改成 `.process` 之后本文件 10 条**全绿**
    /// （2026-08-24 两次实测，变异 M21）——测试 bundle 里 `Tokenizers/` 仍然
    /// 找得到，而**打包后的 app** 里那条嵌套路径没了、运行时种入静默跳过。
    /// 守那一半的是 `build-app.sh` 里查完整嵌套路径的那道检查（改成 `.process`
    /// 后构建退出码 1）。改 `resources:` 的人别以为这里兜得住。
    @Test("应用包里带着 large-v3 的 tokenizer")
    func bundleShipsLargeV3Tokenizer() throws {
        let root = try #require(BundledTokenizer.resourceRoot())
        let repo = root.appendingPathComponent("openai/whisper-large-v3", isDirectory: true)
        for file in BundledTokenizer.files {
            let path = repo.appendingPathComponent(file).path
            #expect(FileManager.default.fileExists(atPath: path), "包里缺 \(file)")
        }
        let size =
            (try? FileManager.default.attributesOfItem(
                atPath: repo.appendingPathComponent("tokenizer.json").path)[.size] as? Int) ?? 0
        #expect(size > 2_000_000, "tokenizer.json 只有 \(size) 字节，不是完整的那份")
    }

    /// `repos` 表里的每一项包里都得有——加了行没放文件的表现是
    /// 「日志说缺仓库」，而用户看到的还是两分钟加载中。
    @Test("repos 表里的每个仓库包里都有")
    func everyListedRepoIsShipped() throws {
        let root = try #require(BundledTokenizer.resourceRoot())
        for repo in BundledTokenizer.repos {
            let marker = root.appendingPathComponent(repo).appendingPathComponent(BundledTokenizer.marker)
            #expect(FileManager.default.fileExists(atPath: marker.path), "包里没有 \(repo)")
        }
    }

    // MARK: - 种到 WhisperKit 查的那个位置

    /// 种入路径必须与 WhisperKit 自己算的 hub 目录逐字相同。
    ///
    /// 拿**真的** `HubApiWrapper` 算，而不是再写一遍 `models/<repo>`：
    /// 两边各写一份的话，WhisperKit 升级改了拼法，这里照样绿，而种进去的
    /// 文件从此没人看。
    @Test("种入路径就是 HubApi 的 localRepoLocation")
    func seedTargetMatchesHubApi() {
        let base = URL(fileURLWithPath: "/tmp/vinput-tokenizer-base", isDirectory: true)
        let expected = HubApiWrapper(downloadBase: base)
            .localRepoLocation(HubApiWrapper.Repo(id: "openai/whisper-large-v3"))
        let ours = BundledTokenizer.hubFolder(downloadBase: base, repo: "openai/whisper-large-v3")
        #expect(ours.standardizedFileURL.path == expected.standardizedFileURL.path)
    }

    /// 干净的 downloadBase：种完三个文件都在，且返回 `.seeded`。
    @Test("干净目录种入三个文件")
    func seedsAllFilesIntoCleanBase() throws {
        let fixture = try Fixture()
        let outcome = BundledTokenizer.seed(
            repo: "openai/whisper-large-v3", from: fixture.resourceRoot, into: fixture.downloadBase)
        #expect(outcome == .seeded(repo: "openai/whisper-large-v3"))
        let target = BundledTokenizer.hubFolder(
            downloadBase: fixture.downloadBase, repo: "openai/whisper-large-v3")
        for file in BundledTokenizer.files {
            let content = try String(contentsOf: target.appendingPathComponent(file), encoding: .utf8)
            #expect(content == "bundled:\(file)", "\(file) 的内容不是包里那份")
        }
    }

    /// 目标已有 `tokenizer.json`（用户手放的、上次种的、WhisperKit 下的）：
    /// **一个字节都不动**，返回 `.alreadyPresent`。
    ///
    /// 判据是内容：只看返回值的话，「返回 alreadyPresent 但照样覆盖」这种
    /// 变异抓不到。
    @Test("已有 tokenizer.json 时不覆盖")
    func doesNotOverwriteExistingTokenizer() throws {
        let fixture = try Fixture()
        let target = BundledTokenizer.hubFolder(
            downloadBase: fixture.downloadBase, repo: "openai/whisper-large-v3")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "user-provided".write(
            to: target.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)

        let outcome = BundledTokenizer.seed(
            repo: "openai/whisper-large-v3", from: fixture.resourceRoot, into: fixture.downloadBase)
        #expect(outcome == .alreadyPresent(repo: "openai/whisper-large-v3"))
        let kept = try String(
            contentsOf: target.appendingPathComponent("tokenizer.json"), encoding: .utf8)
        #expect(kept == "user-provided", "用户自己放的 tokenizer.json 被覆盖了")
        #expect(
            !FileManager.default.fileExists(
                atPath: target.appendingPathComponent("tokenizer_config.json").path),
            "说是 alreadyPresent，却往目录里补了别的文件")
    }

    /// 资源目录里没有这个仓库：如实报 `.sourceMissing`，目标目录不建。
    @Test("包里没有的仓库报 sourceMissing")
    func reportsMissingSource() throws {
        let fixture = try Fixture()
        let outcome = BundledTokenizer.seed(
            repo: "openai/whisper-base", from: fixture.resourceRoot, into: fixture.downloadBase)
        #expect(outcome == .sourceMissing(repo: "openai/whisper-base"))
        let target = BundledTokenizer.hubFolder(
            downloadBase: fixture.downloadBase, repo: "openai/whisper-base")
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    /// `tokenizer.json` 必须最后拷：它是「已存在」的判据，先拷它的话中途
    /// 失败会留下一个看起来完整、实际残缺、下次还会被跳过的目录。
    @Test("tokenizer.json 排在文件表最后")
    func markerIsCopiedLast() {
        #expect(BundledTokenizer.files.last == BundledTokenizer.marker)
    }

    // MARK: - 生产入口

    /// `seedIfNeeded` 走的是 `repos` 表，且种入那一次会记日志，
    /// 第二次什么都不记（不然每次启动都刷一行）。
    @Test("seedIfNeeded 只在真种入时记日志")
    func seedIfNeededLogsOnlyWhenItSeeds() throws {
        let fixture = try Fixture()
        var lines: [String] = []
        let first = BundledTokenizer.seedIfNeeded(
            downloadBase: fixture.downloadBase, resourceRoot: fixture.resourceRoot,
            log: { lines.append($0) })
        #expect(first == [.seeded(repo: "openai/whisper-large-v3")])
        #expect(lines.count == 1)
        #expect(lines.first?.contains("openai/whisper-large-v3") == true)

        lines = []
        let second = BundledTokenizer.seedIfNeeded(
            downloadBase: fixture.downloadBase, resourceRoot: fixture.resourceRoot,
            log: { lines.append($0) })
        #expect(second == [.alreadyPresent(repo: "openai/whisper-large-v3")])
        #expect(lines.isEmpty)
    }

    /// 资源目录找不到时不崩、不种、记一行。
    @Test("没有资源目录时记一行就退")
    func missingResourceRootIsLoggedNotFatal() throws {
        let fixture = try Fixture()
        var lines: [String] = []
        let outcomes = BundledTokenizer.seedIfNeeded(
            downloadBase: fixture.downloadBase, resourceRoot: nil, log: { lines.append($0) })
        #expect(outcomes.isEmpty)
        #expect(lines.count == 1)
    }

    // MARK: - 种进去的那份 WhisperKit 真的能离线加载

    /// **这一条最接近验收口径**：把包里那份种进一个干净的 `downloadBase`，
    /// `HF_ENDPOINT` 指向一个必死的地址，然后调 WhisperKit **真的**
    /// `ModelUtilities.loadTokenizer`——它就是 `prepare()` 里取 tokenizer 的
    /// 那个入口。加载成功且能把中文编解码回来，才算「模型齐了就能说话」。
    ///
    /// 前面几条只证明「文件拷到了 WhisperKit 会查的路径上」；文件本身坏了
    /// （比如包里放了个占位符、或 `tokenizer_config.json` 缺了）它们照样绿，
    /// 而 WhisperKit 本地加载失败后会**默默退回联网**（`loadTokenizer` 的
    /// `catch` 直接 fall through）——那正是 2026-08-23 那两分钟。死地址保证
    /// 退回联网时立刻失败而不是挂两分钟，于是「本地能不能加载」这个问题
    /// 在这里有了唯一的红绿判据。
    @Test("种进去的 tokenizer WhisperKit 能离线加载")
    func seededTokenizerLoadsOfflineThroughWhisperKit() async throws {
        let resourceRoot = try #require(BundledTokenizer.resourceRoot())
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vinput-seeded-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let outcome = BundledTokenizer.seed(
            repo: "openai/whisper-large-v3", from: resourceRoot, into: base)
        #expect(outcome == .seeded(repo: "openai/whisper-large-v3"))

        // 死地址：127.0.0.1 的丢弃端口，连接被立刻拒绝。只在本测试期间生效，
        // 跑完还原（同 `HuggingFaceEndpointTests.setenvIsVisibleToProcessInfoInTheSameProcess`）。
        let name = HuggingFaceEndpoint.variableName
        let previous = ProcessInfo.processInfo.environment[name]
        setenv(name, "http://127.0.0.1:9", 1)
        defer {
            if let previous { setenv(name, previous, 1) } else { unsetenv(name) }
        }

        let tokenizer = try await ModelUtilities.loadTokenizer(for: .largev3, tokenizerFolder: base)
        let ids = tokenizer.encode(text: "你好，世界")
        #expect(!ids.isEmpty)
        // `encode` 会带上 `<|startoftranscript|>` 等特殊 token，`decode` 原样吐回；
        // 判「中文完整地在里面」即可。
        #expect(tokenizer.decode(tokens: ids).contains("你好，世界"))
    }

    // MARK: - 夹具

    /// 一个假的资源目录（三个内容可辨认的小文件）+ 一个干净的 downloadBase。
    private struct Fixture {
        let resourceRoot: URL
        let downloadBase: URL

        init() throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("vinput-bundled-tokenizer-\(UUID().uuidString)", isDirectory: true)
            resourceRoot = tmp.appendingPathComponent("Tokenizers", isDirectory: true)
            downloadBase = tmp.appendingPathComponent("huggingface", isDirectory: true)
            let repo = resourceRoot.appendingPathComponent("openai/whisper-large-v3", isDirectory: true)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
            for file in BundledTokenizer.files {
                try "bundled:\(file)".write(
                    to: repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
        }
    }
}
