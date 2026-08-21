import Foundation
import Testing

@testable import vInput

/// 进程级 `HF_ENDPOINT`：镜像必须**同时**覆盖模型与 tokenizer。
///
/// 背景（QA 2026-08-22 在盘上核过）：`WhisperKit.download(...)` 的 `endpoint:`
/// 只管模型权重；tokenizer 是 `prepare()` 里另一个入口取的，那个入口
/// （`HubApiWrapper(downloadBase:useBackgroundSession:)`）没有 endpoint 参数，
/// 一路落到 `HubApi.hfEndpointfromEnv()` 去读 `HF_ENDPOINT`。
/// 于是国内用户经镜像顺利下完 1.5GB，卡死在第五步为 2.8MB 的 tokenizer
/// 连 huggingface.co——正好是验收标准的最后一步。
struct HuggingFaceEndpointTests {

    // MARK: - 谁说了算

    /// 用户在面板里强制过，就听他的——哪怕上次实际用的是另一个。
    @Test func forcedWinsOverWhatWasUsedLastTime() {
        let resolution = HuggingFaceEndpoint.inForce(forced: .official, resolved: .mirror)
        #expect(resolution.source == .official)
    }

    /// 没强制过时，用上次实际下载用的那个。
    ///
    /// **这一条是本次修复的核心。** 「自动」探测出来的结果原先根本没人记，
    /// 只活在向导那一次运行里；下次启动 `prepare()` 取 tokenizer 时，
    /// 一台靠镜像装成的机器又会去连官方源。
    @Test func fallsBackToTheSourceActuallyUsedLastTime() {
        let resolution = HuggingFaceEndpoint.inForce(forced: nil, resolved: .mirror)
        #expect(resolution.source == .mirror)
    }

    /// 什么都不知道时走官方源——与 `HubApi` 自己的默认一致。
    ///
    /// 失败方向必须是这一边：不知道就别自作主张把用户的流量导去第三方主机。
    @Test func defaultsToOfficialWhenNothingIsKnown() {
        let resolution = HuggingFaceEndpoint.inForce(forced: nil, resolved: nil)
        #expect(resolution.source == .official)
    }

    // MARK: - 设进去的到底是什么

    /// 设的变量名与值，逐字钉住。
    ///
    /// 变量名拼错一个字母的表现是「设了等于没设」：下载照常成功，
    /// 只有第五步会挂——而那一步在测试进程里跑不到。
    @Test func setsTheVariableHubApiReadsWithTheMirrorURL() {
        var written: [(String, String)] = []
        HuggingFaceEndpoint.apply(
            forced: .mirror, resolved: nil,
            setValue: { written.append(($0, $1)) }, log: { _ in })

        let names = written.map(\.0)
        let values = written.map(\.1)
        #expect(names == ["HF_ENDPOINT"])
        #expect(values == ["https://hf-mirror.com"])
    }

    @Test func officialSourceWritesTheOfficialHost() {
        var written: [(String, String)] = []
        HuggingFaceEndpoint.apply(
            forced: .official, resolved: nil,
            setValue: { written.append(($0, $1)) }, log: { _ in })
        #expect(written.map(\.1) == ["https://huggingface.co"])
    }

    /// **日志里必须能直接读出「此刻在走哪个源、为什么」。**
    ///
    /// 这一批改的是「应用会连哪台主机」，而排查国内下载问题的第一个问题
    /// 就是这个。日志不写的话，只能靠抓包或者猜。
    @Test func logsTheEndpointActuallyInForce() {
        var lines: [String] = []
        HuggingFaceEndpoint.apply(
            forced: nil, resolved: .mirror, setValue: { _, _ in }, log: { lines.append($0) })

        let one = lines.count == 1
        #expect(one, "端点日志应当恰好一行，实际 \(lines.count) 行")
        let line = lines.first ?? ""
        #expect(line.contains("https://hf-mirror.com"), "日志里没有实际生效的端点：\(line)")
        #expect(line.contains("上次下载实际用的"), "日志里没说为什么是它：\(line)")
    }

    /// 三档理由各不相同——都写成同一句话的话，日志就答不出「为什么是它」。
    @Test func eachOriginReadsDifferently() {
        let reasons = [
            HuggingFaceEndpoint.inForce(forced: .mirror, resolved: nil).reason,
            HuggingFaceEndpoint.inForce(forced: nil, resolved: .mirror).reason,
            HuggingFaceEndpoint.inForce(forced: nil, resolved: nil).reason,
        ]
        #expect(Set(reasons).count == 3, "三档理由撞车了：\(reasons)")
    }

    // MARK: - 机理：setenv 真的能被 ProcessInfo 读到

    /// **整条修复都压在这一条机理上**：`HubApi` 是在自己的 `init` 里读
    /// `ProcessInfo.processInfo.environment["HF_ENDPOINT"]` 的，而我们是在
    /// 进程**启动之后**才知道该设成什么。如果 Foundation 把环境字典缓存在
    /// 启动那一刻（这在别的平台上确实发生过），那么整个方案是空的，
    /// 而上面那些注入式断言**一条都不会红**——它们只证明我们调了 `setenv`。
    ///
    /// 所以这一条走真路径：不注入 `setValue`，真去动本进程的环境变量，
    /// 再用 `HubApi` 用的那个读法读回来。跑完立刻还原。
    @Test func setenvIsVisibleToProcessInfoInTheSameProcess() {
        let name = HuggingFaceEndpoint.variableName
        let previous = ProcessInfo.processInfo.environment[name]
        defer {
            if let previous { setenv(name, previous, 1) } else { unsetenv(name) }
        }

        HuggingFaceEndpoint.apply(forced: .mirror, resolved: nil, log: { _ in })
        let afterMirror = ProcessInfo.processInfo.environment[name]
        #expect(afterMirror == "https://hf-mirror.com")

        // 再设一次：`HubApi` 每次 init 都重读，所以「改了还能再改」也是契约的
        // 一部分（向导探完源会当场改一次，用户在面板里换档还会再改一次）。
        HuggingFaceEndpoint.apply(forced: .official, resolved: nil, log: { _ in })
        let afterOfficial = ProcessInfo.processInfo.environment[name]
        #expect(afterOfficial == "https://huggingface.co")
    }

    // MARK: - 记账：探出来的源要留到下次启动

    @Test func adoptRemembersTheSourceForNextLaunch() {
        let name = "hf-endpoint-adopt-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let preference = DownloadSourcePreference(defaults: defaults)

        let envName = HuggingFaceEndpoint.variableName
        let previous = ProcessInfo.processInfo.environment[envName]
        defer {
            if let previous { setenv(envName, previous, 1) } else { unsetenv(envName) }
        }

        HuggingFaceEndpoint.adopt(.mirror, preference: preference)

        #expect(preference.resolved == .mirror)
        // 下次启动那条路：只有偏好，没有别的。
        let nextLaunch = HuggingFaceEndpoint.inForce(
            forced: preference.forced, resolved: preference.resolved)
        #expect(nextLaunch.source == .mirror)
    }

    // MARK: - vendor 那一侧的契约

    /// `HubApi` 读的确实是这个变量名。
    ///
    /// `vendor/` 不归我们改，但**升级 WhisperKit 会换掉它**——那一刻这整条
    /// 修复会静默失效（下载照常成功，只有第五步在国内挂住），而全仓一条
    /// 测试都不会红。所以这一条去扫 vendor 的源码，把那份契约钉在这里。
    @Test func vendorHubApiStillReadsThisEnvironmentVariable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // vInputTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
        let hubApi = try String(
            contentsOf: root.appendingPathComponent(
                "vendor/WhisperKit/Sources/ArgmaxCore/External/Hub/HubApi.swift"),
            encoding: .utf8)

        let readsIt = hubApi.contains(
            "environment[\"\(HuggingFaceEndpoint.variableName)\"]")
        #expect(
            readsIt,
            """
            vendor 的 HubApi 不再读 \(HuggingFaceEndpoint.variableName)。
            tokenizer 那一路没有 endpoint 参数，只认这个环境变量——它一变，
            国内用户会在向导第五步（取 2.8MB 的 tokenizer）上挂住，
            而 1.5GB 的模型下载仍然一切正常。
            """
        )
    }

    /// tokenizer 那一路确实**没有** endpoint 参数——这正是本条修复存在的理由。
    ///
    /// 哪天 WhisperKit 给 `loadTokenizer` 加上了 endpoint，我们就该改走
    /// 参数而不是环境变量；这条测试会在那一刻红，逼下一个人回来想一遍。
    @Test func vendorTokenizerLoaderStillHasNoEndpointParameter() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let utilities = try String(
            contentsOf: root.appendingPathComponent(
                "vendor/WhisperKit/Sources/WhisperKit/Utilities/ModelUtilities.swift"),
            encoding: .utf8)

        let constructsHubWithoutEndpoint = utilities.contains(
            "HubApiWrapper(downloadBase: tokenizerFolder, useBackgroundSession: useBackgroundSession)"
        )
        #expect(
            constructsHubWithoutEndpoint,
            """
            loadTokenizer 里那句 HubApiWrapper(...) 变了。
            本条修复的全部前提是「这一路拿不到 endpoint，只能走环境变量」——
            前提变了就该回来重选做法（多半是改传参数）。
            """
        )
    }
}
