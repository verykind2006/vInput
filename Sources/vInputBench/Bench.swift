import Foundation
import WhisperKit

/// 临时对比工具：同一段音频跑不同模型，比较质量与耗时。用完删除。
@main
struct Bench {
    static func main() async {
        let root = "/Users/vk/Library/CloudStorage/OneDrive-个人/projects/vInput/vendor/models"
        let audio = "/tmp/vinput-spike/sample.wav"
        let models = ["openai_whisper-base", "openai_whisper-large-v3"]

        guard let floats = try? AudioProcessor.loadAudioAsFloatArray(fromPath: audio) else {
            print("音频加载失败"); exit(1)
        }
        let seconds = Double(floats.count) / 16_000
        print("音频时长 \(String(format: "%.2f", seconds)) 秒\n")

        for name in models {
            do {
                let loadStart = Date()
                let pipe = try await WhisperKit(WhisperKitConfig(modelFolder: "\(root)/\(name)"))
                let loadTime = Date().timeIntervalSince(loadStart)

                let start = Date()
                let results = try await pipe.transcribe(
                    audioArray: floats,
                    decodeOptions: DecodingOptions(
                        language: "zh", suppressBlank: true, chunkingStrategy: .vad
                    )
                )
                let elapsed = Date().timeIntervalSince(start)
                let raw = results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)

                print("【\(name)】")
                print("  加载 \(String(format: "%.1f", loadTime))s   转写 \(String(format: "%.2f", elapsed))s   实时倍率 \(String(format: "%.1f", seconds/elapsed))x")
                print("  原始: \(raw)")
                print("")
            } catch {
                print("【\(name)】失败: \(error)\n")
            }
        }
    }
}
