import Foundation
import WhisperKit

/// 模型对比与切换诊断工具。
///
/// 用法：
/// ```bash
/// ./scripts/bench.sh          # 对比所有模型
/// ./scripts/bench.sh switch   # 诊断运行时切换（走与 App 相同的代码路径）
/// ```
@main
struct Bench {
    static let modelsRoot =
        "/Users/vk/Library/CloudStorage/OneDrive-个人/projects/vInput/vendor/models"
    static let audioRoot = "/tmp/vinput-bench"

    struct Sample {
        let file: String
        let label: String
        let truth: String
    }

    static let samples = [
        Sample(
            file: "chat", label: "闲聊短句",
            truth: "行那我明天上午再看看这个事儿吧你先忙"
        ),
        Sample(
            file: "short", label: "技术短句",
            truth: "帮我把这个函数里的依赖数组改一下，然后跑一遍测试"
        ),
        Sample(
            file: "tech", label: "技术密集",
            truth: "把 useEffect 里的依赖数组补上 loading 状态，然后把这个组件的 props 类型定义抽到单独的文件里，顺便修一下快捷键之外的那个报错"
        ),
        Sample(
            file: "long", label: "长文",
            truth: "今天下午三点我们讨论一下发版计划，看看相关的计划是否可行，以及在可行范围内我们要付出怎样的代价，怎么用最小的代价实现我们的发版目标。另外还需要确认一下测试环境的准备情况，以及灰度发布的具体时间窗口，如果有风险要提前上报。"
        ),
    ]

    static func main() async {
        if CommandLine.arguments.contains("switch") {
            await diagnoseSwitching()
        } else {
            await compareModels()
        }
    }

    // MARK: - 切换诊断

    /// 复现 App 的运行时切换路径：large-v3 → turbo，两边各转写一次。
    static func diagnoseSwitching() async {
        let all = discoverModels()
        guard all.count >= 2 else {
            print("需要至少两个模型才能测切换，当前只有 \(all)"); exit(1)
        }
        let first = all[0]
        let second = all[1]

        guard let floats = try? AudioProcessor.loadAudioAsFloatArray(
            fromPath: "\(audioRoot)/short.wav"
        ) else {
            print("测试音频缺失，先跑一次 ./scripts/bench.sh"); exit(1)
        }

        print("初始模型: \(first)")
        var t = Date()
        let transcriber = WhisperKitTranscriberShim(name: first, root: modelsRoot)
        do {
            try await transcriber.prepare()
            print("  加载 \(fmt(Date().timeIntervalSince(t)))s")
            t = Date()
            let text = try await transcriber.transcribe(floats)
            print("  转写 \(fmt(Date().timeIntervalSince(t)))s → \(quoted(text))")
        } catch {
            print("  失败: \(error)"); exit(1)
        }

        print("\n切换到: \(second)")
        t = Date()
        let next = WhisperKitTranscriberShim(name: second, root: modelsRoot)
        do {
            try await next.prepare()
            print("  加载 \(fmt(Date().timeIntervalSince(t)))s  ← App 在此期间禁用录音")
            t = Date()
            let text = try await next.transcribe(floats)
            print("  转写 \(fmt(Date().timeIntervalSince(t)))s → \(quoted(text))")
            if text.isEmpty {
                print("\n*** 复现：切换后转写结果为空 ***")
            } else {
                print("\n切换后转写正常。若 App 中无输出，问题在 UI 层而非转写层。")
            }
        } catch {
            print("  失败: \(error)")
        }
    }

    // MARK: - 模型对比

    static func compareModels() async {
        let models = discoverModels()
        guard !models.isEmpty else {
            print("vendor/models 下没有模型"); exit(1)
        }
        print("待测模型: \(models.joined(separator: ", "))\n")

        for model in models {
            print(String(repeating: "=", count: 70))
            print("【\(model)】")
            print(String(repeating: "=", count: 70))

            let loadStart = Date()
            guard let pipe = try? await WhisperKit(
                WhisperKitConfig(modelFolder: "\(modelsRoot)/\(model)")
            ) else {
                print("加载失败\n"); continue
            }
            print("加载耗时 \(fmt(Date().timeIntervalSince(loadStart)))s\n")

            for sample in samples {
                let path = "\(audioRoot)/\(sample.file).wav"
                guard let floats = try? AudioProcessor.loadAudioAsFloatArray(fromPath: path) else {
                    print("  [\(sample.label)] 音频缺失: \(path)"); continue
                }
                let seconds = Double(floats.count) / 16_000

                let start = Date()
                let results = try? await pipe.transcribe(
                    audioArray: floats,
                    decodeOptions: DecodingOptions(
                        language: "zh", suppressBlank: true, chunkingStrategy: .vad
                    )
                )
                let elapsed = Date().timeIntervalSince(start)
                let raw = (results ?? []).map(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                print("  [\(sample.label)] 音频 \(fmt(seconds))s → 转写 \(fmt(elapsed))s (\(fmt(seconds / max(elapsed, 0.001)))x 实时)")
                print("    原文: \(sample.truth)")
                print("    输出: \(raw)")
                print("")
            }
        }
    }

    // MARK: - 辅助

    static func discoverModels() -> [String] {
        let fm = FileManager.default
        let found = (try? fm.contentsOfDirectory(atPath: modelsRoot)) ?? []
        let order = [
            "openai_whisper-large-v3",
            "openai_whisper-large-v3-v20240930_turbo",
            "openai_whisper-medium",
            "openai_whisper-small",
            "openai_whisper-base",
        ]
        return found
            .filter { !$0.hasPrefix(".") }
            .sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
    }

    static func fmt(_ value: Double) -> String { String(format: "%.2f", value) }
    static func quoted(_ text: String) -> String { text.isEmpty ? "(空)" : "「\(text)」" }
}

/// 复刻 App 中 WhisperKitTranscriber 的行为，用于诊断。
/// 保持与生产代码相同的 DecodingOptions。
actor WhisperKitTranscriberShim {
    private let folder: String
    private var pipe: WhisperKit?

    init(name: String, root: String) {
        self.folder = "\(root)/\(name)"
    }

    func prepare() async throws {
        guard pipe == nil else { return }
        pipe = try await WhisperKit(WhisperKitConfig(modelFolder: folder))
    }

    /// 引导标点与技术专名的 prompt token，与生产同源。
    ///
    /// **这段必须与 `WhisperKitTranscriber` 保持一致。** bench 存在的意义
    /// 是拿它做模型/参数对照（M5 要用它比 large-v3 与 turbo），一旦两边的
    /// `DecodingOptions` 不同，对照出来的差异就分不清是模型造成的还是参数
    /// 造成的——结论直接作废。
    ///
    /// 曾经就差了两项（`skipSpecialTokens` 与 `promptTokens`），而注释还写着
    /// 「保持与生产代码相同的 DecodingOptions」。
    private var promptTokens: [Int]?

    /// 与 `WhisperKitTranscriber.punctuationPrompt` 同源，改一处要改两处。
    /// 这是复刻工具的固有代价：bench 是独立的可执行目标，import 不到 vInput。
    static let punctuationPrompt =
        "对,这个我知道,那我们就先这样吧,回头再说。用 Claude Code 和 GitHub Actions,最后部署到 AWS。"

    func transcribe(_ samples: [Float]) async throws -> String {
        try await prepare()
        guard let pipe else { return "" }

        if promptTokens == nil, let tokenizer = pipe.tokenizer {
            promptTokens = tokenizer.encode(text: Self.punctuationPrompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }

        let results = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(
                language: "zh",
                skipSpecialTokens: true,
                promptTokens: promptTokens,
                suppressBlank: true,
                chunkingStrategy: .vad
            )
        )
        return results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
