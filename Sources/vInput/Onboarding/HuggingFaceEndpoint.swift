import Foundation

/// 本进程的 Hugging Face 端点。
///
/// ## 为什么需要它：镜像只覆盖了模型，tokenizer 一直在走官方源
///
/// `ModelDownloader` 把选中的源当 `endpoint:` 传给
/// `WhisperKit.download(...)`，那一条**只下模型权重**。tokenizer 是另一个
/// 入口在另一个时刻取的：`WhisperKit(config)` → `prepare()` →
/// `ModelUtilities.loadTokenizer(for:tokenizerFolder:...)`
/// （`vendor/WhisperKit/Sources/WhisperKit/Utilities/ModelUtilities.swift:23`），
/// 它 `new` 出来的 `HubApiWrapper(downloadBase:useBackgroundSession:)`
/// **压根没有 endpoint 这个参数**，于是一路落到
/// `HubApi.hfEndpointfromEnv()`
/// （`vendor/WhisperKit/Sources/ArgmaxCore/External/Hub/HubApi.swift:128`）：
///
/// ```swift
/// ProcessInfo.processInfo.environment["HF_ENDPOINT"] ?? "https://huggingface.co"
/// ```
///
/// 后果实测得到：turbo 的 tokenizer 仓库是 `openai/whisper-large-v3`
/// （`ModelUtilities.swift:199`），落在模型目录**旁边**的
/// `models/openai/whisper-large-v3/`（约 2.8 MB，本机盘上就有这么一份）。
/// 在国内，向导会顺利地经镜像下完 1.5 GB，然后在第五步「试说一句」的
/// `prepare()` 上，为了 2.8 MB 去连 huggingface.co 而挂住——**恰好是验收
/// 标准的最后一步，恰好在目标机器上**。
///
/// ## 为什么是设进程环境变量，而不是把 tokenizer 打进 app 包
///
/// 另一条路是把那 2.8 MB 随 app 分发，`prepare()` 时传 `tokenizerFolder`，
/// 第五步就彻底不需要网络。**没有选它**，理由三条：
///
/// 1. 它只治一个变体。`tokenizerFolder` 里那份 tokenizer 是按仓库名
///    （`openai/whisper-large-v3`）找的；用户从别的机器拷来一个 base 或
///    large-v3 目录（S-3 那条逃生口的正常用法），要的就是另一个仓库，
///    照样回到 `HF_ENDPOINT` 这条路上。
/// 2. 它只治 tokenizer 这一个调用点。`HubApiWrapper` 在 `vendor/` 里，
///    我们不改它；今天没有 endpoint 参数的调用点是一个，明天 WhisperKit
///    升级后是几个，只有环境变量能一次覆盖全部。
/// 3. 那 2.8 MB 走的是刚刚才成功下完 1.5 GB 的同一个源。真实风险从来不是
///    「2.8 MB 下不动」，是「它去了另一台主机」。修主机就够了。
///
/// 代价如实记下：仍然需要一次几 MB 的联网，完全离线装不了。
///
/// ## 谁在什么时候调
///
/// - `AppModel.bootstrap()` 一进门就调一次（在造 transcriber 之前，
///   也就在任何 WhisperKit 加载之前）。判据来自偏好，**默认官方源**。
/// - 向导探测出这次用哪个源的那一刻再调一次（`adopt(_:)`），并把它
///   持久化——否则「自动」探出来的结果只活在本次向导里，下次启动
///   `prepare()` 又回官方源了。
/// - 用户在面板「高级 → 下载源」里改档时调一次：他改的就是「走哪个源」，
///   没道理只有模型听他的。
///
/// `setenv` 对本进程立即生效，且 `ProcessInfo.processInfo.environment`
/// 每次读都重新取（实测：同一进程内 setenv 两次，两次都读得到新值）——
/// `HubApi` 是在**每次** `init` 里读它的，所以这个先后顺序是成立的。
enum HuggingFaceEndpoint {
    /// `HubApi` 读的那个变量名。**全仓唯一的一处**，理由同
    /// `DownloadSourcePreference.forcedKey`：拼错一个字母的表现是
    /// 「设了等于没设」，而没有任何编译错误。
    static let variableName = "HF_ENDPOINT"

    /// 端点的判据与理由。`reason` 只进日志——「此刻到底在走哪个源」
    /// 是排查国内下载问题的第一个问题，日志里必须直接答得出来。
    struct Resolution: Equatable {
        let source: DownloadSource
        let reason: String
    }

    /// 谁说了算：**用户强制的 > 上次实际用过的 > 官方源**。
    ///
    /// 第三档是默认值，也是失败方向：什么都不知道时走官方源，
    /// 与 `HubApi` 自己的默认一致——即「不知道就不要自作主张改行为」。
    nonisolated static func inForce(
        forced: DownloadSource?, resolved: DownloadSource?
    ) -> Resolution {
        if let forced { return Resolution(source: forced, reason: "面板里强制的") }
        if let resolved { return Resolution(source: resolved, reason: "上次下载实际用的") }
        return Resolution(source: .official, reason: "没有记录，默认")
    }

    nonisolated static func logLine(_ resolution: Resolution) -> String {
        "HF 端点：\(resolution.source.endpoint)"
            + "（\(resolution.source.displayName)，\(resolution.reason)）"
    }

    /// 设进本进程并记一条日志。
    ///
    /// `setValue` / `log` 注入进来是为了能测：真去动本进程的环境变量，
    /// 测试之间会互相影响（另有一条测试专门验真 `setenv` 那条路）。
    @discardableResult
    nonisolated static func apply(
        forced: DownloadSource?,
        resolved: DownloadSource?,
        setValue: (String, String) -> Void = { setenv($0, $1, 1) },
        log: (String) -> Void = { AppLogger.shared.log($0) }
    ) -> Resolution {
        let resolution = inForce(forced: forced, resolved: resolved)
        setValue(variableName, resolution.source.endpoint)
        log(logLine(resolution))
        return resolution
    }

    /// 生产入口：从偏好里读判据。启动时调。
    @discardableResult
    nonisolated static func applyFromPreference(
        _ preference: DownloadSourcePreference = DownloadSourcePreference()
    ) -> Resolution {
        apply(forced: preference.forced, resolved: preference.resolved)
    }

    /// 这次下载定下用哪个源：**记下来，并且当场生效**。
    ///
    /// 「记下来」是为了下次启动的 `prepare()`；「当场生效」是为了本次——
    /// 向导下完模型立刻就会走到 `prepare()` 去取 tokenizer，
    /// 那一下不能还用着启动时那个判据。
    ///
    /// 用户强制过的话强制的仍然赢（`inForce` 的顺序），这里只是补上
    /// 「自动探出来的那个从来没人记」这个洞。
    nonisolated static func adopt(
        _ source: DownloadSource,
        preference: DownloadSourcePreference = DownloadSourcePreference()
    ) {
        preference.resolved = source
        apply(forced: preference.forced, resolved: source)
    }
}
