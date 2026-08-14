import Foundation
import Testing
import WhisperKit
@testable import vInput

/// 端到端管线体检。
///
/// **默认跳过**，需要真实模型与真实音频，跑一遍要一两分钟：
///
/// ```bash
/// ./scripts/bench.sh            # 先生成测试音频
/// VINPUT_E2E=1 ./scripts/test.sh --filter PipelineE2E
/// ```
///
/// 存在的理由：此前每个问题都是用户在真机上逐个发现、逐个反馈的——
/// 特殊标记漏出、结尾套话幻觉、跨会话状态残留、繁体输出，全是这么找到的。
/// 单元测试覆盖不到，因为它们只在「真模型 + 真音频 + 完整链路」下才出现。
///
/// 这里把真实音频喂进与 App 完全相同的转写路径，逐条断言那些**曾经真的
/// 出过问题**的性质。新发现一类问题就往这里加一条，而不是等下次再被发现。
@Suite(
    "PipelineE2E",
    .enabled(if: ProcessInfo.processInfo.environment["VINPUT_E2E"] == "1")
)
struct PipelineE2ETests {
    static let modelsRoot = "/Users/vk/Library/CloudStorage/OneDrive-个人/projects/vInput/vendor/models"
    static let audioRoot = "/tmp/vinput-bench"
    static let modelName = "openai_whisper-large-v3-v20240930_turbo"

    private func makeTranscriber() -> WhisperKitTranscriber {
        WhisperKitTranscriber(
            modelFolder: "\(Self.modelsRoot)/\(Self.modelName)",
            language: "zh"
        )
    }

    private func transcribe(_ sample: String) async throws -> String {
        let path = "\(Self.audioRoot)/\(sample).wav"
        let floats = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        return try await makeTranscriber().transcribe(floats)
    }

    @Test("输出不含 Whisper 特殊标记", arguments: ["chat", "short", "tech", "long"])
    func noSpecialTokens(sample: String) async throws {
        let text = try await transcribe(sample)
        // 真机出过两次：预览一次、最终注入一次。两次成因相同——
        // segment.text 是原始文本，而 TranscriptionResult.text 是处理过的。
        let hit = text.range(of: "<\\|[^|]*\\|>", options: .regularExpression)
        #expect(hit == nil, "含特殊标记：\(text.prefix(100))")
    }

    @Test("结尾不含套话幻觉", arguments: ["chat", "short", "tech", "long"])
    func noTrailingFiller(sample: String) async throws {
        let text = try await transcribe(sample)
        // 真机出过三次：「( 字幕:J Chong )」「谢谢观看」「谢谢大家」
        let fillers = ["谢谢观看", "谢谢大家", "感谢观看", "谢谢收看", "字幕", "点赞订阅"]
        let trailing = String(text.suffix(12))
        let hit = fillers.filter { trailing.contains($0) }
        #expect(hit.isEmpty, "结尾含 \(hit.joined(separator: "、"))：…\(trailing)")
    }

    @Test("输出为简体中文", arguments: ["chat", "short", "tech", "long"])
    func outputIsSimplified(sample: String) async throws {
        let text = try await transcribe(sample)
        // 真机出过：base 模型整段输出繁体
        #expect(ChineseScript.toSimplified(text) == text, "仍含繁体：\(text.prefix(60))")
    }

    @Test("转写结果非空", arguments: ["chat", "short", "tech", "long"])
    func outputIsNotEmpty(sample: String) async throws {
        let text = try await transcribe(sample)
        #expect(!text.isEmpty)
    }

    @Test("同一转写器连续两次结果一致")
    func repeatedTranscriptionIsStable() async throws {
        // 流式预览曾因跨会话复用实例而残留状态，这里确认最终转写路径没有
        // 同类问题——同一个 transcriber 连转两次必须给出相同结果。
        let floats = try AudioProcessor.loadAudioAsFloatArray(fromPath: "\(Self.audioRoot)/short.wav")
        let transcriber = makeTranscriber()

        let first = try await transcriber.transcribe(floats)
        let second = try await transcriber.transcribe(floats)

        #expect(!first.isEmpty)
        #expect(first == second, "第一次「\(first)」第二次「\(second)」")
    }

    @Test("蓝牙路径的音频能被转写管线正确消费")
    func bluetoothPathProducesUsableText() async throws {
        // 蓝牙音频经 IMA ADPCM 解码后是 Int16 PCM，再由
        // BluetoothRemoteSource 归一化成 Float。这里模拟那条路径：
        // 拿真实音频转成 Int16、走归一化、喂进与麦克风完全相同的转写路径。
        //
        // 验证的是「解码出来的音频能被现有管线消费」，无需外设。
        let floats = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: "\(Self.audioRoot)/short.wav"
        )
        let asInt16 = floats.map { Int16(max(-32_768, min(32_767, $0 * 32_768))) }
        let roundTripped = BluetoothRemoteSource.normalize(asInt16)

        let text = try await makeTranscriber().transcribe(roundTripped)

        #expect(!text.isEmpty)
        #expect(text.range(of: "<\\|[^|]*\\|>", options: .regularExpression) == nil)
        #expect(ChineseScript.toSimplified(text) == text)
    }

    @Test("Int16 往返不显著损失质量")
    func int16RoundTripPreservesQuality() async throws {
        // 若归一化的除数写错（用 32767 而非 32768），或某处溢出，
        // 转写结果会明显劣化。这里用同一段音频的两条路径对比。
        let floats = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: "\(Self.audioRoot)/short.wav"
        )
        let asInt16 = floats.map { Int16(max(-32_768, min(32_767, $0 * 32_768))) }
        let roundTripped = BluetoothRemoteSource.normalize(asInt16)

        let transcriber = makeTranscriber()
        let direct = try await transcriber.transcribe(floats)
        let viaInt16 = try await transcriber.transcribe(roundTripped)

        #expect(direct == viaInt16, "直接路径「\(direct)」Int16 往返「\(viaInt16)」")
    }
}
