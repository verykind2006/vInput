import Foundation

/// 下载源的真实网络探测。
///
/// `DownloadSource.choose(probe:forced:demoted:)` 把「谁快用谁」的决策做成了纯函数，
/// 但它要的那个 `probe` 一直是空缺的——本文件补上，且**只补这一件事**。
///
/// ## 为什么单独一个文件
///
/// 这是本批唯一一处主动发起网络请求的代码。放在向导里的话，
/// 「换一种探测方式」就得动向导；单独放着，`OnboardingCoordinator.Wiring.probe`
/// 一行就能换成假的（测试就是这么做的），也能换成别的判据。
///
/// ## 为什么探的是 `resolve/main/<variant>/config.json`，不是仓库页
///
/// 第一版探 `<endpoint>/argmaxinc/whisperkit-coreml`（仓库的 HTML 页）。
/// 2026-08-23 太太的机器上，那一页三次都在 1.5–2.2 秒内回了，而紧接着的
/// 下载三次都在 `…/resolve/main/<variant>/<file>` 上 60 秒超时——其中一个
/// 文件只有 243 字节。**仓库页通不代表下载路径通**，两条路多半不在同一组
/// 主机上。所以改探下载真正会走的那条路：同一个仓库、同一个变体、
/// 里面一个小的非 LFS 文件（`config.json`，1149 字节）。HEAD 只要响应头。
///
/// **它不是目录里最小的那个**（2026-08-24 订正）：`*.mlmodelc/analytics/
/// coremldata.bin` 有 4 个，各 243 字节，08-23 卡死的正是其中一个。
/// `config.json` 只是**顶层**最小。选它的理由是「在 `resolve/main/<variant>/`
/// 这一层、非 LFS、必然存在」，不是「最小」。
///
/// `variant` 取 `ModelDownloader.variant`——向导只下这一个，探别的没意义。
///
/// **重定向、403、404 都算「通」**：这里量的是「这个源有没有响应、多快」，
/// 不是「这个 URL 语义上对不对」。判死只有一种情形——传输层根本没回来
/// （连不上、超时）。判得太严的代价是把一个其实能用的源排除掉，
/// 而两个都被排除时向导只能去要用户手动导入模型。
///
/// ## 为什么超时只有 2.5 秒
///
/// 这是**并发**探测（`choose` 里 `async let` 两条一起发），两个都不通时
/// 用户要干等的就是这个数。用户此刻站在向导第一步，等待期本该被后面的
/// 权限步骤吸收掉；超时定长一点只会把「两个源都连不上」这句话说得更晚。
///
/// ## 给后来人的一条提醒
///
/// `TranslationAttachmentCoordinatorTests.sourceHasSingleCloudEgressPath`
/// 那道出站面守卫是**按文件名**匹配的，本文件已经在它的白名单里。也就是说
/// **今后往这个文件里新加任何 `URLSession` 用法都自动豁免**，不会再有测试
/// 拦你一次。要加新的出站请求，请回那份清单把三问重答一遍
/// （发的是什么、用户能不能禁掉、怎么验证真的禁掉了）。
enum EndpointProbe {
    /// 单次探测的超时。理由见类型注释。
    static let timeout: TimeInterval = 2.5

    /// 探测专用的会话：**不带 cookie、不落缓存、不进钥匙串**。
    ///
    /// 不能用 `URLSession.shared`：它带着进程共享的 cookie 存储。白名单注释里
    /// 那句「对面只知道有人问了这个公开仓库在不在」，只有在这里成立时才是
    /// 真话——共享会话会把这个进程碰巧存下的任何 cookie 一起发给
    /// huggingface.co 和 hf-mirror.com。
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// 探测用的 URL：下载真正会走的那条路上一个小的非 LFS 文件。理由见类型注释。
    static func probeURL(for source: DownloadSource) -> URL? {
        URL(
            string: source.endpoint
                + "/argmaxinc/whisperkit-coreml/resolve/main/"
                + ModelDownloader.variant + "/config.json")
    }

    /// 探测请求。
    ///
    /// - `HEAD`：只要响应头，不拉正文。第一版探的是几十 KB 的仓库 HTML 页，
    ///   拉全文会把「响应有多快」量成「带宽有多大」；现在探的 `config.json`
    ///   只有 1 KB，但 HEAD 仍然要保留——同一层还有 LFS 大文件，将来换探测
    ///   目标时 GET 会直接把这个隐患变成一次真下载。
    /// - `reloadIgnoringLocalAndRemoteCacheData`：命中缓存的话量到的是
    ///   本机磁盘速度，两个源会双双报出个位数毫秒，`choose` 的比较从此无意义。
    static func request(for source: DownloadSource) -> URLRequest? {
        guard let url = probeURL(for: source) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeout
        return request
    }

    /// 把「耗时 + 有没有抛错」翻译成 `ProbeResult`。
    ///
    /// 抽成纯函数是因为上面那句 `data(for:)` 在测试进程里跑不了（要真联网），
    /// 而「什么算通、毫秒怎么算」恰恰是会写错的部分：早一版把非 2xx 也判成
    /// unreachable，结果 huggingface.co 对 HEAD 回 405 就被判死。
    ///
    /// `elapsed` 取整而不是四舍五入无所谓——`choose` 只比大小。但**至少是 1**：
    /// 两个源都量到 0 毫秒时 `min` 的结果取决于数组顺序，看上去像「永远选官方源」。
    nonisolated static func result(elapsed: TimeInterval, failed: Bool) -> DownloadSource.ProbeResult {
        guard !failed else { return .unreachable }
        return .responded(millis: max(1, Int(elapsed * 1000)))
    }

    /// 真正发请求的那一层。**测试进程里跑不到**（要真联网），
    /// 因此除了计时与转交，它一行判断都不做。
    static func probe(
        _ source: DownloadSource, session: URLSession = EndpointProbe.session
    ) async -> DownloadSource.ProbeResult {
        guard let request = request(for: source) else { return .unreachable }
        let started = Date()
        do {
            _ = try await session.data(for: request)
            return result(elapsed: Date().timeIntervalSince(started), failed: false)
        } catch {
            AppLogger.shared.log("下载源探测失败：\(source.displayName) 错误=\(error)")
            return result(elapsed: Date().timeIntervalSince(started), failed: true)
        }
    }
}
