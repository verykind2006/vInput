import Foundation
import Testing

@testable import vInput

/// 云端翻译器的请求形状与响应解析。
///
/// **本轮不做真实联网。** 用户至今没有提供 API key（2026-08-19），
/// Keychain 里大概率是空的。真联网那条另有一套门控用例
/// （`GeminiE2ETests` + `./scripts/gemini-e2e.sh`），要用户自己存好 key
/// 才跑得起来。这里用 `RequestRecorder` 就地拦下每一条请求：断言的是
/// 「发出去的是什么形状」与「收到什么样的响应会得出什么结论」，
/// 一个字节都不出网卡。
///
/// 假 key 一律明写成 `not-a-real-key-*`：**任何真 key 都不许进仓库。**
///
/// # 变异表（2026-08-19 实测）
///
/// | 变异 | 结果 |
/// |---|---|
/// | 把 `case missingAPIKey` 从 `TranslatorError` 里注释掉 | **编译错误**，且在生产代码里：`GeminiTranslator.swift:107`（`prepare`）、`:114`（`translate`）、`TranslationPipeline.swift:170` |
/// | 响应只取 `parts[0]` 不拼接 | `joinsAllParts` 红（拿到 "We go live"） |
/// | 不设 `timeoutInterval` | `requestTimeoutFollowsPipelineBudget` 红（量到 60 秒，`URLSession` 的默认值） |
/// | key 改走 `?key=` 而不是请求头 | `keyNeverAppearsInURL` + `requestShapeMatchesGeminiAPI` 红 |
@Suite("云端翻译器")
struct GeminiTranslatorTests {
    private static let fakeKey = "not-a-real-key-0000"
    private static let source = "今天下午上线。"

    /// 一条成功的响应。形状照 Gemini 的 `generateContent` 文档写。
    ///
    /// 非 private：协调器那套「零出站」用例要拿同一份线上格式喂给**真的**
    /// `GeminiTranslator`。两处各写一份的话，那边的正对照可能在一份早已
    /// 漂掉的格式上「成功」，而它恰恰是用来证明装置有效的那一条。
    static func successBody(_ text: String, finishReason: String = "STOP") -> Data {
        Data(
            """
            {"candidates":[{"content":{"parts":[{"text":\(jsonString(text))}],"role":"model"},\
            "finishReason":"\(finishReason)"}],"modelVersion":"gemini-2.0-flash"}
            """.utf8)
    }

    static func jsonString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [])
        let array = String(data: data, encoding: .utf8)!
        return String(array.dropFirst().dropLast())
    }

    private func translator(
        _ recorder: RequestRecorder,
        key: String? = GeminiTranslatorTests.fakeKey,
        model: String = GeminiTranslator.defaultModel
    ) -> GeminiTranslator {
        GeminiTranslator(model: model, session: recorder.makeSession(), readKey: { key })
    }

    // MARK: - 缺 key：抛 .missingAPIKey，且一个字节都不出站

    /// **`.missingAPIKey` 的第一个真实抛出点。**
    ///
    /// M8 早期变异实测：把 `case missingAPIKey` 从 `TranslatorError` 里删掉，
    /// 全套件绿——它那时没有任何抛出点，唯一能写的断言是「我刚才让它抛的
    /// 就是它抛的」，那是空断言。现在它有了两个真实抛出点（`prepare` 与
    /// `translate`），删掉那一格是编译错误。
    @Test("prepare：没配 key 时抛 .missingAPIKey")
    func prepareWithoutKeyThrowsMissingAPIKey() async throws {
        let recorder = RequestRecorder()
        let translator = translator(recorder, key: nil)

        await #expect(throws: TranslatorError.missingAPIKey) {
            try await translator.prepare()
        }
        #expect(recorder.requests.isEmpty, "prepare 不该发任何请求")
    }

    /// 有 key 时 prepare 成功，**但仍然一条请求都不发**。
    ///
    /// 云端没有加载成本，prepare 在这里只是「提前把缺 key 捅出来」。
    /// 顺手发一条请求去验 key 的话，用户每次换语言都要烧一次配额，
    /// 而且那条请求里装的是什么？只能是编的内容——那就等于替用户往云端
    /// 发了一句他没说过的话。
    @Test("prepare：配了 key 时不发请求也不报错")
    func prepareWithKeySendsNothing() async throws {
        let recorder = RequestRecorder()
        try await translator(recorder).prepare()
        #expect(recorder.requests.isEmpty)
    }

    /// **缺 key 时 `translate` 也不许发出去。**
    ///
    /// 带着空 key 发出去换回来的是一个看不懂的 401，而那一次已经把用户刚
    /// 说的话送出去了——恰恰是最不该发生的顺序。把 `guard let key` 那行
    /// 换成 `let key = readKey() ?? ""`，这条红。
    @Test("translate：没配 key 时抛 .missingAPIKey，且不发任何请求")
    func translateWithoutKeySendsNothing() async throws {
        let recorder = RequestRecorder()
        let translator = translator(recorder, key: nil)

        await #expect(throws: TranslatorError.missingAPIKey) {
            _ = try await translator.translate(Self.source, to: .english)
        }
        #expect(recorder.requests.isEmpty, "缺 key 时把用户说的话发出去了")
    }

    /// key 是**每次请求时**读的，不是构造时读一次。
    ///
    /// 用户开着云端、发现没配 key、当场用 `security` 存了一条——下一句话
    /// 就该生效，不必回菜单重选一次语言（他也想不到要那么做）。
    /// 把 `readKey()` 的结果缓存进存储属性时这条红。
    @Test("key 每次请求都重新读：中途存进 Keychain 立刻生效")
    func keyIsReadOnEveryRequest() async throws {
        let recorder = RequestRecorder(reply: .status(200, Self.successBody("We go live.")))
        let box = MutableBox<String?>(nil)
        let translator = GeminiTranslator(
            session: recorder.makeSession(), readKey: { box.value })

        await #expect(throws: TranslatorError.missingAPIKey) {
            _ = try await translator.translate(Self.source, to: .english)
        }
        box.value = Self.fakeKey
        let output = try await translator.translate(Self.source, to: .english)

        #expect(output == "We go live.")
        #expect(recorder.requests.count == 1)
    }

    // MARK: - 请求形状

    @Test("请求形状：POST、端点、头、体")
    func requestShapeMatchesGeminiAPI() async throws {
        let recorder = RequestRecorder(reply: .status(200, Self.successBody("We go live.")))
        _ = try await translator(recorder).translate(Self.source, to: .spanish)

        let request = try #require(recorder.requests.first)
        #expect(recorder.requests.count == 1, "一次翻译只该发一条请求")
        #expect(request.method == "POST")
        #expect(
            request.url?.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/models/"
                + "gemini-2.0-flash:generateContent")
        #expect(request.headers["x-goog-api-key"] == Self.fakeKey)
        #expect(request.headers["Content-Type"] == "application/json")

        let body = try #require(request.jsonBody)
        let contents = try #require(body["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        // **不在这里复刻提示词**，拿生产函数比对：抄一份的话，改了生产提示词
        // 而忘了改这里，这条会以「期望值过时」的形式红，改的人多半是把断言
        // 改成新文本了事；而抄错一个字时它反而绿。
        #expect(
            parts.first?["text"] as? String
                == TranslationPrompt.user(for: Self.source, target: .spanish))
        let config = try #require(body["generationConfig"] as? [String: Any])
        #expect((config["temperature"] as? NSNumber)?.doubleValue == 0)
    }

    /// **key 只走请求头，绝不进 URL。**
    ///
    /// Gemini 也接受 `?key=` 这种写法，而 query 会原样落进各级代理与服务端
    /// 的访问日志。写成 query 的那一刻，用户的密钥就散进了他控制不了的地方。
    @Test("key 不出现在 URL 里")
    func keyNeverAppearsInURL() async throws {
        let recorder = RequestRecorder(reply: .status(200, Self.successBody("Hi.")))
        _ = try await translator(recorder).translate(Self.source, to: .english)

        let url = try #require(recorder.requests.first?.url?.absoluteString)
        #expect(!url.contains(Self.fakeKey), "key 进了 URL：\(url)")
    }

    /// 请求超时跟着流水线的预算走，不是 `URLSession` 的默认 60 秒。
    ///
    /// 流水线超时后**不取消**在途请求（见 `TranslationPipeline.withTimeout`
    /// 的注释），60 秒的默认值意味着一条挂死的请求会一直占着连接。
    @Test("请求超时与流水线预算同源")
    func requestTimeoutFollowsPipelineBudget() async throws {
        let recorder = RequestRecorder(reply: .status(200, Self.successBody("Hi.")))
        _ = try await translator(recorder).translate(Self.source, to: .english)

        let timeout = try #require(recorder.requests.first?.timeoutInterval)
        #expect(timeout == TimeInterval(TranslationPipeline.defaultTimeout.components.seconds))
        #expect(timeout != 60, "这是 URLSession 的默认值，说明没设 timeoutInterval")
    }

    // MARK: - 响应解析

    @Test("解析出译文并去掉首尾空白")
    func parsesTranslationAndTrims() async throws {
        let recorder = RequestRecorder(
            reply: .status(200, Self.successBody("\n  We go live this afternoon.  \n")))
        let output = try await translator(recorder).translate(Self.source, to: .english)
        #expect(output == "We go live this afternoon.")
    }

    /// **多个 part 要拼起来，不是只取第一个。**
    ///
    /// 只取 `parts[0]` 的表现是「译文少了后半截、而且是成功返回」，与推理被
    /// 截断长得一模一样，事后分不开；闸门的截断判据主要看句末标点，接不住
    /// 「正好在句号处断开」的那一种。
    @Test("多个 part 的响应要拼完整")
    func joinsAllParts() async throws {
        let body = Data(
            """
            {"candidates":[{"content":{"parts":[{"text":"We go live "},\
            {"text":"this afternoon."}]},"finishReason":"STOP"}]}
            """.utf8)
        let recorder = RequestRecorder(reply: .status(200, body))
        let output = try await translator(recorder).translate(Self.source, to: .english)
        #expect(output == "We go live this afternoon.")
    }

    @Test("非 200 收敛为 .engineFailed(\"HTTP …\")")
    func nonOKStatusBecomesEngineFailed() async throws {
        let recorder = RequestRecorder(reply: .status(503, Data("{}".utf8)))
        await #expect(throws: TranslatorError.engineFailed("HTTP 503")) {
            _ = try await translator(recorder).translate(Self.source, to: .english)
        }
    }

    /// 400 要带上 gRPC 状态名：光一个 400 分不清是 key 不对还是模型名不对，
    /// 而这两件事用户要做的动作完全不同。
    ///
    /// **只取 `error.status`，不取 `error.message`**——message 是服务端的
    /// 自由文本，可能把请求里的内容回显出来，而请求里装的正是用户刚说的话，
    /// 它会经由流水线进日志。这条用例的 message 里故意放了一段中文原文，
    /// 断言它没有出现在错误里。
    @Test("非 200 带上 gRPC 状态名，但不带服务端的自由文本")
    func nonOKStatusCarriesGRPCStatusOnly() async throws {
        let body = Data(
            """
            {"error":{"code":400,"message":"Invalid input: 今天下午上线。","status":"INVALID_ARGUMENT"}}
            """.utf8)
        let recorder = RequestRecorder(reply: .status(400, body))

        do {
            _ = try await translator(recorder).translate(Self.source, to: .english)
            Issue.record("400 应当抛错")
        } catch let error as TranslatorError {
            guard case .engineFailed(let message) = error else {
                Issue.record("期望 .engineFailed，实际 \(error)")
                return
            }
            #expect(message.hasPrefix("HTTP 400"))
            #expect(message.contains("INVALID_ARGUMENT"))
            #expect(!message.contains("今天下午上线"), "服务端的自由文本进了错误消息：\(message)")
        }
    }

    @Test("结构不认识时说清是结构不认识")
    func unknownStructureIsReported() async throws {
        let recorder = RequestRecorder(reply: .status(200, Data("{\"whatever\":1}".utf8)))
        await #expect(throws: TranslatorError.engineFailed("响应结构不认识")) {
            _ = try await translator(recorder).translate(Self.source, to: .english)
        }
    }

    /// 结构认得、但一个字都没有（安全过滤拦下是最常见的）：
    /// 要带上 finishReason，否则这条错误看起来和「结构不认识」一样无从下手。
    @Test("有 candidate 却没有译文时带上 finishReason")
    func emptyCandidateCarriesFinishReason() async throws {
        let body = Data(#"{"candidates":[{"finishReason":"SAFETY"}]}"#.utf8)
        let recorder = RequestRecorder(reply: .status(200, body))

        do {
            _ = try await translator(recorder).translate(Self.source, to: .english)
            Issue.record("没有译文时应当抛错")
        } catch let error as TranslatorError {
            guard case .engineFailed(let message) = error else {
                Issue.record("期望 .engineFailed，实际 \(error)")
                return
            }
            #expect(message.contains("SAFETY"), "实际：\(message)")
            #expect(message != "响应结构不认识", "结构是认得的，说成不认识会让人去查错方向")
        }
    }

    // MARK: - 网络层错误

    /// 网络超时要收敛成 `.timedOut`，HUD 才会说「翻译超时」。
    ///
    /// 任 `URLError` 漏出去的话，流水线走的是兜底那条 catch，标注里是
    /// `Error` 的 `String(describing:)`——一串对用户毫无意义的结构体描述。
    @Test("网络超时收敛为 .timedOut")
    func networkTimeoutBecomesTimedOut() async throws {
        let recorder = RequestRecorder(reply: .failure(.timedOut))
        await #expect(throws: TranslatorError.timedOut) {
            _ = try await translator(recorder).translate(Self.source, to: .english)
        }
    }

    @Test("断网收敛为 .engineFailed，不漏 URLError")
    func offlineBecomesEngineFailed() async throws {
        let recorder = RequestRecorder(reply: .failure(.notConnectedToInternet))
        do {
            _ = try await translator(recorder).translate(Self.source, to: .english)
            Issue.record("断网时应当抛错")
        } catch let error as TranslatorError {
            guard case .engineFailed(let message) = error else {
                Issue.record("期望 .engineFailed，实际 \(error)")
                return
            }
            #expect(message.contains("\(URLError.Code.notConnectedToInternet.rawValue)"))
        } catch {
            Issue.record("URLError 漏出去了：\(error)")
        }
    }
}

/// 一个能在 `@Sendable` 闭包里改的盒子。
///
/// 只为「key 每次请求都重新读」那条用例存在：要在两次调用之间把值换掉，
/// 而闭包必须是 `@Sendable`。
final class MutableBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) {
        storage = value
    }

    var value: T {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
