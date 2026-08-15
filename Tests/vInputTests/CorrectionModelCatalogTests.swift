import Foundation
import Testing

@testable import vInput

@Suite("校正模型目录校验")
struct CorrectionModelCatalogTests {
    /// 在临时目录里造一个模型目录，只放指定的文件。
    /// 每个用例一个 UUID 子目录，用完即删，测试之间互不干扰。
    private func makeFolder(files: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vinput-correction-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            try Data().write(to: dir.appendingPathComponent(file))
        }
        return dir
    }

    private func remove(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 完整的目录：结构描述、分词器配置、权重三样齐全。
    private static let complete = ["config.json", "tokenizer_config.json", "model.safetensors"]

    @Test("三样齐全的目录校验通过")
    func acceptsCompleteFolder() throws {
        let dir = try makeFolder(files: Self.complete + ["tokenizer.json", "vocab.json"])
        defer { remove(dir) }

        guard case .success(let descriptor) = CorrectionModelCatalog.validate(directory: dir) else {
            Issue.record("应校验通过"); return
        }
        #expect(descriptor.directory == dir)
        #expect(descriptor.name == dir.lastPathComponent)
    }

    @Test("缺 config.json 被拒，且提示里点名 config.json")
    func rejectsMissingConfig() throws {
        let dir = try makeFolder(files: ["tokenizer_config.json", "model.safetensors"])
        defer { remove(dir) }

        guard case .failure(.notAModelFolder(let missing)) =
                CorrectionModelCatalog.validate(directory: dir) else {
            Issue.record("应校验失败"); return
        }
        #expect(missing.contains("config.json"))
        // 只该报缺的那一样，否则用户不知道该补什么。
        #expect(!missing.contains("tokenizer_config.json"))
    }

    @Test("缺 tokenizer_config.json 被拒")
    func rejectsMissingTokenizerConfig() throws {
        let dir = try makeFolder(files: ["config.json", "model.safetensors"])
        defer { remove(dir) }

        guard case .failure(.notAModelFolder(let missing)) =
                CorrectionModelCatalog.validate(directory: dir) else {
            Issue.record("应校验失败"); return
        }
        #expect(missing == ["tokenizer_config.json"])
    }

    @Test("一个 .safetensors 都没有被拒")
    func rejectsMissingWeights() throws {
        let dir = try makeFolder(files: [
            "config.json", "tokenizer_config.json", "tokenizer.json", "README.md",
        ])
        defer { remove(dir) }

        guard case .failure(.notAModelFolder(let missing)) =
                CorrectionModelCatalog.validate(directory: dir) else {
            Issue.record("应校验失败"); return
        }
        #expect(missing == [CorrectionModelCatalog.weightsLabel])
    }

    /// 防止把权重判据写死成 `model.safetensors` 的回归测试。
    /// 大模型会分片，此时根本没有 `model.safetensors` 这个文件，
    /// 写死文件名会把一个完全合法的模型判为非法。
    @Test("分片权重（没有 model.safetensors）也算合法")
    func acceptsShardedWeights() throws {
        let dir = try makeFolder(files: [
            "config.json",
            "tokenizer_config.json",
            "model-00001-of-00002.safetensors",
            "model-00002-of-00002.safetensors",
            "model.safetensors.index.json",
        ])
        defer { remove(dir) }

        guard case .success = CorrectionModelCatalog.validate(directory: dir) else {
            Issue.record("分片模型应校验通过"); return
        }
    }

    /// `model.safetensors.index.json` 不以 `.safetensors` 结尾，
    /// 不该被误认成权重——否则只有索引没有权重的半下载目录会被放行。
    @Test("只有 index.json 没有权重时被拒")
    func indexAloneIsNotWeights() throws {
        let dir = try makeFolder(files: [
            "config.json", "tokenizer_config.json", "model.safetensors.index.json",
        ])
        defer { remove(dir) }

        guard case .failure(.notAModelFolder(let missing)) =
                CorrectionModelCatalog.validate(directory: dir) else {
            Issue.record("应校验失败"); return
        }
        #expect(missing == [CorrectionModelCatalog.weightsLabel])
    }

    @Test("空目录三样全缺")
    func rejectsEmptyFolder() throws {
        let dir = try makeFolder(files: [])
        defer { remove(dir) }

        guard case .failure(.notAModelFolder(let missing)) =
                CorrectionModelCatalog.validate(directory: dir) else {
            Issue.record("应校验失败"); return
        }
        #expect(missing.count == CorrectionModelCatalog.requiredFiles.count + 1)
    }

    /// 目录被移动/删除后走的就是这条路径，必须给提示而不是崩溃。
    @Test("不存在的目录报缺失而非崩溃")
    func rejectsNonexistentFolder() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vinput-absent-\(UUID().uuidString)")

        guard case .failure(.notAModelFolder(let missing)) =
                CorrectionModelCatalog.validate(directory: dir) else {
            Issue.record("应校验失败"); return
        }
        #expect(missing.count == CorrectionModelCatalog.requiredFiles.count + 1)
    }

    /// 判据是照着仓库里真实的 qwen3-4b 目录定的，用它兜一次底：
    /// 判据若哪天收得太紧，这条会先响。
    @Test("仓库自带的 qwen3-4b 目录校验通过", .enabled(if: FileManager.default.fileExists(
        atPath: CorrectionModelCatalogTests.repoModelPath)))
    func acceptsRepoModel() {
        let dir = URL(fileURLWithPath: Self.repoModelPath)
        guard case .success = CorrectionModelCatalog.validate(directory: dir) else {
            Issue.record("仓库自带的校正模型应校验通过"); return
        }
    }

    /// `#filePath` 指向 Tests/vInputTests/ 下，上溯三级到仓库根。
    static let repoModelPath: String = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Models/qwen3-4b-instruct-2507-4bit")
        .path
}
