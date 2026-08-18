import Foundation
import MLXLLM
import MLXLMCommon
import Testing

@testable import vInput

/// 本地模型能否胜任翻译的一次性探针。
///
/// **不是回归测试，不做断言。** 它只是把模型的实际输出和耗时打出来，
/// 供人判断「一切不出本机」这条原则能否覆盖 M8 的多语种输出。
/// 结论落定后应当删除，或改写成带断言的正式测试。
///
/// 门控用标记文件而非环境变量：`xcodebuild test` 不把父进程环境传给
/// 测试运行器，实测会让整个套件被静默跳过而仍报 TEST SUCCEEDED
/// （与 `E2EGate` 同一考量）。
enum TranslationProbeGate {
    /// 仓库根：本文件在 `Tests/vInputTests/` 下，退三级。
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // vInputTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
    }

    static var markerURL: URL {
        repositoryRoot.appendingPathComponent("Testing/.translate-probe")
    }

    static var modelDirectory: URL? {
        guard let name = try? String(contentsOf: markerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else { return nil }
        return repositoryRoot.appendingPathComponent("models/\(name)")
    }

    static var isEnabled: Bool {
        guard let directory = modelDirectory else { return false }
        return FileManager.default.fileExists(atPath: directory.path)
    }
}

/// 素材取自用户 2026-08-17 的真实听写日志，不是编的。
/// 编造的句子测不出真实用法里的中英混排与技术术语。
private struct Sample {
    let label: String
    let text: String
}

private let samples: [Sample] = [
    Sample(
        label: "口语",
        text: "昨天去逛了一下华强北,还是看到挺多好玩的新东西的。"
    ),
    Sample(
        label: "技术+中英混排",
        text: "好的,没问题,我对你 M8 规划的分场景优化目前有点疑虑,"
            + "因为本地模型肯定是不具备这种能力的,到时候还要调云端模型。"
    ),
    // 用户明确说过未来会口述报价这类机密内容——这正是最需要翻译、
    // 又最不能出本机的一类，必须测。
    Sample(
        label: "商务/报价",
        text: "这批货的单价是每件十二美元五角,起订量五百件,"
            + "海运到鹿特丹大概要三十五天,付款方式是电汇预付三成。"
    ),
]

private let targets = [("英语", "English"), ("西班牙语", "Spanish")]

@Suite("翻译能力探针", .enabled(if: TranslationProbeGate.isEnabled), .serialized)
struct TranslationProbeTests {
    /// 全套共用一个实例：`OneShotLoader` 判重，只有第一次真的加载，
    /// 否则六次翻译要重复加载六遍 4GB 模型。
    private static let container: ModelContainer? = {
        guard let directory = TranslationProbeGate.modelDirectory else { return nil }
        return try? runBlocking { try await loadModelContainer(directory: directory) }
    }()

    @Test("把中文翻译成英语与西班牙语")
    func translate() async throws {
        let container = try #require(
            Self.container,
            "模型加载失败，检查 Testing/.translate-probe 指向的目录"
        )

        let name = TranslationProbeGate.modelDirectory?.lastPathComponent ?? "?"
        print("\n========== 翻译探针：\(name) ==========\n")

        for sample in samples {
            for (zhName, enName) in targets {
                var parameters = GenerateParameters()
                // 与校正层一致：要确定性，同一句每次该得到同样结果。
                parameters.temperature = 0
                // 译文可能比原文长不少，96 不够（校正层用 96 是因为
                // 替换清单极短）。
                parameters.maxTokens = 512

                // 每次新建：ChatSession 持有对话历史，复用会让上一句
                // 污染下一句。
                //
                // 规则写进用户消息而不用 instructions：上游在每次
                // respond/streamResponse 时用赋值覆盖 messages，系统消息
                // 会被静默丢弃（见 CorrectionPrompt.user 的注释）。
                let session = ChatSession(container, generateParameters: parameters)
                let prompt = """
                    Translate the following Chinese text into \(enName). \
                    Output only the translation, with no explanation, no pinyin, \
                    and no original text.

                    \(sample.text)
                    """

                let started = Date()
                var output = ""
                for try await chunk in session.streamResponse(to: prompt) {
                    output += chunk
                }
                let elapsed = Date().timeIntervalSince(started)

                print("[\(sample.label) → \(zhName)] 耗时 \(String(format: "%.2f", elapsed)) 秒")
                print("  原文：\(sample.text)")
                print("  译文：\(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                print("")
            }
        }

        print("========== 探针结束 ==========\n")
    }
}

/// 在 `static let` 初始化里跑异步代码。仅供本探针使用。
private func runBlocking<T: Sendable>(
    _ work: @escaping @Sendable () async throws -> T
) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = UncheckedBox<Result<T, Error>?>(nil)
    Task {
        do { box.value = .success(try await work()) } catch { box.value = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    guard let result = box.value else { throw CorrectorError.modelNotReady }
    return try result.get()
}

private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
