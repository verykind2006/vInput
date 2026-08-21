import Foundation

/// 一个可用的本地模型。
struct ModelDescriptor: Equatable, Identifiable, Sendable {
    /// 目录名，同时用作显示名与 WhisperKit 的模型名。
    let name: String
    /// 模型目录的绝对路径。
    let folder: String

    var id: String { folder }
}

enum ModelCatalogError: Error, Equatable {
    /// 目录存在但不是 WhisperKit 模型目录。
    case notAModelFolder(missing: [String])
}

/// 发现并校验本地模型目录。
enum ModelCatalog {
    /// WhisperKit 模型目录必须包含的三个子目录。
    ///
    /// 用它校验用户手选的目录，避免选错时只得到一个难以理解的加载错误。
    static let requiredEntries = [
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
    ]

    /// 校验目录是否为可用的 WhisperKit 模型目录。
    static func validate(folder: String) -> Result<ModelDescriptor, ModelCatalogError> {
        let fm = FileManager.default
        let missing = requiredEntries.filter {
            !fm.fileExists(atPath: (folder as NSString).appendingPathComponent($0))
        }
        guard missing.isEmpty else {
            return .failure(.notAModelFolder(missing: missing))
        }
        return .success(
            ModelDescriptor(name: (folder as NSString).lastPathComponent, folder: folder)
        )
    }

    /// 列出目录下所有合法的模型，按 `ModelPreference` 的顺序排列，
    /// 未列入偏好的排在后面并按名称排序。
    static func discover(in root: String) -> [ModelDescriptor] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: root)) ?? []

        let models = entries
            .filter { !$0.hasPrefix(".") }
            .compactMap { name -> ModelDescriptor? in
                let path = (root as NSString).appendingPathComponent(name)
                guard case .success(let descriptor) = validate(folder: path) else { return nil }
                return descriptor
            }

        return sortedByPreference(models)
    }

    /// `discover` 与 `merge` 共用的排序。抽出来是因为两处各写一份的话，
    /// 「导入的模型排在哪」会跟「扫出来的模型排在哪」各走各的。
    nonisolated static func sortedByPreference(
        _ models: [ModelDescriptor]
    ) -> [ModelDescriptor] {
        models.sorted { lhs, rhs in
            let li = ModelPreference.preferredModels.firstIndex(of: lhs.name) ?? .max
            let ri = ModelPreference.preferredModels.firstIndex(of: rhs.name) ?? .max
            if li != ri { return li < ri }
            return lhs.name < rhs.name
        }
    }

    /// 把「用户导入的目录」并进「根目录里扫出来的」。
    ///
    /// 导入的模型（`ImportedModelPreference`）住在根目录外面，`discover`
    /// 永远看不到它们——不并进来的话，从 `~/Desktop/` 导入的模型这一次
    /// 能用，下次启动面板里就没有了。
    ///
    /// 三条规矩：
    /// - **按路径去重**。导入的目录后来被搬进了根目录（或者用户经
    ///   「其他目录…」重新指了根目录里已有的那个）时，列表里不该出现两行
    ///   一模一样的模型，而 `ModelDescriptor.id` 就是 folder，
    ///   `ForEach` 撞 id 会直接渲染异常。
    /// - **不合法的丢掉**，不报错。目录可能已经被搬走/删掉，而这是
    ///   建列表，不是用户刚点了什么——没有上下文的红字比不显示更糟。
    ///   真正的「忘掉它」在 `ImportedModelPreference.revalidate`。
    /// - 排序与 `discover` 完全一致，见 `sortedByPreference`。
    ///
    /// `validate` 注入进来是为了纯函数可测：真实现要碰文件系统。
    nonisolated static func merge(
        discovered: [ModelDescriptor],
        imported: [String],
        validate: (String) -> Result<ModelDescriptor, ModelCatalogError>
    ) -> [ModelDescriptor] {
        var seen = Set(discovered.map(\.folder))
        var all = discovered
        for folder in imported {
            guard !seen.contains(folder) else { continue }
            guard case .success(let descriptor) = validate(folder) else { continue }
            seen.insert(folder)
            all.append(descriptor)
        }
        return sortedByPreference(all)
    }

    /// 这个目录是不是就在模型根目录底下。
    ///
    /// 用途只有一个：根目录里的模型**不必**记进 `ImportedModelPreference`
    /// ——下次启动 `discover` 自己就扫得到，记一份只会让那份偏好越积越长，
    /// 而且每条都要复核一次。
    ///
    /// 比较前给根目录补上尾斜杠：不补的话 `/a/models-old/x` 会被判成
    /// 在 `/a/models` 底下。
    nonisolated static func isUnder(folder: String, root: String) -> Bool {
        guard !root.isEmpty, !folder.isEmpty else { return false }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return folder.hasPrefix(prefix)
    }

    /// 一个模型都没有时占在「当前模型」那一格上的描述符。
    ///
    /// **`folder` 必须是空字符串**，`AppModel.makeTranscriber` 靠它认出
    /// 「没有模型」并给出 `MissingModelTranscriber`。名字写成人话是因为
    /// 它会原样显示在面板的「模型」那一行上；原先这里放的是
    /// `openai_whisper-base`，于是面板显示着一个盘上根本不存在的模型名，
    /// 按下去还会去下载它（见 `MissingModelTranscriber` 的注释）。
    static let noModel = ModelDescriptor(name: "（还没有模型）", folder: "")

    /// **开发期**位置：仓库根目录下的模型目录。
    ///
    /// `.app` 位于 `<仓库>/dist/` 下，因此上溯两级。这条路径只在开发机上
    /// 存在——分发装进 `/Applications` 后，谁在用这个位置都找不到模型，
    /// 实际去处见 `resolveRoot(appSupport:developmentRoot:exists:)`。
    static func defaultRoot(appBundleURL: URL) -> String {
        appBundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("vendor/models")
            .path
    }

    /// 应用支持目录下的模型位置。
    ///
    /// **与 `WhisperKitTranscriber.defaultDownloadBase()` 必须是同一个地方**
    /// ——那边是「下载到哪」，这边是「去哪找」，对不上就会下完还说找不到。
    nonisolated static func applicationSupportRoot(home: String) -> String {
        (home as NSString)
            .appendingPathComponent("Library/Application Support/vInput/huggingface")
    }

    /// 模型根目录的查找顺序：**开发目录优先，其次应用支持目录**。
    ///
    /// 判据就是「那个目录在不在」，不需要环境变量或构建配置来区分开发与分发：
    /// - 分发版那台机器上 `vendor/models` 不存在 → 走应用支持目录；
    /// - 开发机上它存在（4.5GB，重下不现实）→ 继续用它。
    ///
    /// 两个都不在时返回应用支持目录：那是**将要下载到**的地方，返回 nil 会让
    /// 调用方误判成「没救了」，而实际只是还没下载。
    nonisolated static func resolveRoot(
        appSupport: String,
        developmentRoot: String,
        exists: (String) -> Bool
    ) -> String {
        if exists(developmentRoot) { return developmentRoot }
        return appSupport
    }
}
