import Foundation

/// 加载模型前先算「tokenizer 要不要联网」，要联网就先探一下，不通立刻失败。
///
/// ## 为什么需要它
///
/// `BundledTokenizer` 只打包了 large-v3 一个仓库。用户导入 base 之类的变体、
/// 或将来 WhisperKit 换了仓库名时，`prepare()` 仍会为 tokenizer 联网；而
/// WhisperKit 那条路的失败要等 2 分 18 秒（2026-08-23 实测），期间界面只有
/// 「正在加载模型」。这里用 2.5 秒把同一个结论提前给出，并说清该怎么办。
///
/// ## 判「要不要联网」照抄 WhisperKit，判不出来就不拦
///
/// 仓库名来自 `ModelUtilities.detectVariant` + `tokenizerNameForVariant` 那两张表
/// （按 `vocab_size` 与 `d_model`——后者就是 `encoderDim`）；搜索位置照抄
/// `loadTokenizerIfNeeded` + `loadTokenizer` 的四处。**表上没有的组合一律
/// `.unknownVariant`，不做预检，交给 WhisperKit**——宁可慢，不可把一个其实
/// 能加载的模型错拦下来。
///
/// ## 只在「不在本地」时才探，且探的是 `HF_ENDPOINT` 指向的那个源
///
/// 本地有的话零开销。要联网时读进程的 `HF_ENDPOINT`（HubApi 认的就是它，
/// `HuggingFaceEndpoint` 负责设），映射回 `DownloadSource` 后用向导同一套
/// `EndpointProbe` 探；变量值不是我们认识的两个主机之一时同样不拦。
enum TokenizerPreflight {
    /// WhisperKit 会去要的仓库名。表上没有的返回 nil。
    nonisolated static func repo(vocabSize: Int, dModel: Int) -> String? {
        switch vocabSize {
        case 51866:
            return "openai/whisper-large-v3"
        case 51865:
            switch dModel {
            case 384: return "openai/whisper-tiny"
            case 512: return "openai/whisper-base"
            case 768: return "openai/whisper-small"
            case 1024: return "openai/whisper-medium"
            case 1280: return "openai/whisper-large-v2"
            default: return nil
            }
        case 51864:
            switch dModel {
            case 384: return "openai/whisper-tiny.en"
            case 512: return "openai/whisper-base.en"
            case 768: return "openai/whisper-small.en"
            case 1024: return "openai/whisper-medium.en"
            default: return nil
            }
        default:
            return nil
        }
    }

    /// 从模型目录的 `config.json` 推仓库名。读不到、解不开、表上没有都是 nil。
    nonisolated static func repo(configJSON data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let vocabSize = object["vocab_size"] as? Int,
            let dModel = object["d_model"] as? Int
        else { return nil }
        return repo(vocabSize: vocabSize, dModel: dModel)
    }

    nonisolated static func repo(modelFolder: String) -> String? {
        let url = URL(fileURLWithPath: modelFolder, isDirectory: true)
            .appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return repo(configJSON: data)
    }

    /// WhisperKit 会查的位置，顺序照抄：hub 目录 → `tokenizerFolder` →
    /// 模型目录 → 模型目录下的 hub 形状。
    ///
    /// **`tokenizerFolder` 不是「我们不传就没有」**：`WhisperKit.init` 里是
    /// `config.tokenizerFolder ?? config.downloadBase`（`WhisperKit.swift:75`），
    /// 所以 `downloadBase` 本身也是一处搜索位置。漏掉它的后果是：用户把
    /// `tokenizer.json` 直接放进 `huggingface/` 根目录时，WhisperKit 能加载，
    /// 而这里判成「不在本地」去探网络——离线时就把一个能用的模型错拦了。
    nonisolated static func searchPaths(repo: String, downloadBase: URL, modelFolder: URL?) -> [URL] {
        var paths = [
            BundledTokenizer.hubFolder(downloadBase: downloadBase, repo: repo),
            downloadBase,
        ]
        if let modelFolder {
            paths.append(modelFolder)
            paths.append(BundledTokenizer.hubFolder(downloadBase: modelFolder, repo: repo))
        }
        return paths
    }

    nonisolated static func isLocal(
        repo: String, downloadBase: URL, modelFolder: URL?,
        fileManager fm: FileManager = .default
    ) -> Bool {
        searchPaths(repo: repo, downloadBase: downloadBase, modelFolder: modelFolder).contains {
            fm.fileExists(atPath: $0.appendingPathComponent(BundledTokenizer.marker).path)
        }
    }

    /// 进程此刻的 `HF_ENDPOINT` 指向哪个源。没设 = HubApi 的默认 = 官方源；
    /// 设了个我们不认识的值 = nil。
    nonisolated static func currentSource(environment: [String: String]) -> DownloadSource? {
        guard let value = environment[HuggingFaceEndpoint.variableName] else { return .official }
        let trimmed = value.hasSuffix("/") ? String(value.dropLast()) : value
        return DownloadSource.allCases.first { $0.endpoint == trimmed }
    }

    enum Verdict: Equatable {
        /// 本地就有，不会联网。
        case local(repo: String)
        /// 推不出仓库名，不拦。
        case unknownVariant
        /// 要联网，但 `HF_ENDPOINT` 指向我们不认识的主机，不拦。
        case unknownEndpoint(repo: String)
        /// 要联网，源探通了，放行。
        case willDownload(repo: String, source: DownloadSource)
        /// 要联网，源不通。调用方据此立刻失败。
        case unreachable(repo: String, source: DownloadSource)
    }

    /// 给用户看的那句话：说缺什么、为什么、该做什么。
    nonisolated static func message(repo: String, source: DownloadSource) -> String {
        "缺少 tokenizer（\(repo)），而\(source.displayName)连不上。"
            + "把 tokenizer.json 和 tokenizer_config.json 放进模型目录后再试。"
    }

    /// 决定。只在「不在本地且认识那个源」时才调 `probe`。
    static func check(
        modelFolder: String?,
        downloadBase: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        probe: (DownloadSource) async -> DownloadSource.ProbeResult = { await EndpointProbe.probe($0) },
        fileManager fm: FileManager = .default
    ) async -> Verdict {
        guard let modelFolder, let repo = repo(modelFolder: modelFolder) else {
            return .unknownVariant
        }
        let folderURL = URL(fileURLWithPath: modelFolder, isDirectory: true)
        if isLocal(repo: repo, downloadBase: downloadBase, modelFolder: folderURL, fileManager: fm) {
            return .local(repo: repo)
        }
        guard let source = currentSource(environment: environment) else {
            return .unknownEndpoint(repo: repo)
        }
        switch await probe(source) {
        case .responded: return .willDownload(repo: repo, source: source)
        case .unreachable: return .unreachable(repo: repo, source: source)
        }
    }
}
