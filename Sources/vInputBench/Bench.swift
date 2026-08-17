import Foundation
import WhisperKit

/// 模型对比与切换诊断工具。
///
/// 用法：
/// ```bash
/// ./scripts/bench.sh          # 对比所有模型
/// ./scripts/bench.sh switch   # 诊断运行时切换
/// ```
///
/// **本工具的输出不代表生产管线，不要拿它评估产品表现。** 它直接调
/// WhisperKit，用的是不挂 initial prompt 的 `benchDecodingOptions`，而生产的
/// `WhisperKitTranscriber` 还有条件前缀、短音频补白、结尾套话过滤、繁简转换。
/// **要评估生产表现请用 `./scripts/bench-run.sh`**——它跑的是真正的
/// `WhisperKitTranscriber`，零复刻（`Tests/vInputTests/BenchRunnerTests.swift`）。
/// 本工具回答的是另一类问题：模型能不能加载、切换后还转不转得出来、
/// 各模型的相对速度。
///
/// **本文件刻意不再复刻任何生产参数。** 这里原有一个 `WhisperKitTranscriberShim`，
/// 注释写着「与生产同源，改一处要改两处」，而两次都只改了一处：M4 期间差了
/// `skipSpecialTokens` 与 `promptTokens`；M5 把 prompt 从 63 字换成 124 字
/// （提交 036240e）时 shim 又没跟上，2026-08-17 独立验收才查出来。
/// **复刻必然漂移，注释拦不住。**
///
/// 技术上可以让 `vInputBench` 依赖 `vInput` 目标（实测 SPM 允许可执行目标
/// 之间依赖，能编过），但代价是把生产类型改成 `public`，并把整个 App 连同
/// MLX 链进这个诊断工具——`./scripts/bench.sh` 从此要先做一遍 MLX 的 release
/// 构建。为一个诊断工具付这个代价不值得。所以选择是：**不复刻，也不假装
/// 等同**，质量结论一律交给 bench-run.sh。
@main
struct Bench {
    static let modelsRoot =
        "/Users/vk/Library/CloudStorage/OneDrive-个人/projects/vInput/vendor/models"
    static let audioRoot = "/tmp/vinput-bench"

    /// 本工具两条路径共用的解码参数。**不挂 initial prompt，与生产不同**，
    /// 见文件头。
    ///
    /// 三项取值与 main 上 `compareModels()` 里的完全一致，只是提出来给切换
    /// 诊断共用——一个文件里长出第二套「看起来像生产」的参数，正是那个 shim
    /// 的来路。
    static let benchDecodingOptions = DecodingOptions(
        language: "zh", suppressBlank: true, chunkingStrategy: .vad
    )

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

    /// 加载一个模型并转写一次，返回加载耗时、转写耗时与文本。
    static func loadAndTranscribe(
        model: String, audio: [Float]
    ) async throws -> (load: Double, run: Double, text: String) {
        var t = Date()
        let pipe = try await WhisperKit(
            WhisperKitConfig(modelFolder: "\(modelsRoot)/\(model)")
        )
        let load = Date().timeIntervalSince(t)

        t = Date()
        let results = try await pipe.transcribe(
            audioArray: audio, decodeOptions: benchDecodingOptions
        )
        let text = results.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (load, Date().timeIntervalSince(t), text)
    }

    /// 复现运行时切换：加载第一个模型转写一次，再加载第二个转写一次。
    ///
    /// 它回答的问题是「切换之后还转不转得出来」——那是模型加载与解码器生命
    /// 周期的问题，**与 initial prompt 无关**，所以这里用
    /// `benchDecodingOptions` 而不复刻生产参数（见文件头）。要看切换后的
    /// 转写**质量**，换模型跑两次 `./scripts/bench-run.sh` 再 diff 两份归档。
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
        do {
            let run = try await loadAndTranscribe(model: first, audio: floats)
            print("  加载 \(fmt(run.load))s")
            print("  转写 \(fmt(run.run))s → \(quoted(run.text))")
        } catch {
            print("  失败: \(error)"); exit(1)
        }

        print("\n切换到: \(second)")
        do {
            let run = try await loadAndTranscribe(model: second, audio: floats)
            print("  加载 \(fmt(run.load))s  ← App 在此期间禁用录音")
            print("  转写 \(fmt(run.run))s → \(quoted(run.text))")
            if run.text.isEmpty {
                print("\n*** 复现：切换后转写结果为空 ***")
            } else {
                print("\n切换后转写正常。若 App 中无输出，问题在 UI 层而非转写层。")
            }
        } catch {
            print("  失败: \(error)")
        }
    }

    // MARK: - 模型对比

    /// 逐个模型跑同一批 TTS 音频，看加载耗时、转写耗时与输出。
    ///
    /// **这里的输出不代表生产管线**：`benchDecodingOptions` 不挂 initial
    /// prompt，而生产的 `WhisperKitTranscriber` 挂着一段 124 字的条件前缀
    /// （标点密度与技术专名写法几乎全靠它），另有短音频补白、结尾套话过滤、
    /// 繁简转换。**要评估生产表现请用 `./scripts/bench-run.sh`。**
    /// 本函数适合回答「哪个模型加载快、转写快、大致听不听得清」。
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
                    audioArray: floats, decodeOptions: benchDecodingOptions
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
