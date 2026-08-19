import Foundation

/// 一个把请求**记下来并就地回一个假响应**的 `URLSession`——一个字节都不出
/// 网卡。
///
/// # 它存在的唯一理由：让「零出站」不靠推理
///
/// 「云端开着 + 输出语言是中文 = 零出站」是整个产品原则里最要紧的一条
/// （用户 2026-08-19 强调：用户可能为某次需要打开云端、之后忘了关）。
/// 在此之前这条只由「`translationAttachment` 返回 `.detach`」间接保证——
/// 那是在推理，不是在观测。
///
/// # 怎么保证它不是自证
///
/// 一个从没被调用的翻译器当然不会发请求，断言它没发等于什么都没断言。
/// 三件事一起，才让「0 条请求」成为证据：
///
/// 1. 记录器是**从生产路径**（`TranslationAttachmentCoordinator` 的云端
///    工厂）被送进去的，翻译器是真的 `GeminiTranslator`；
/// 2. **同一套接线**换成外语时确实记到 1 条发往
///    `generativelanguage.googleapis.com` 的 POST（正对照）；
/// 3. `CloudEgressTests` 扫源码钉住 `Sources/` 里只有那一个工厂能造出
///    `GeminiTranslator`，也只有它一处 `URLSession`——绕开注入另起一条
///    出站路径的写法会在那里红。
///
/// # 为什么用 token 而不是一个全局数组
///
/// `URLProtocol` 的实例由系统创建，拿不到测试里的对象。常见写法是往一个
/// 静态数组里塞，但 Swift Testing 默认并行跑用例，两条用例的请求会混进
/// 同一个数组——而「0 条」这种断言在被别人的请求污染时会假红、在自己的
/// 请求跑到别人那里去时会**假绿**。所以每个记录器带一个 token，经
/// `httpAdditionalHeaders` 进请求头，协议按 token 找回自己的记录器。
final class RequestRecorder: @unchecked Sendable {
    /// 记下来的一条请求。**存的是值不是 `URLRequest`**：`URLRequest` 在
    /// 协议层拿到时 `httpBody` 已被搬进 `httpBodyStream`，晚一步再读就读
    /// 不到了。
    struct Recorded: Sendable {
        let url: URL?
        let method: String?
        let headers: [String: String]
        let body: Data?
        let timeoutInterval: TimeInterval

        /// 请求体解成 JSON 字典。解不出来返回 nil。
        var jsonBody: [String: Any]? {
            guard let body,
                let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            return object
        }
    }

    /// 假响应。
    enum Reply: Sendable {
        case status(Int, Data)
        /// 网络层直接失败（断网、超时）。
        case failure(URLError.Code)
    }

    static let tokenHeader = "X-vInput-Test-Recorder"

    private static let registryLock = NSLock()
    private nonisolated(unsafe) static var registry: [String: RequestRecorder] = [:]

    let token = UUID().uuidString

    private let lock = NSLock()
    private var storage: [Recorded] = []
    private var reply: Reply

    init(reply: Reply = .status(200, Data())) {
        self.reply = reply
        Self.registryLock.withLock { Self.registry[token] = self }
    }

    deinit {
        Self.registryLock.withLock { Self.registry[token] = nil }
    }

    /// 收到的请求，按顺序。
    var requests: [Recorded] { lock.withLock { storage } }

    func setReply(_ reply: Reply) {
        lock.withLock { self.reply = reply }
    }

    /// 一个只走本协议、且带着本记录器 token 的 `URLSession`。
    ///
    /// 用 `.ephemeral` 而不是 `.default`：默认配置带磁盘缓存与 cookie 存储，
    /// 测试没有理由在用户机器上留下这些。
    func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        configuration.httpAdditionalHeaders = [Self.tokenHeader: token]
        return URLSession(configuration: configuration)
    }

    fileprivate static func recorder(for token: String) -> RequestRecorder? {
        registryLock.withLock { registry[token] }
    }

    fileprivate func record(_ recorded: Recorded) -> Reply {
        lock.withLock {
            storage.append(recorded)
            return reply
        }
    }
}

/// 拦截所有请求交给 `RequestRecorder`。**只在测试自己造的 session 上注册**
/// （`configuration.protocolClasses`），不进 `URLProtocol.registerClass` 的
/// 全局链——全局注册会波及进程里其它一切网络调用。
final class RecordingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let token = request.value(forHTTPHeaderField: RequestRecorder.tokenHeader),
            let recorder = RequestRecorder.recorder(for: token)
        else {
            // 没有 token 就说明有人绕开了 `makeSession()`。**必须失败得很响**
            // ——静默放行的话，那条请求会真的出站，而这套装置的全部意义就是
            // 保证它不会。
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "RecordingURLProtocol", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "请求没带记录器 token，说明它不是从 RequestRecorder.makeSession() 出来的"
                    ]))
            return
        }

        let recorded = RequestRecorder.Recorded(
            url: request.url,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.body(of: request),
            timeoutInterval: request.timeoutInterval
        )

        switch recorder.record(recorded) {
        case .status(let code, let data):
            let response = HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}

    /// 取请求体。
    ///
    /// **不能只读 `httpBody`**：`URLSession` 把请求交给协议之前会把 body
    /// 搬进 `httpBodyStream`，`httpBody` 那时是 nil。照直觉写的话，
    /// 「请求体里装的是不是 `TranslationPrompt.user` 那段」就永远断言不到，
    /// 而用例仍然是绿的——本仓库头号缺陷类型的又一个形态。
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
