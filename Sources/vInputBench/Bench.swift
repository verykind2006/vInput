import Foundation
import WhisperKit

/// 模型对比工具。用同一组音频跑多个模型，比较质量与耗时。
///
/// 用法：
/// ```bash
/// ./scripts/bench.sh
/// ```
///
/// 测试音频由 scripts/bench.sh 用系统 TTS 生成，覆盖三个目标场景：
/// 闲聊短句、技术术语密集、长文。
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

    static func discoverModels() -> [String] {
        let fm = FileManager.default
        let found = (try? fm.contentsOfDirectory(atPath: modelsRoot)) ?? []
        // 按 ModelPreference 的顺序排，未列入的排在后面
        let order = [
            "openai_whisper-base",
            "openai_whisper-small",
            "openai_whisper-medium",
            "openai_whisper-large-v3-v20240930_turbo",
            "openai_whisper-large-v3",
        ]
        return found
            .filter { !$0.hasPrefix(".") }
            .sorted { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
    }

    static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
