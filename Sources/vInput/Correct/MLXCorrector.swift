import Foundation
import MLXLLM
import MLXLMCommon

/// 基于 MLX 的本地校正器。
///
/// 用 actor 而非 class：模型加载与推理都不可重入，两次会话同时触发时
/// 第二个必须排队而不是并发进入。与 `WhisperKitTranscriber` 同一考量。
actor MLXCorrector: Corrector {
    /// 本地模型目录。为 nil 时按 Hugging Face 标识符下载。
    ///
    /// 优先支持本地目录，与 Whisper 同一考量：内置下载器在本机网络下会
    /// 整体超时放弃，模型一律预先拉好再指过来。
    private let modelDirectory: URL?
    private let modelID: String
    private var container: ModelContainer?

    init(
        modelDirectory: URL? = nil,
        modelID: String = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    ) {
        self.modelDirectory = modelDirectory
        self.modelID = modelID
    }

    func prepare() async throws {
        guard container == nil else { return }
        do {
            container = if let modelDirectory {
                try await loadModelContainer(directory: modelDirectory)
            } else {
                try await loadModelContainer(id: modelID)
            }
        } catch {
            throw CorrectorError.engineFailed(error.localizedDescription)
        }
    }

    func edits(for text: String) async throws -> [CorrectionEdit] {
        try await prepare()
        guard let container else { throw CorrectorError.modelNotReady }

        // 逐字段赋值而非用带标签的构造器：GenerateParameters 的字段在
        // 版本间增删过，逐字段赋值不受参数顺序与标签变化影响。
        var parameters = GenerateParameters()
        // 校正要的是确定性，不是创造力。同一句话每次都该得到同样的结果。
        parameters.temperature = 0
        // 替换清单本就极短。设上限是为了让「模型开始滔滔不绝」这种失败
        // 快速结束，而不是拖到 3 秒超时才被打断。
        parameters.maxTokens = 256

        // **每次新建 ChatSession。** 它内部持有对话历史，复用会让上一句
        // 转写污染下一句的校正。M2 曾因复用 AudioStreamTranscriber 导致
        // 第二次会话显示上次的文字，这是同一类错误。
        let session = ChatSession(
            container,
            instructions: CorrectionPrompt.instructions,
            generateParameters: parameters
        )

        let output: String
        do {
            output = try await session.respond(to: CorrectionPrompt.user(for: text))
        } catch {
            throw CorrectorError.engineFailed(error.localizedDescription)
        }

        return CorrectionEditParser.parse(output)
    }
}
