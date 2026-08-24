import Foundation
import Testing

@testable import vInput

/// 加载模型前的 tokenizer 预检：要不要联网、联网的那个源通不通。
///
/// 背景（2026-08-23）：模型齐了、tokenizer 缺了、源不通，WhisperKit 要挂
/// 2 分 18 秒才报错。这里用 2.5 秒把同一个结论提前给出。
struct TokenizerPreflightTests {

    // MARK: - 仓库名那张表（照抄 ModelUtilities.detectVariant）

    /// turbo 与 large-v3 的 `vocab_size` 都是 51866，落到同一个仓库——
    /// 这正是「只打包一个仓库就覆盖两个变体」的依据。
    @Test("51866 → large-v3，与 d_model 无关")
    func largeV3FamilyMapsToOneRepo() {
        #expect(TokenizerPreflight.repo(vocabSize: 51866, dModel: 1280) == "openai/whisper-large-v3")
        #expect(TokenizerPreflight.repo(vocabSize: 51866, dModel: 999) == "openai/whisper-large-v3")
    }

    @Test("51865 按 d_model 分 tiny/base/small/medium/large-v2")
    func multilingualSplitsByEncoderDim() {
        #expect(TokenizerPreflight.repo(vocabSize: 51865, dModel: 384) == "openai/whisper-tiny")
        #expect(TokenizerPreflight.repo(vocabSize: 51865, dModel: 512) == "openai/whisper-base")
        #expect(TokenizerPreflight.repo(vocabSize: 51865, dModel: 768) == "openai/whisper-small")
        #expect(TokenizerPreflight.repo(vocabSize: 51865, dModel: 1024) == "openai/whisper-medium")
        #expect(TokenizerPreflight.repo(vocabSize: 51865, dModel: 1280) == "openai/whisper-large-v2")
    }

    @Test("51864 是英文变体")
    func englishOnlyVariants() {
        #expect(TokenizerPreflight.repo(vocabSize: 51864, dModel: 512) == "openai/whisper-base.en")
        #expect(TokenizerPreflight.repo(vocabSize: 51864, dModel: 1024) == "openai/whisper-medium.en")
    }

    /// 表上没有的组合返回 nil——**不拦**。WhisperKit 对未知尺寸会默默退回
    /// base，我们猜错仓库名的代价是把一个能加载的模型错拦下来。
    @Test("表上没有的组合不猜")
    func unknownCombinationsReturnNil() {
        #expect(TokenizerPreflight.repo(vocabSize: 51865, dModel: 4096) == nil)
        #expect(TokenizerPreflight.repo(vocabSize: 51864, dModel: 1280) == nil)
        #expect(TokenizerPreflight.repo(vocabSize: 12345, dModel: 512) == nil)
    }

    /// 真的 turbo `config.json` 的形状：两个键都是整数，别的键一大堆。
    @Test("从 config.json 读 vocab_size 与 d_model")
    func readsRepoFromConfigJSON() {
        let json = #"{"_name_or_path": "x", "d_model": 1280, "vocab_size": 51866, "num_mel_bins": 128}"#
        #expect(TokenizerPreflight.repo(configJSON: Data(json.utf8)) == "openai/whisper-large-v3")
        #expect(TokenizerPreflight.repo(configJSON: Data("not json".utf8)) == nil)
        #expect(TokenizerPreflight.repo(configJSON: Data(#"{"d_model": 1280}"#.utf8)) == nil)
    }

    // MARK: - 搜索位置照抄 WhisperKit

    /// 顺序与 `loadTokenizerIfNeeded` + `loadTokenizer` 一致：hub 目录、
    /// `tokenizerFolder`（WhisperKit 里它默认就是 `downloadBase`）、
    /// 模型目录本身、模型目录下的 hub 形状。
    @Test("四个搜索位置")
    func searchPathsMirrorWhisperKit() {
        let base = URL(fileURLWithPath: "/base", isDirectory: true)
        let model = URL(fileURLWithPath: "/models/turbo", isDirectory: true)
        let paths = TokenizerPreflight.searchPaths(
            repo: "openai/whisper-large-v3", downloadBase: base, modelFolder: model
        ).map(\.path)
        #expect(
            paths == [
                "/base/models/openai/whisper-large-v3",
                "/base",
                "/models/turbo",
                "/models/turbo/models/openai/whisper-large-v3",
            ])
    }

    /// `downloadBase` 根目录里的 `tokenizer.json` 也算本地有——WhisperKit 把
    /// `downloadBase` 当 `tokenizerFolder` 查（`WhisperKit.swift:75`）。
    @Test("downloadBase 根目录里的 tokenizer.json 算本地有")
    func tokenizerAtDownloadBaseRootCountsAsLocal() throws {
        let fixture = try Fixture()
        try "x".write(
            to: fixture.downloadBase.appendingPathComponent("tokenizer.json"),
            atomically: true, encoding: .utf8)
        #expect(
            TokenizerPreflight.isLocal(
                repo: "openai/whisper-base", downloadBase: fixture.downloadBase,
                modelFolder: fixture.modelFolder))
    }

    /// 用户把 `tokenizer.json` 直接放进模型目录（2026-08-23 最后用起来的
    /// 那条路）必须算「本地有」。
    @Test("模型目录里的 tokenizer.json 算本地有")
    func tokenizerInsideModelFolderCountsAsLocal() throws {
        let fixture = try Fixture()
        try "x".write(
            to: fixture.modelFolder.appendingPathComponent("tokenizer.json"),
            atomically: true, encoding: .utf8)
        #expect(
            TokenizerPreflight.isLocal(
                repo: "openai/whisper-base", downloadBase: fixture.downloadBase,
                modelFolder: fixture.modelFolder))
    }

    // MARK: - 现在走的是哪个源

    @Test("HF_ENDPOINT 映射回源；没设 = 官方源；未知主机 = nil")
    func currentSourceFromEnvironment() {
        #expect(TokenizerPreflight.currentSource(environment: [:]) == .official)
        #expect(
            TokenizerPreflight.currentSource(environment: ["HF_ENDPOINT": "https://hf-mirror.com"])
                == .mirror)
        #expect(
            TokenizerPreflight.currentSource(environment: ["HF_ENDPOINT": "https://hf-mirror.com/"])
                == .mirror)
        #expect(
            TokenizerPreflight.currentSource(environment: ["HF_ENDPOINT": "https://example.com"])
                == nil)
    }

    // MARK: - 决定

    /// 本地有：不探、不联网。`probe` 被调到就是错。
    @Test("本地有 tokenizer 时不探")
    func localTokenizerSkipsProbe() async throws {
        let fixture = try Fixture(vocabSize: 51866, dModel: 1280)
        // 种进 hub 目录（生产上 BundledTokenizer 干的事）。
        let hub = BundledTokenizer.hubFolder(
            downloadBase: fixture.downloadBase, repo: "openai/whisper-large-v3")
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        try "x".write(to: hub.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)

        var probed = false
        let verdict = await TokenizerPreflight.check(
            modelFolder: fixture.modelFolder.path, downloadBase: fixture.downloadBase,
            environment: [:], probe: { _ in
                probed = true
                return .unreachable
            })
        #expect(verdict == .local(repo: "openai/whisper-large-v3"))
        #expect(!probed, "本地明明有 tokenizer 还去探网络")
    }

    /// 不在本地、源不通：`.unreachable`，带仓库名与源名——那句话要给用户看。
    @Test("不在本地且源不通时立刻判死")
    func missingAndUnreachableFailsFast() async throws {
        let fixture = try Fixture(vocabSize: 51865, dModel: 512)
        var probedSource: DownloadSource?
        let verdict = await TokenizerPreflight.check(
            modelFolder: fixture.modelFolder.path, downloadBase: fixture.downloadBase,
            environment: ["HF_ENDPOINT": "https://hf-mirror.com"],
            probe: { source in
                probedSource = source
                return .unreachable
            })
        #expect(verdict == .unreachable(repo: "openai/whisper-base", source: .mirror))
        #expect(probedSource == .mirror, "探的不是 HF_ENDPOINT 指向的那个源")
    }

    /// 不在本地、源通：放行，让 WhisperKit 去下。
    @Test("不在本地但源通时放行")
    func missingButReachableProceeds() async throws {
        let fixture = try Fixture(vocabSize: 51865, dModel: 512)
        let verdict = await TokenizerPreflight.check(
            modelFolder: fixture.modelFolder.path, downloadBase: fixture.downloadBase,
            environment: [:], probe: { _ in .responded(millis: 30) })
        #expect(verdict == .willDownload(repo: "openai/whisper-base", source: .official))
    }

    /// 推不出仓库名：不探、不拦。
    @Test("推不出仓库名时不探不拦")
    func unknownVariantIsNotBlocked() async throws {
        let fixture = try Fixture(vocabSize: 1, dModel: 1)
        var probed = false
        let verdict = await TokenizerPreflight.check(
            modelFolder: fixture.modelFolder.path, downloadBase: fixture.downloadBase,
            environment: [:], probe: { _ in
                probed = true
                return .unreachable
            })
        #expect(verdict == .unknownVariant)
        #expect(!probed)
    }

    /// `HF_ENDPOINT` 指向不认识的主机：不探、不拦。
    @Test("未知主机不探不拦")
    func unknownEndpointIsNotBlocked() async throws {
        let fixture = try Fixture(vocabSize: 51865, dModel: 512)
        let verdict = await TokenizerPreflight.check(
            modelFolder: fixture.modelFolder.path, downloadBase: fixture.downloadBase,
            environment: ["HF_ENDPOINT": "https://example.com"], probe: { _ in .unreachable })
        #expect(verdict == .unknownEndpoint(repo: "openai/whisper-base"))
    }

    /// 那句话要说三件事：缺什么、哪个源不通、该做什么。
    @Test("失败文案说清缺什么、哪个源、该做什么")
    func messageNamesRepoSourceAndRemedy() {
        let text = TokenizerPreflight.message(repo: "openai/whisper-base", source: .official)
        #expect(text.contains("openai/whisper-base"))
        #expect(text.contains(DownloadSource.official.displayName))
        #expect(text.contains("tokenizer.json"))
        #expect(text.contains("模型目录"))
    }

    // MARK: - 接上了没有（源码扫描）

    /// `prepare()` 里种入与预检两步都得在造 `WhisperKit` 之前。
    ///
    /// 这两行各只有一处调用，删掉没有任何编译错误；而删掉的后果分别是
    /// 「离线机器上模型齐了也加载不了」与「回到两分钟才报错」。
    @Test("prepare() 先种入、再预检、再造 WhisperKit")
    @MainActor
    func prepareSeedsAndChecksBeforeConstructingWhisperKit() throws {
        let source = OnboardingWiringTests.codeOnly(
            try OnboardingWiringTests.source("Sources/vInput/Transcribe/WhisperKitTranscriber.swift"))
        let body = try #require(
            OnboardingWiringTests.functionBody(source, signature: "func prepare() async throws"),
            "找不到 prepare() 的函数体")
        let seed = body.range(of: "BundledTokenizer.seedIfNeeded(")
        let check = body.range(of: "TokenizerPreflight.check(")
        let construct = body.range(of: "try await WhisperKit(")
        #expect(seed != nil, "prepare() 里没有 BundledTokenizer.seedIfNeeded(：离线机器上模型齐了也加载不了")
        #expect(check != nil, "prepare() 里没有 TokenizerPreflight.check(：又回到两分钟才报错")
        #expect(construct != nil, "prepare() 里找不到 WhisperKit( 的构造")
        if let seed, let check, let construct {
            #expect(seed.lowerBound < construct.lowerBound, "种入排在造 WhisperKit 之后：种了也没人查")
            #expect(check.lowerBound < construct.lowerBound, "预检排在造 WhisperKit 之后：等于没检")
            // **种入必须排在预检之前。** 只查「两步都在造 WhisperKit 之前」是
            // 不够的：把预检提到种入前面，干净机器上种入还没发生，预检就会
            // 判「不在本地 + 源不通」直接抛错——**恰好把本次要修的那个场景
            // 重新弄坏**（模型齐了、包里带着 tokenizer，却说连不上）。
            // 2026-08-24 变异 N9 实测存活，这一行是补上的判据。
            #expect(
                seed.lowerBound < check.lowerBound,
                "预检排在种入之前：包里带着 tokenizer 也会被判成「不在本地且源不通」")
        }
        // 判死那一支必须真的 throw，而不是只记一行日志继续往下走。
        //
        // **只看 `case .unreachable` 到下一个 `case` 之间那几行。** 第一版从
        // `case .unreachable` 一直找到函数末尾，而 `prepare()` 后面的 `catch`
        // 里本来就有一句 `throw TranscribeError.engineFailed(`——把判死那支的
        // throw 换成空操作，测试照样绿（2026-08-24 变异 M13 实测存活）。
        let unreachableBranch: Substring? = {
            guard let start = body.range(of: "case .unreachable") else { return nil }
            let rest = body[start.upperBound...]
            let end = rest.range(of: "\n        case ")?.lowerBound ?? rest.endIndex
            return rest[..<end]
        }()
        #expect(unreachableBranch != nil, "prepare() 里没有 case .unreachable 那一支")
        let throwsOnUnreachable =
            unreachableBranch?.contains("throw TranscribeError.engineFailed(") ?? false
        #expect(throwsOnUnreachable, "预检判死那一支里没有 throw：日志记了，用户照样等两分钟")
    }

    // MARK: - 夹具

    private struct Fixture {
        let downloadBase: URL
        let modelFolder: URL

        init(vocabSize: Int? = nil, dModel: Int? = nil) throws {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("vinput-preflight-\(UUID().uuidString)", isDirectory: true)
            downloadBase = tmp.appendingPathComponent("huggingface", isDirectory: true)
            modelFolder = tmp.appendingPathComponent("model", isDirectory: true)
            try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)
            if let vocabSize, let dModel {
                let json = #"{"vocab_size": \#(vocabSize), "d_model": \#(dModel), "model_type": "whisper"}"#
                try json.write(
                    to: modelFolder.appendingPathComponent("config.json"),
                    atomically: true, encoding: .utf8)
            }
        }
    }
}
