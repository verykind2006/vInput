import Foundation
import Testing
import WhisperKit
@testable import vInput

/// 临时实验台：对比多个 initial prompt 候选。跑法：
/// VINPUT_PROMPTLAB=1 ./scripts/test.sh --filter PromptLab
@Suite(
    "PromptLab",
    .enabled(if: ProcessInfo.processInfo.environment["VINPUT_PROMPTLAB"] == "1"),
    .serialized
)
struct PromptLabTests {
    static let modelsRoot = "/Users/vk/Library/CloudStorage/OneDrive-个人/projects/vInput/vendor/models"
    static let audioRoot = "/tmp/vinput-bench"
    static let modelName = "openai_whisper-large-v3-v20240930_turbo"

    struct Variant {
        let id: String
        let text: String?
    }

    static let variants: [Variant] = [
        Variant(id: "A-现状", text: "对,这个我知道,那我们就先这样吧,回头再说。时间上没问题,你放心。"),
        Variant(id: "B-现状+术语句", text: "对,这个我知道,那我们就先这样吧,回头再说。用 Claude Code 和 GitHub Actions,最后部署到 AWS。"),
    ]

    static let speechFiles = ["techen", "pad_techen", "techen", "pad_techen"]
    static let quietFiles = [
        "silence15", "silence30", "noise10", "noise30", "noise_lp", "silence5",
    ]

    @Test("prompt 候选对比")
    func compare() async throws {
        let pipe = try await WhisperKit(
            WhisperKitConfig(modelFolder: "\(Self.modelsRoot)/\(Self.modelName)")
        )
        guard let tokenizer = pipe.tokenizer else {
            Issue.record("tokenizer 缺失"); return
        }

        var cache: [String: [Float]] = [:]
        func audio(_ name: String) throws -> [Float] {
            if let hit = cache[name] { return hit }
            let floats = try AudioProcessor.loadAudioAsFloatArray(
                fromPath: "\(Self.audioRoot)/\(name).wav"
            )
            cache[name] = floats
            return floats
        }

        for variant in Self.variants {
            let tokens = variant.text.map { WhisperKitTranscriber.encodePrompt($0, with: tokenizer) }
            print("\n########## \(variant.id) tokens=\(tokens?.count ?? 0) ##########")
            print("PROMPT: \(variant.text ?? "(无)")")

            let plan = Self.speechFiles + Array(repeating: Self.quietFiles, count: 8).flatMap { $0 }
            for name in plan {
                let floats = try audio(name)
                let options = DecodingOptions(
                    language: "zh",
                    skipSpecialTokens: true,
                    promptTokens: tokens,
                    suppressBlank: true,
                    chunkingStrategy: .vad
                )
                let results = try await pipe.transcribe(audioArray: floats, decodeOptions: options)
                let all = results.flatMap(\.segments)
                let before = WhisperKitTranscriber.textDroppingTrailingNonSpeech(all)
                let kept = WhisperKitTranscriber.segmentsDroppingFallbackFiller(all)
                let raw = WhisperKitTranscriber.textDroppingTrailingNonSpeech(kept)
                let final = ChineseScript.toSimplified(TranscriptCleaner.clean(raw))
                let marks = final.filter { "，。！？；：,.!?;:".contains($0) }.count
                print("[\(variant.id)] \(name) 标点=\(marks) 过滤前=「\(before)」 最终=「\(final)」")
            }
        }
    }
}
