import Foundation

/// 随 app 分发的 tokenizer，加载模型前种进 WhisperKit 第一个查的目录。
///
/// ## 为什么要有它（2026-08-23，太太的机器）
///
/// 模型三个 `.mlmodelc` 齐了，`prepare()` 仍要为 2.8 MB 的 tokenizer 联网。
/// 那台机器上官方源与镜像都不通，用户看到的是两分钟「正在加载模型」，
/// 然后一句 `Download failed: The request timed out.`。最后是人工把
/// `tokenizer.json` 塞进模型目录才用起来。
///
/// M9 第二批曾否决「打包 tokenizer」（`HuggingFaceEndpoint` 的类型注释），
/// 理由是它治不了「去了另一台主机」。那条理由仍成立——所以 `HF_ENDPOINT`
/// 那一路保留；本类型补的是另一半：**主机本身不通时，根本不需要联网。**
///
/// ## 只打包 `openai/whisper-large-v3` 一个仓库
///
/// 它同时覆盖 turbo 与 large-v3（`ModelUtilities.tokenizerNameForVariant`
/// 对 `.largev3` 返回它，turbo 的 `vocab_size` 51866 也判成 `.largev3`）。
/// 向导只下 turbo，用户拷来拷去的也是这两个。其余变体各 2–3 MB，
/// 全打进去多 20 MB 换不到任何真实用户；没打包的走 `TokenizerPreflight`
/// 快速失败那条路。
///
/// ## 种到 hub 目录，不种进用户的模型目录
///
/// `ModelUtilities.loadTokenizer` 的搜索顺序：`<downloadBase>/models/<repo>/`
/// → `tokenizerFolder` → `modelFolder` → `modelFolder/models/<repo>/`。
/// 种进第一个：它在应用支持目录里、是我们自己的地盘、卸载清单已覆盖。
/// 用户的模型目录可能在 `~/Documents`（TCC 保护）或只读盘上，往里写不是
/// 我们该做的事。
///
/// ## 幂等，且 `tokenizer.json` 最后拷
///
/// 目标目录已有 `tokenizer.json` 就什么都不动——不管是用户手放的、上次种的
/// 还是 WhisperKit 自己下的。`tokenizer.json` 排在文件表最后：它是「已存在」
/// 的判据，先拷它再拷别的，中途失败会留下一个看起来完整、实际缺
/// `tokenizer_config.json` 的目录，下次启动还会跳过它。
enum BundledTokenizer {
    /// 打包了哪些仓库。加一个仓库 = 往 `Resources/Tokenizers/` 放一个目录
    /// + 这里加一行。
    static let repos = ["openai/whisper-large-v3"]

    /// 每个仓库目录里的文件，**`marker` 必须最后**（理由见类型注释）。
    static let files = ["config.json", "tokenizer_config.json", "tokenizer.json"]

    /// 「这个目录里有 tokenizer」的判据——与 `ModelUtilities.loadTokenizer`
    /// 的 `hasTokenizer(in:)` 用的是同一个文件名。
    static let marker = "tokenizer.json"

    /// 资源目录（`Tokenizers/`）在 app 包里的位置；找不到返回 nil。
    ///
    /// `Bundle.module` 找不到资源包时是 `fatalError`，不是 nil——所以
    /// `build-app.sh` 里有一道「包里必须有 tokenizer.json」的检查，
    /// 这里只处理「包在、目录不在」。
    static func resourceRoot(bundle: Bundle = .module) -> URL? {
        bundle.url(forResource: "Tokenizers", withExtension: nil)
    }

    /// WhisperKit 第一个查的位置：`<downloadBase>/models/<repo>/`。
    ///
    /// 与 `HubApi.localRepoLocation` 的拼法一致（`models` 是 `RepoType.models`
    /// 的 rawValue），`BundledTokenizerTests` 拿真的 `HubApiWrapper` 比对过。
    nonisolated static func hubFolder(downloadBase: URL, repo: String) -> URL {
        downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
    }

    enum SeedOutcome: Equatable {
        case seeded(repo: String)
        case alreadyPresent(repo: String)
        /// 资源目录里没有这个仓库——包打坏了，或 `repos` 加了行没放文件。
        case sourceMissing(repo: String)
        case failed(repo: String, error: String)
    }

    /// 把一个仓库的三个文件从资源目录拷到 hub 目录。纯文件操作，测得到。
    nonisolated static func seed(
        repo: String, from resourceRoot: URL, into downloadBase: URL,
        fileManager fm: FileManager = .default
    ) -> SeedOutcome {
        let target = hubFolder(downloadBase: downloadBase, repo: repo)
        if fm.fileExists(atPath: target.appendingPathComponent(marker).path) {
            return .alreadyPresent(repo: repo)
        }
        let source = resourceRoot.appendingPathComponent(repo, isDirectory: true)
        guard fm.fileExists(atPath: source.appendingPathComponent(marker).path) else {
            return .sourceMissing(repo: repo)
        }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for file in files {
                let from = source.appendingPathComponent(file)
                guard fm.fileExists(atPath: from.path) else { continue }
                let to = target.appendingPathComponent(file)
                try? fm.removeItem(at: to)
                try fm.copyItem(at: from, to: to)
            }
            return .seeded(repo: repo)
        } catch {
            return .failed(repo: repo, error: String(describing: error))
        }
    }

    /// 生产入口：把打包的全部仓库种进 `downloadBase`，记日志。
    ///
    /// 只在 `WhisperKitTranscriber.prepare()` 造 `WhisperKit` 之前调——
    /// 那是 tokenizer 被查找的唯一时刻，早了没意义，晚了就已经去联网了。
    @discardableResult
    static func seedIfNeeded(
        downloadBase: URL,
        resourceRoot: URL? = BundledTokenizer.resourceRoot(),
        log: (String) -> Void = { AppLogger.shared.log($0) }
    ) -> [SeedOutcome] {
        guard let resourceRoot else {
            log("应用包里没有 Tokenizers 资源目录，离线加载模型要靠本地已有的 tokenizer")
            return []
        }
        return repos.map { repo in
            let outcome = seed(repo: repo, from: resourceRoot, into: downloadBase)
            switch outcome {
            case .seeded:
                log("已从应用包种入 tokenizer：\(repo) → \(hubFolder(downloadBase: downloadBase, repo: repo).path)")
            case .alreadyPresent:
                break
            case .sourceMissing:
                log("应用包里缺 tokenizer 仓库 \(repo)，离线加载模型要靠本地已有的 tokenizer")
            case .failed(_, let error):
                log("种入 tokenizer 失败：\(repo) 错误=\(error)")
            }
            return outcome
        }
    }
}
