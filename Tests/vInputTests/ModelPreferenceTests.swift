import Testing
@testable import vInput

@Suite("ModelPreference")
struct ModelPreferenceTests {
    @Test("偏好列表非空且无重复")
    func listIsWellFormed() {
        let models = ModelPreference.preferredModels
        #expect(!models.isEmpty)
        #expect(Set(models).count == models.count)
    }

    @Test("质量更高的模型排在前面")
    func orderedByQuality() {
        let models = ModelPreference.preferredModels
        let largeIndex = models.firstIndex(of: "openai_whisper-large-v3")
        let baseIndex = models.firstIndex(of: "openai_whisper-base")

        #expect(largeIndex != nil)
        #expect(baseIndex != nil)
        #expect(largeIndex! < baseIndex!)
    }

    @Test("base 作为最后的兜底")
    func baseIsFallback() {
        #expect(ModelPreference.preferredModels.last == "openai_whisper-base")
    }

    @Test("所有名称都是 fetch-model.sh 可接受的 HuggingFace 目录名")
    func namesLookLikeRepoDirectories() {
        for name in ModelPreference.preferredModels {
            // 不含路径分隔符与空白，否则拼进 URL 会出问题
            #expect(!name.contains("/"))
            #expect(!name.contains(" "))
            #expect(name.hasPrefix("openai_whisper-") || name.hasPrefix("distil-whisper_"))
        }
    }
}
