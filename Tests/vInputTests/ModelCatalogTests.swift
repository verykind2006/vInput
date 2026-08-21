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

    // MARK: - 并进「用户导入的目录」

    /// 导入的目录住在根目录**外面**，`discover` 永远看不到它们。
    /// 不并进来的话，从 `~/Desktop/` 导入的模型下次启动就从面板里消失了。
    @Test("导入的目录并进列表")
    func mergeAddsImportedFolders() {
        let discovered = [ModelDescriptor(name: "openai_whisper-base", folder: "/root/base")]
        let merged = ModelCatalog.merge(
            discovered: discovered, imported: ["/Desktop/turbo"],
            validate: { folder in
                .success(ModelDescriptor(name: "openai_whisper-large-v3-v20240930_turbo",
                                         folder: folder))
            })
        #expect(merged.map(\.folder) == ["/Desktop/turbo", "/root/base"])
    }

    /// 已经在根目录里扫到的那个，不许因为也被记进导入列表而出现两次。
    ///
    /// 这不只是难看：`ModelDescriptor.id` 就是 folder，`ForEach` 撞 id 会
    /// 直接渲染异常。用户经「其他目录…」重新指一次根目录里那个模型，
    /// 就走到这条路上。
    @Test("同一个目录不出现两次")
    func mergeDeduplicatesByFolder() {
        let discovered = [ModelDescriptor(name: "turbo", folder: "/root/turbo")]
        let merged = ModelCatalog.merge(
            discovered: discovered, imported: ["/root/turbo"],
            validate: { .success(ModelDescriptor(name: "turbo", folder: $0)) })
        #expect(merged.map(\.folder) == ["/root/turbo"])
    }

    /// 已经不合法的导入目录**静默丢掉**，不报错、不进列表。
    ///
    /// 这是在建列表，不是用户刚点了什么——一句没有上下文的红字比不显示更糟。
    /// 真正的「忘掉它」在 `ImportedModelPreference.revalidate`。
    @Test("失效的导入目录丢掉而不报错")
    func mergeSkipsInvalidImports() {
        let merged = ModelCatalog.merge(
            discovered: [], imported: ["/gone"],
            validate: { _ in .failure(.notAModelFolder(missing: ["AudioEncoder.mlmodelc"])) })
        #expect(merged.isEmpty)
    }

    /// 排序与 `discover` 完全一致：偏好里的排前面，其余按名称。
    /// 各写一份的话，导入的模型会插在一个跟别人不一样的位置上。
    @Test("并进来之后仍按偏好排序")
    func mergeSortsLikeDiscover() {
        let discovered = [ModelDescriptor(name: "zzz-custom", folder: "/root/zzz")]
        let merged = ModelCatalog.merge(
            discovered: discovered,
            imported: ["/Desktop/turbo", "/Desktop/aaa"],
            validate: { folder in
                let name = folder.hasSuffix("turbo")
                    ? "openai_whisper-large-v3-v20240930_turbo" : "aaa-custom"
                return .success(ModelDescriptor(name: name, folder: folder))
            })
        #expect(
            merged.map(\.name)
                == ["openai_whisper-large-v3-v20240930_turbo", "aaa-custom", "zzz-custom"])
    }

    // MARK: - 「这个目录在不在根目录底下」

    /// 根目录里的模型不必记进导入偏好（`discover` 自己扫得到）。
    @Test("根目录底下的目录判为 true")
    func isUnderRecognisesChildren() {
        #expect(ModelCatalog.isUnder(folder: "/a/models/turbo", root: "/a/models"))
        #expect(ModelCatalog.isUnder(folder: "/a/models/turbo", root: "/a/models/"))
    }

    /// **只差一个尾斜杠的兄弟目录不许算进来。** 不补尾斜杠就比较的话，
    /// `/a/models-old/turbo` 会被判成「在根目录里」，于是它永远不会被记住
    /// ——重启即消失，正是这一条要修的东西。
    @Test("同前缀的兄弟目录不算在根目录底下")
    func isUnderDoesNotMatchSiblingPrefixes() {
        #expect(ModelCatalog.isUnder(folder: "/a/models-old/turbo", root: "/a/models") == false)
        #expect(ModelCatalog.isUnder(folder: "/Desktop/turbo", root: "/a/models") == false)
    }

    /// 根目录还没算出来（bootstrap 没跑完）时一律 false——
    /// 失败方向是「记住它」，多记一条只是多复核一次，漏记是模型消失。
    @Test("根目录为空时一律 false")
    func isUnderIsFalseForEmptyRoot() {
        #expect(ModelCatalog.isUnder(folder: "/a/turbo", root: "") == false)
        #expect(ModelCatalog.isUnder(folder: "", root: "/a/models") == false)
    }

    /// 「一个模型都没有」那个占位描述符：**folder 必须是空字符串**——
    /// `AppModel.makeTranscriber` 就是靠它认出「没有模型」的。
    /// 名字会原样显示在面板的模型行上，所以它得是人话，
    /// 而不是原先那个盘上根本不存在的 `openai_whisper-base`。
    @Test("零模型占位符的目录是空的")
    func noModelPlaceholderHasNoFolder() {
        #expect(ModelCatalog.noModel.folder.isEmpty)
        #expect(ModelCatalog.noModel.name.contains("还没有"))
    }
}
