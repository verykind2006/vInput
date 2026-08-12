import Foundation
import Testing
@testable import vInput

@Suite("ModelCatalog")
struct ModelCatalogTests {

    /// 在临时目录里造一个假的模型目录结构。
    private func makeRoot(models: [String: Bool]) throws -> String {
        let fm = FileManager.default
        let root = NSTemporaryDirectory()
            .appending("vinput-catalog-\(UUID().uuidString)")
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)

        for (name, complete) in models {
            let dir = (root as NSString).appendingPathComponent(name)
            let entries = complete
                ? ModelCatalog.requiredEntries
                : ["AudioEncoder.mlmodelc"]   // 残缺
            for entry in entries {
                try fm.createDirectory(
                    atPath: (dir as NSString).appendingPathComponent(entry),
                    withIntermediateDirectories: true
                )
            }
        }
        return root
    }

    // MARK: - 校验

    @Test("完整的模型目录校验通过")
    func validatesCompleteFolder() throws {
        let root = try makeRoot(models: ["openai_whisper-base": true])
        let folder = (root as NSString).appendingPathComponent("openai_whisper-base")

        let result = ModelCatalog.validate(folder: folder)

        guard case .success(let descriptor) = result else {
            Issue.record("应校验通过，实际 \(result)"); return
        }
        #expect(descriptor.name == "openai_whisper-base")
        #expect(descriptor.folder == folder)
    }

    @Test("残缺的目录报告缺了哪些")
    func reportsMissingEntries() throws {
        let root = try makeRoot(models: ["broken": false])
        let folder = (root as NSString).appendingPathComponent("broken")

        let result = ModelCatalog.validate(folder: folder)

        guard case .failure(.notAModelFolder(let missing)) = result else {
            Issue.record("应校验失败，实际 \(result)"); return
        }
        #expect(missing.contains("TextDecoder.mlmodelc"))
        #expect(missing.contains("MelSpectrogram.mlmodelc"))
        #expect(!missing.contains("AudioEncoder.mlmodelc"))
    }

    @Test("完全不存在的目录也报缺失而非崩溃")
    func nonexistentFolderIsRejected() {
        let result = ModelCatalog.validate(folder: "/nonexistent/path/xyz")

        guard case .failure(.notAModelFolder(let missing)) = result else {
            Issue.record("应校验失败"); return
        }
        #expect(missing.count == ModelCatalog.requiredEntries.count)
    }

    // MARK: - 发现

    @Test("只列出结构完整的模型")
    func discoverSkipsIncomplete() throws {
        let root = try makeRoot(models: [
            "openai_whisper-base": true,
            "openai_whisper-large-v3": true,
            "半下载的模型": false,
        ])

        let found = ModelCatalog.discover(in: root)

        #expect(found.count == 2)
        #expect(!found.contains { $0.name == "半下载的模型" })
    }

    @Test("按偏好顺序排列，turbo 优先于 large-v3，base 垫底")
    func discoverSortsByPreference() throws {
        let root = try makeRoot(models: [
            "openai_whisper-base": true,
            "openai_whisper-large-v3": true,
            "openai_whisper-large-v3-v20240930_turbo": true,
        ])

        let names = ModelCatalog.discover(in: root).map(\.name)

        // 默认取速度与质量的平衡点：turbo 比 large-v3 快 3–5.5 倍，
        // 其代价（个别错字、长文标点缺失）由 M4 润色层解决。
        #expect(names == [
            "openai_whisper-large-v3-v20240930_turbo",
            "openai_whisper-large-v3",
            "openai_whisper-base",
        ])
    }

    @Test("偏好列表之外的模型排在后面并按名称排序")
    func unknownModelsGoLast() throws {
        let root = try makeRoot(models: [
            "openai_whisper-base": true,
            "zzz-custom": true,
            "aaa-custom": true,
        ])

        let names = ModelCatalog.discover(in: root).map(\.name)

        #expect(names.first == "openai_whisper-base")
        #expect(Array(names.dropFirst()) == ["aaa-custom", "zzz-custom"])
    }

    @Test("空目录返回空列表")
    func emptyRootYieldsNothing() throws {
        let root = try makeRoot(models: [:])
        #expect(ModelCatalog.discover(in: root).isEmpty)
    }

    @Test("不存在的根目录返回空列表而非崩溃")
    func missingRootIsSafe() {
        #expect(ModelCatalog.discover(in: "/nonexistent/root/xyz").isEmpty)
    }

    // MARK: - 默认位置

    @Test("默认模型根目录相对 .app 上溯两级")
    func defaultRootResolution() {
        let bundle = URL(fileURLWithPath: "/repo/dist/vInput.app")
        #expect(ModelCatalog.defaultRoot(appBundleURL: bundle) == "/repo/vendor/models")
    }
}
