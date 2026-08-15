import Foundation

/// 一个可用的本地 MLX 校正模型。
struct CorrectionModelDescriptor: Equatable, Sendable {
    /// 目录名，用作菜单里的显示名。
    let name: String
    /// 模型目录。
    let directory: URL
}

enum CorrectionModelCatalogError: Error, Equatable {
    /// 目录存在但不是 MLX 模型目录。
    case notAModelFolder(missing: [String])
}

/// 校验本地 MLX 校正模型目录。
///
/// 与 `ModelCatalog` 对 Whisper 做的是同一件事，只是判据不同：MLX 模型是
/// Hugging Face 布局的一堆文件，而不是三个 `.mlmodelc` 目录。分成两个类型
/// 而非合并：两边的必需项没有交集，合并只会得到一个带模式开关的函数。
enum CorrectionModelCatalog {
    /// 必须存在的两个文件。
    ///
    /// - `config.json`：模型结构描述。MLX 靠它决定实例化哪种架构，
    ///   缺了它连「这是什么模型」都无从谈起。
    /// - `tokenizer_config.json`：分词器配置。文本进出模型都要过分词器。
    ///
    /// 刻意不要求 `tokenizer.json`：部分模型只带 `vocab.json` + `merges.txt`
    /// 的旧式分词器文件，把它列为必需会误杀。
    static let requiredFiles = ["config.json", "tokenizer_config.json"]

    /// 权重文件的后缀。
    ///
    /// **判据是「存在任意 `.safetensors` 文件」，而不是写死 `model.safetensors`。**
    /// 大模型会分片成 `model-00001-of-00003.safetensors`，此时根本没有
    /// `model.safetensors` 这个文件——写死文件名会把合法的分片模型判为非法。
    static let weightsSuffix = ".safetensors"

    /// 权重缺失时显示给用户的名字。缺的是「任意一个权重文件」，
    /// 报某个具体文件名会让用户去找一个本就不该存在的文件。
    static let weightsLabel = "*.safetensors（权重文件）"

    /// 校验目录是否为可用的 MLX 模型目录。
    ///
    /// 先校验再启用，而不是等加载失败：MLX 的加载错误发生在几十秒后的
    /// 后台任务里，且措辞晦涩，用户只会看到「校正开着但没生效」。
    static func validate(directory: URL) -> Result<CorrectionModelDescriptor, CorrectionModelCatalogError> {
        let fm = FileManager.default
        let folder = directory.path

        var missing = requiredFiles.filter {
            !fm.fileExists(atPath: (folder as NSString).appendingPathComponent($0))
        }
        if !hasWeights(in: folder) {
            missing.append(weightsLabel)
        }

        guard missing.isEmpty else {
            return .failure(.notAModelFolder(missing: missing))
        }
        return .success(
            CorrectionModelDescriptor(
                // 用 lastPathComponent 而非 URL 的 lastPathComponent 属性上
                // 可能残留的斜杠：NSOpenPanel 返回的目录 URL 带尾斜杠时，
                // standardized 后才拿得到干净的目录名。
                name: directory.standardizedFileURL.lastPathComponent,
                directory: directory
            )
        )
    }

    /// 目录下是否有任意权重文件。
    ///
    /// 目录不存在时 `contentsOfDirectory` 抛错，这里吞掉并当作「没有权重」，
    /// 于是不存在的目录会走到和空目录一样的「缺哪些」提示，而不是崩溃。
    private static func hasWeights(in folder: String) -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return entries.contains { $0.hasSuffix(weightsSuffix) }
    }
}
