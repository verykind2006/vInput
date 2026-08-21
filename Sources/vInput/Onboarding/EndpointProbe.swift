import Foundation

/// 下载源的真实网络探测。
///
/// `DownloadSource.choose(probe:forced:)` 把「谁快用谁」的决策做成了纯函数，
/// 但它要的那个 `probe` 一直是空缺的——本文件补上，且**只补这一件事**。
///
/// ## 为什么单独一个文件
///
/// 这是本批唯一一处主动发起网络请求的代码。放在向导里的话，
/// 「换一种探测方式」就得动向导；单独放着，`OnboardingCoordinator.Wiring.probe`
/// 一行就能换成假的（测试就是这么做的），也能换成别的判据。
///
/// ## 为什么探到仓库路径而不是站点根
///
/// 站点根通了不代表这个源上有我们要的仓库。探
/// `<endpoint>/argmaxinc/whisperkit-coreml`——两个源都以网页形式提供这条路径，
/// hf-mirror 是 huggingface.co 的整站镜像。
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
enum EndpointProbe {
    /// 单次探测的超时。理由见类型注释。
    static let timeout: TimeInterval = 2.5

    /// 探测用的仓库路径。
    static func probeURL(for source: DownloadSource) -> URL? {
        URL(string: source.endpoint + "/argmaxinc/whisperkit-coreml")
    }

    /// 探测请求。
    ///
    /// - `HEAD`：只要响应头，不拉正文。仓库页面的 HTML 有几十 KB，
    ///   在慢网络上拉全文会把「响应有多快」量成「带宽有多大」。
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
        _ source: DownloadSource, session: URLSession = .shared
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
