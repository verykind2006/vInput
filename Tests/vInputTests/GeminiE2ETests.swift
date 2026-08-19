import Foundation
import Testing

@testable import vInput

/// 云端翻译的**真实联网**体检。默认跳过。
///
/// ```bash
/// # 先把 key 存进 Keychain（-w 后不带值，交互式输入，key 不进 shell 历史）
/// security add-generic-password -a vInput -s vinput-gemini-api-key -w
/// # 再跑
/// ./scripts/gemini-e2e.sh                    # 默认 gemini-2.0-flash
/// ./scripts/gemini-e2e.sh gemini-2.5-flash   # 换模型
/// ```
///
/// # 这套用例会把几句中文发到 Google 的服务器上
///
/// 这是它存在的全部意义：`GeminiTranslatorTests` 用假 `URLSession` 验的是
/// 请求形状与响应解析——那套用例在「Gemini 早就把响应结构改了」「端点搬家
/// 了」「key 的头名写错了」时**一条都不会红**。只有真发一次才知道。
///
/// 发出去的素材是本文件里写死的三句话，不是用户的任何真实内容。
///
/// # 门控用标记文件，不用环境变量
///
/// `xcodebuild test` 不把父进程环境传给测试运行器，实测结果是整个套件被
/// 静默跳过而仍报 `TEST SUCCEEDED`、退出码 0（`E2EGate` 与
/// `TranslationE2EGate` 都记着这一条）。
///
/// # 缺 key 是**失败**，不是跳过
///
/// `isEnabled` 只看标记文件，**不看 Keychain 里有没有 key**。看的话，
/// 用户没存 key 时整套体检会被静默跳过而报绿——而「有没有配对 key」正是
/// 他跑这套东西最想知道的事。缺 key 时下面第一条用例会红，并把存 key 的
/// 命令打出来。
///
/// # 串行
///
/// 免得四条用例同时打同一个配额（免费档有每分钟请求数上限），
/// 撞上 429 时报出来的是 `HTTP 429 RESOURCE_EXHAUSTED`，看起来像功能坏了。
@Suite("云端翻译端到端", .enabled(if: GeminiE2EGate.isEnabled), .serialized)
struct GeminiE2ETests {
    /// 真实翻译器：**默认 `URLSession` + 默认 key 来源**，一处替身都不用。
    /// 这套用例的价值全在「跟线上那条路一模一样」。
    private var translator: GeminiTranslator {
        GeminiTranslator(model: GeminiE2EGate.model)
    }

    private func report(_ label: String, source: String, result: TranslationResult, seconds: Double)
    {
        print("[云端 e2e] \(label) \(String(format: "%.1f", seconds))秒 模型=\(GeminiE2EGate.model)")
        print("    原文：\(source)")
        print("    译文：\(result.text)")
        print("    标注：\(result.annotation.map(String.init(describing:)) ?? "无")")
    }

    private func translate(
        _ source: String, to target: TranslationTarget, label: String
    ) async -> TranslationResult {
        // **闸门与超时都用默认值。** 两个数各自有实测支撑且各自有测试守着，
        // 在这里硬写等于绕过那两道守卫，而且不会有人发现。
        let pipeline = TranslationPipeline(translator: translator)
        let started = ContinuousClock.now
        let result = await pipeline.translate(source, to: target)
        let elapsed = ContinuousClock.now - started
        let seconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        report(label, source: source, result: result, seconds: seconds)
        return result
    }

    /// key 在不在。**不打印它，也不打印它的任何一部分。**
    ///
    /// 只断言「读得到」：长度、前缀都不断言——那些会随 Google 换发行格式而
    /// 变，而断言一个没量过的格式正是本仓库反复栽的那类。
    @Test("Keychain 里有 API key")
    func keyIsStored() throws {
        _ = try #require(
            TranslationKey.read(service: TranslationKey.geminiService),
            """
            Keychain 里没有 \(TranslationKey.geminiService)。先存一条：
                security add-generic-password -a vInput -s \(TranslationKey.geminiService) -w
            （-w 后不带值，回车后交互式输入，key 不进 shell 历史，也不进本仓库。）
            """
        )
    }

    /// 中译英，走完整条流水线。
    ///
    /// 断言全是机械判据：**没有标注**（等价于「真的走完了请求并过了闸门」，
    /// 因为翻译层一切失败都收敛为「中文原文 + 标注」）、**残留汉字为 0**、
    /// 译文与原文不同。语义对不对机器判不了，所以译文照样打印出来给人扫一眼。
    @Test("中译英出干净的英文")
    func translatesChineseIntoCleanEnglish() async {
        let source = "新功能的上线计划已经定了，下周三开始灰度。"
        let result = await translate(source, to: .english, label: "中译英")

        #expect(result.annotation == nil, "实际输出：\(result.text)")
        #expect(
            TranslationMetrics.residualHanCount(result.text) == 0,
            "译文里还有汉字。实际输出：\(result.text)")
        #expect(result.text != source, "译文与原文相同，说明翻译实际未生效")
    }

    /// 数字一个都不能丢——**报价场景最贵的错**。
    ///
    /// 素材用阿拉伯数字而不是中文数字：`TranslationMetrics.lostDigits` 只认
    /// ASCII 数字，「五百」译成 `five hundred` 是正确行为，拿它考数字保留
    /// 等于考了个假的（本地那套 e2e 记着同一条）。
    @Test("数字原样保留")
    func keepsDigits() async {
        let source = "这批货的单价是 12.5 美元，起订量 500 件。"
        let result = await translate(source, to: .english, label: "数字")

        #expect(result.annotation == nil, "实际输出：\(result.text)")
        #expect(
            TranslationMetrics.lostDigits(source: source, translation: result.text).isEmpty,
            "丢了数字。实际输出：\(result.text)")
    }

    /// 西语也走一遍：`TranslationPrompt` 里的语言名是拼出来的，
    /// 只测英文的话「语言名拼错」这类问题一条用例都碰不到。
    @Test("中译西出干净的西班牙文")
    func translatesChineseIntoSpanish() async {
        let source = "新功能的上线计划已经定了，下周三开始灰度。"
        let result = await translate(source, to: .spanish, label: "中译西")

        #expect(result.annotation == nil, "实际输出：\(result.text)")
        #expect(
            TranslationMetrics.residualHanCount(result.text) == 0,
            "译文里还有汉字。实际输出：\(result.text)")
    }

    /// **错的 key 要得到一个看得懂的错误，而不是崩溃或者一句空话。**
    ///
    /// 这条是唯一能验证「非 200 的解析对得上真实响应」的用例：
    /// 假 `URLSession` 那套用的是我自己编的错误体，Google 真回什么形状，
    /// 只有真发一次才知道。用的是明写的假 key，不动 Keychain 里那条。
    @Test("key 不对时收敛为看得懂的 HTTP 错误")
    func wrongKeyReportsHTTPError() async {
        let translator = GeminiTranslator(
            model: GeminiE2EGate.model, readKey: { "not-a-real-key-0000" })
        do {
            let output = try await translator.translate("你好。", to: .english)
            Issue.record("错的 key 竟然译出来了：\(output)")
        } catch let error as TranslatorError {
            guard case .engineFailed(let message) = error else {
                Issue.record("期望 .engineFailed，实际 \(error)")
                return
            }
            print("[云端 e2e] 错 key 的错误消息：\(message)")
            #expect(message.hasPrefix("HTTP 4"), "实际：\(message)")
        } catch {
            Issue.record("漏出了非 TranslatorError：\(error)")
        }
    }
}

/// 云端端到端体检的开关。
///
/// 与本地那两套（`E2EGate` / `TranslationE2EGate`）**各用各的标记文件**：
/// 本地两套各要几十秒到几分钟并占满 GPU，这套只要几秒但会烧配额，
/// 合用一个开关就没法只跑其中一套。
enum GeminiE2EGate {
    /// 仓库根目录下的标记文件。在 .gitignore 里排除——本机开关，
    /// 不该跟着提交跑到别人机器上。
    static let markerPath = "Testing/.gemini-e2e-enabled"

    /// 仓库根。**直接借 `E2EGate` 的**，不另写一遍 `#filePath` 回溯——
    /// 两处各写一份的话，目录层级一变只改一处，而漏掉的那一处的表现是
    /// 「套件被静默跳过」，正是这套门控最怕的假绿灯。
    static var repositoryRoot: URL { E2EGate.repositoryRoot }

    /// 标记文件的内容（模型名），去掉首尾空白。文件不存在或为空时返回空串。
    static var markerContents: String {
        let path = repositoryRoot.appendingPathComponent(markerPath).path
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 要测的模型。标记文件为空时用生产默认值——**跟着生产走，不另写一个**，
    /// 否则体检验的是一个线上根本不用的模型。
    static var model: String {
        markerContents.isEmpty ? GeminiTranslator.defaultModel : markerContents
    }

    /// **只看标记文件，不看 Keychain。** 理由见 `GeminiE2ETests` 的类型注释：
    /// 缺 key 必须是响亮的失败，不能是静默跳过。
    static var isEnabled: Bool {
        FileManager.default.fileExists(
            atPath: repositoryRoot.appendingPathComponent(markerPath).path)
    }
}
