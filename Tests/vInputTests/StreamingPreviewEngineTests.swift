import Testing
import WhisperKit
@testable import vInput

@Suite("StreamingPreviewEngine 状态转换")
struct StreamingPreviewEngineTests {
    private func segment(_ text: String, id: Int = 0) -> TranscriptionSegment {
        TranscriptionSegment(
            id: id, seek: 0, start: 0, end: 1, text: text,
            tokens: [], tokenLogProbs: [], temperature: 0,
            avgLogprob: 0, compressionRatio: 1, noSpeechProb: 0
        )
    }

    @Test("已确认与未确认分别拼接")
    func splitsConfirmedAndUnconfirmed() {
        let preview = StreamingPreviewEngine.makePreview(
            confirmedSegments: [segment("已经确定的"), segment("这一段")],
            unconfirmedSegments: [segment("还可能改")],
            bufferEnergy: []
        )

        #expect(preview.confirmed == "已经确定的这一段")
        #expect(preview.unconfirmed == "还可能改")
    }

    @Test("能量数据原样带出")
    func carriesEnergy() {
        let preview = StreamingPreviewEngine.makePreview(
            confirmedSegments: [],
            unconfirmedSegments: [],
            bufferEnergy: [0.1, 0.5, 0.9]
        )

        #expect(preview.energy == [0.1, 0.5, 0.9])
    }

    @Test("预览文本同样转成简体")
    func convertsToSimplified() {
        let preview = StreamingPreviewEngine.makePreview(
            confirmedSegments: [segment("測試繁體")],
            unconfirmedSegments: [],
            bufferEnergy: []
        )

        // 与最终文本保持一致，否则松手瞬间会看到字形跳变
        #expect(preview.confirmed == "测试繁体")
    }

    @Test("空状态产出空预览")
    func emptyStateYieldsEmptyPreview() {
        let preview = StreamingPreviewEngine.makePreview(
            confirmedSegments: [],
            unconfirmedSegments: [],
            bufferEnergy: []
        )

        #expect(preview.confirmed.isEmpty)
        #expect(preview.unconfirmed.isEmpty)
        #expect(preview.energy.isEmpty)
    }
}
