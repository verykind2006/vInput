import Foundation

/// 模型下载源。
enum DownloadSource: String, CaseIterable, Equatable, Sendable {
    case official
    case mirror

    var endpoint: String {
        switch self {
        case .official: "https://huggingface.co"
        case .mirror: "https://hf-mirror.com"
        }
    }

    /// 给用户看的名字（面板「高级」区的下载源开关用）。
    var displayName: String {
        switch self {
        case .official: "官方源"
        case .mirror: "国内镜像"
        }
    }

    /// 另一个源。只有两个源，这一条是「下载失败自动换源」的全部选源逻辑。
    var other: DownloadSource {
        switch self {
        case .official: .mirror
        case .mirror: .official
        }
    }

    enum ProbeResult: Equatable, Sendable {
        case responded(millis: Int)
        case unreachable
    }

    /// 并发探测两个源，谁先响应用谁。
    ///
    /// **为什么不是「主源优先、失败再切」**：用户现在在国内，官方源基本不通，
    /// 「先试官方」等于每次都先白等一个超时；而 9 月到西班牙后官方更快，
    /// 写死镜像又反过来吃亏。并发探测让同一套代码两边都最优，且**不必问
    /// 用户身处何地**。
    ///
    /// 两个都不通时返回 nil：调用方要去说「两个源都连不上」并给手动导入入口，
    /// 硬选一个只会卡在下载里。
    ///
    /// `demoted` 是**本次会话里下载失败过的源**（2026-08-23：官方源探测三次
    /// 都通、下载三次都超时）。可达的源里先挑没失败过的；都失败过就仍按最快
    /// 的挑——用户点了重试，就该再试，而不是无源可选。`forced` 仍然最高。
    static func choose(
        probe: @Sendable (DownloadSource) async -> ProbeResult,
        forced: DownloadSource?,
        demoted: Set<DownloadSource> = []
    ) async -> DownloadSource? {
        if let forced { return forced }

        async let officialResult = probe(.official)
        async let mirrorResult = probe(.mirror)
        let results: [(DownloadSource, ProbeResult)] = [
            (.official, await officialResult), (.mirror, await mirrorResult),
        ]

        let reachable = results.compactMap { source, result -> (DownloadSource, Int)? in
            guard case .responded(let millis) = result else { return nil }
            return (source, millis)
        }
        let fresh = reachable.filter { !demoted.contains($0.0) }
        return (fresh.isEmpty ? reachable : fresh).min { $0.1 < $1.1 }?.0
    }
}
