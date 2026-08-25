import Foundation

/// 基于 Gemini 的云端翻译器。**默认不加载。**
///
/// # 云端是「默认关、用户显式开」，不是「本地做不到」
///
/// 产品大原则是**一切不出本机**（用户 2026-08-17 确立）：这个工具会用在
/// 含机密的场合，包括**报价**。所以云端后端存在，但默认关闭，且只在用户
/// 显式打开 `translation.usesCloudBackend` 之后才可能被构造出来。
///
/// **理由是「本地做得到」，不是「懒得做本地」**——这条区别要保住。M8 第 0
/// 步实测：本地 `qwen3-4b-instruct-2507-4bit` 残留汉字 0、术语保留
/// 1.00/0.92/0.89（英/西/德）、单条最长 4.9 秒。本地方案已经验收过，云端
/// 只是给「本机跑不动大模型」或「就是要那家的译文」的场合留的一条路。
///
/// 这也是「只要能禁掉云端，这个产品在欧洲就可能符合 GDPR」那句话的实现
/// 前提：禁掉的路径必须**真的一个字节都不出站**，而不是「大概不会走到」。
/// 守它的是 `TranslationAttachmentCoordinatorTests` 里那条零出站用例——
/// 云端开着、输出语言是中文时，从偏好一路走到注入，本类型一次都不会被
/// 构造，发出的请求数是 0（同一套接线换成外语时确实发出 1 条，那条正对照
/// 用例证明这套装置不是自证）。
///
/// # 为什么不套 Anthropic / OpenAI 那个 messages 形状
///
/// Gemini 的 API 形状与它们不同（`generateContent` 端点、`contents`/`parts`
/// 结构、key 走 `x-goog-api-key` 头而不是 `Authorization: Bearer`），
/// 硬套一个「通用 chat 客户端」抽象只会多一层翻译，而这一层今天只有一个
/// 实现。要加第二家云端时再抽，那时才知道共性在哪。
///
/// # 密钥：本类型不打印它，也不把它放进任何错误里
///
/// key 只从 `TranslationKey`（Keychain）来，走请求头**不走 query 参数**
/// ——query 会原样落进各级代理与服务端的访问日志。本类型不记任何日志，
/// 错误消息里只有 HTTP 状态码与 gRPC 状态名，都不含请求内容。
struct GeminiTranslator: Translator {
    /// 默认模型。
    ///
    /// **这个默认值没有实测支撑**：本轮（Task 13）用户还没提供 API key，
    /// 真实联网只跑得了门控 e2e（`./scripts/gemini-e2e.sh`），译文质量、
    /// 术语保留、耗时一概没有量过。本地那三个数（1.00/0.92/0.89）是
    /// **本地后端**的，不能拿来替云端说话。
    /// **取自 `CloudTranslationModel.default`，不另写一份。**
    ///
    /// 两处各写一个字面量的下场刚发生过：2026-08-19 换模型列表时改了
    /// `CloudTranslationModel`，这里的 `gemini-2.0-flash` 被漏下——而那个
    /// 标识符**已经不存在了**（实测 404）。生产路径上协调器会显式传模型，
    /// 所以漏掉不会立刻炸，只有不传模型、吃这个默认值的调用点会中招，
    /// 更难发现。
    ///
    /// （这段注释刻意不写出本类型带括号的构造写法：出站面那条源码扫描
    /// **不剥注释**，写一次就会把本文件也算成一个构造点——本文件里既有的
    /// 注释专门警告过这件事，而我改这里时还是踩了一次。）
    static let defaultModel = CloudTranslationModel.default.identifier

    /// 端点主机名。单列出来是给测试断言用：零出站那条用例要能说清
    /// 「本该发往哪里的请求一条都没发」。
    static let host = "generativelanguage.googleapis.com"

    /// 单次请求的超时。**从流水线的预算派生，不另拍一个数。**
    ///
    /// 两处各写一个 8 会漂，而漂了的表现极难看出来：流水线先超时退回中文
    /// 原文，请求还在后台跑——`TranslationPipeline` 刻意不取消那个 worker
    /// （见它的注释），于是一条挂死的请求会一直占着连接直到 URLSession
    /// 自己的默认 60 秒到期。让它跟着流水线的预算走，超时的两侧就对齐了。
    static var requestTimeout: TimeInterval {
        TimeInterval(TranslationPipeline.defaultTimeout.components.seconds)
    }

    private let model: String
    private let session: URLSession
    private let readKey: @Sendable () -> String?

    /// - Parameters:
    ///   - model: Gemini 模型名。
    ///   - session: 发请求用的 `URLSession`。
    ///   - readKey: 读 API key。
    ///
    /// **`session` 与 `readKey` 可注入，是为了让「零出站」这件事可验证。**
    /// 不可注入的话，唯一能写的断言是「我没调它，所以它没发请求」——
    /// 那是空断言。注入之后，测试把一个记录型 `URLSession` 从生产路径
    /// （协调器的云端工厂）送进来，**同一套接线**在外语时确实发出请求、
    /// 在中文时一条都没有，两条一起才构成证据。
    ///
    /// `readKey` 可注入还有第二个作用：测试永远不需要真 key，也就不可能
    /// 有人为了跑通测试把一个真 key 写进仓库。
    init(
        model: String = GeminiTranslator.defaultModel,
        session: URLSession = .shared,
        readKey: @escaping @Sendable () -> String? = {
            TranslationKey.read(service: TranslationKey.geminiService)
        }
    ) {
        self.model = model
        self.session = session
        self.readKey = readKey
    }

    /// 端点。模型名拼不成合法 URL 时返回 nil。
    static func endpoint(model: String) -> URL? {
        URL(string: "https://\(host)/v1beta/models/\(model):generateContent")
    }

    /// **刻意不覆盖 `isReady`**（协议默认恒为 true）。
    ///
    /// 照直觉写成「有 key 才算就绪」的话，缺 key 时流水线走的是
    /// `.modelLoading` 那条，HUD 说的是「翻译模型还在加载，本次注入中文
    /// 原文」——而云端根本没有模型要加载，用户会一直等一件不会发生的事。
    /// 缺 key 必须走 `translate` 抛 `.missingAPIKey`，HUD 才会说
    /// 「云端翻译未配置 API key」，那是他真正能采取动作的那句话。

    /// 云端没有加载成本，但要在这里确认 key 在。
    ///
    /// 否则用户开了云端却到第一次说话时才发现没配，而那时他正等着文字
    /// 出现。挂载时就抛的话，`TranslationPipeline.prepareTranslator` 会把
    /// 它记进日志（协调器还会同步记一条带存 key 命令的），用户在开口之前
    /// 就有机会看到。
    func prepare() async throws {
        guard readKey() != nil else { throw TranslatorError.missingAPIKey }
    }

    func translate(_ text: String, to target: Language) async throws -> String {
        // **没 key 就在这里断掉，一个字节都不出站。** 带着空 key 发出去
        // 换回来的是一个用户看不懂的 401，而且那一次已经把他刚说的话送出
        // 去了——恰恰是最不该发生的顺序。
        guard let key = readKey() else { throw TranslatorError.missingAPIKey }
        guard let url = Self.endpoint(model: model) else {
            throw TranslatorError.engineFailed("模型名拼不成合法 URL：\(model)")
        }

        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // key 走头不走 query：query 会原样进各级代理与服务端的访问日志。
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        // 提示词直接用 `TranslationPrompt.user`，**不在这里另写一份**。
        // 云端与本地各写一套的话，两边的译文差异就分不清是模型的差异还是
        // 提示词的差异——而本仓库的头号缺陷正是这类「度量测的其实是别的
        // 东西」。temperature 0 同理，与 `MLXTranslator` 一致：翻译要的是
        // 确定性。
        let body = RequestBody(
            contents: [
                .init(parts: [.init(text: TranslationPrompt.user(for: text, target: target))])
            ],
            generationConfig: .init(temperature: 0)
        )
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw TranslatorError.engineFailed("请求体编码失败：\(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // **网络错误要收敛成 `TranslatorError`，不能任它漏出去。**
            // 漏出去的话流水线走的是兜底那条 catch，标注里是
            // `Error` 的 `String(describing:)`——一串对用户毫无意义的
            // 结构体描述，而且断网这种最常见的情形应当说成「超时」。
            if error.code == .timedOut { throw TranslatorError.timedOut }
            throw TranslatorError.engineFailed(
                "网络错误 \(error.code.rawValue)：\(error.localizedDescription)")
        } catch {
            throw TranslatorError.engineFailed("请求失败：\(error)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw TranslatorError.engineFailed("响应不是 HTTP")
        }
        guard http.statusCode == 200 else {
            // 附上 gRPC 状态名（INVALID_ARGUMENT / PERMISSION_DENIED /
            // RESOURCE_EXHAUSTED …）：光一个 400 分不清是 key 不对还是模型名
            // 不对，而这两件事用户要做的动作完全不同。
            //
            // **只取 `error.status`，不取 `error.message`。** message 是服务端
            // 的自由文本，可能把请求里的内容回显出来——而请求里装的正是用户
            // 刚说的那句话，它会经由流水线进日志。status 是封闭的枚举名，
            // 不可能含用户内容。
            let status = (try? JSONDecoder().decode(ResponseBody.self, from: data))?.error?.status
            // **地域受限单列一格。** Google 用 `FAILED_PRECONDITION` 表示
            // "User location is not supported for the API use."——2026-08-19
            // 实测，中国 + VPN 下约 1/8 的请求撞上它。并进「翻译失败」的话，
            // 用户会去重说一遍，而重说一百遍也没用：他要做的是换网络位置
            // 或切回本机。
            if status == "FAILED_PRECONDITION" { throw TranslatorError.locationNotSupported }
            throw TranslatorError.engineFailed(
                status.map { "HTTP \(http.statusCode) \($0)" } ?? "HTTP \(http.statusCode)")
        }

        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
            let candidates = decoded.candidates
        else {
            throw TranslatorError.engineFailed("响应结构不认识")
        }

        // **把所有 part 拼起来，不是只取 parts[0]。** Gemini 允许把一段
        // 输出切成多个 part；只取第一个的表现是「译文少了后半截、而且是
        // 成功返回」，与推理被截断长得一模一样，事后分不开。闸门的截断判据
        // 主要看句末标点，接不住「正好在句号处断开」的那一种。
        let joined = (candidates.first?.content?.parts ?? [])
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else {
            // 结构认得，但一个字都没有：安全过滤拦下、或者模型什么都没生成。
            // 带上 finishReason（SAFETY / MAX_TOKENS / RECITATION …），
            // 否则这条错误看起来和「响应结构不认识」一样无从下手。
            let reason = candidates.first?.finishReason ?? "无 finishReason"
            throw TranslatorError.engineFailed("响应里没有译文（\(reason)）")
        }
        return joined
    }
}

// MARK: - 线上格式

/// 请求体。用 `Encodable` 而不是 `[String: Any]` + `JSONSerialization`：
/// 后者的字段名拼错了要到线上才发现，而返回的是一个 400。
private struct RequestBody: Encodable {
    struct Part: Encodable {
        let text: String
    }
    struct Content: Encodable {
        let parts: [Part]
    }
    struct GenerationConfig: Encodable {
        let temperature: Double
    }
    let contents: [Content]
    let generationConfig: GenerationConfig
}

/// 响应体。**成功与失败共用一个类型**，字段全可选。
///
/// 分成两个类型的话，非 200 那条路要先试着解一次错误结构、解不出来再退回
/// ——而两条路要读的字段本来就不重叠，合成一个反而没有歧义。
private struct ResponseBody: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }
            let parts: [Part]?
        }
        let content: Content?
        /// STOP / MAX_TOKENS / SAFETY / RECITATION…
        let finishReason: String?
    }
    /// gRPC 状态名。**刻意不解 `message`**，理由见 `translate` 里那段。
    struct ErrorPayload: Decodable {
        let status: String?
    }
    let candidates: [Candidate]?
    let error: ErrorPayload?
}
