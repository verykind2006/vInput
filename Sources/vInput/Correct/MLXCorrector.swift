import Foundation
import MLXLLM
import MLXLMCommon

/// 基于 MLX 的本地校正器。
///
/// 用 actor 而非 class：模型加载与推理都不可重入，两次会话同时触发时
/// 第二个必须排队而不是并发进入。与 `WhisperKitTranscriber` 同一考量。
actor MLXCorrector: Corrector {
    /// 模型加载走 `OneShotLoader`，而不是 `guard container == nil`。
    ///
    /// 直接在本 actor 里加载有两个坑：加载会随调用方的取消一起被掐断
    /// （3 秒超时一到就前功尽弃，模型永远等不到就绪），且两次并发调用会
    /// 各自启动一次加载（判重的 await 之间有空隙）。两条都由闸门解决。
    ///
    /// 模型目录为 nil 时按 Hugging Face 标识符下载。优先支持本地目录，
    /// 与 Whisper 同一考量：内置下载器在本机网络下会整体超时放弃，
    /// 模型一律预先拉好再指过来。
    private let loader: OneShotLoader<ModelContainer>

    init(
        modelDirectory: URL? = nil,
        modelID: String = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    ) {
        loader = OneShotLoader {
            do {
                if let modelDirectory {
                    return try await loadModelContainer(directory: modelDirectory)
                }
                return try await loadModelContainer(id: modelID)
            } catch {
                throw CorrectorError.engineFailed(error.localizedDescription)
            }
        }
    }

    var isReady: Bool {
        get async { await loader.ready != nil }
    }

    func prepare() async throws {
        _ = try await loader.value()
    }

    func edits(for text: String) async throws -> [CorrectionEdit] {
        // **不在这里等加载。** 加载要几十秒，而调用方带着 3 秒推理预算，
        // 等下去只会把注入一起拖住。未就绪就直说，由流水线退回原文并
        // 另行预热。
        guard let container = await loader.ready else { throw CorrectorError.modelNotReady }

        // 逐字段赋值而非用带标签的构造器：GenerateParameters 的字段在
        // 版本间增删过，逐字段赋值不受参数顺序与标签变化影响。
        var parameters = GenerateParameters()
        // 校正要的是确定性，不是创造力。同一句话每次都该得到同样的结果。
        parameters.temperature = 0
        // 替换清单本就极短——一句话里错三四个词已经很多了。
        // 256 是最初拍脑袋写的；压到 96 是因为生产方不受我们的取消影响
        // （`ChatSession.stream()` 内部是非结构化 Task，没有 onTermination），
        // 超时后它仍会跑完，而 `ModelContainer.perform` 串行会让它挡住下一次
        // 推理。让推理本身就短，比指望取消更可靠。
        parameters.maxTokens = 96

        // **每次新建 ChatSession。** 它内部持有对话历史，复用会让上一句
        // 转写污染下一句的校正。M2 曾因复用 AudioStreamTranscriber 导致
        // 第二次会话显示上次的文字，这是同一类错误。
        // 不传 instructions：上游会在每次 respond/streamResponse 时用
        // 赋值覆盖掉 messages，系统消息静默丢失（见 CorrectionPrompt.user）。
        // 规则已并进用户提示。
        let session = ChatSession(container, generateParameters: parameters)

        // 用流式而非 `respond(to:)`：后者走同步的 generate 循环，全程不检查
        // 取消（`Evaluate.swift:597-646`），我们的超时对它毫无作用。流式版本
        // 走的重载在 `Evaluate.swift:809` 有 `if Task.isCancelled { break }`，
        // 取消能让本循环立刻退出。
        //
        // 注意生产方仍会跑完：`ChatSession.stream()` 内部是非结构化 Task，
        // 取消消费方不会中断它。我们要的只是「注入路径上不干等」。
        var output = ""
        do {
            for try await chunk in session.streamResponse(to: CorrectionPrompt.user(for: text)) {
                try Task.checkCancellation()
                output += chunk
            }
        } catch is CancellationError {
            throw CorrectorError.timedOut
        } catch {
            throw CorrectorError.engineFailed(error.localizedDescription)
        }

        return CorrectionEditParser.parse(output)
    }
}
