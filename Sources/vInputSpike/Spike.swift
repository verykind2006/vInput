import Foundation
import WhisperKit

/// 一次性可行性验证。Task 2 结束时连同整个 target 一起删除。
@main
struct Spike {
    static func main() async {
        let start = Date()
        do {
            print("[spike] 正在加载模型（首次会下载，可能需要几分钟）…")
            let pipe = try await WhisperKit(WhisperKitConfig(model: "base"))
            print("[spike] 模型就绪，耗时 \(Int(Date().timeIntervalSince(start))) 秒")

            let path = "/tmp/vinput-spike/sample.wav"
            let floats = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
            print("[spike] 音频样本数: \(floats.count)  时长约 \(String(format: "%.2f", Double(floats.count) / 16_000)) 秒")

            let transcribeStart = Date()
            let results = try await pipe.transcribe(
                audioArray: floats,
                decodeOptions: DecodingOptions(language: "zh")
            )
            let text = results.map(\.text).joined()
            print("[spike] 转写耗时 \(String(format: "%.2f", Date().timeIntervalSince(transcribeStart))) 秒")
            print("[spike] 转写结果: \(text)")
        } catch {
            print("[spike] 失败: \(error)")
            exit(1)
        }
    }
}
