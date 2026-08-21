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

        return models.sorted { lhs, rhs in
            let li = ModelPreference.preferredModels.firstIndex(of: lhs.name) ?? .max
            let ri = ModelPreference.preferredModels.firstIndex(of: rhs.name) ?? .max
            if li != ri { return li < ri }
            return lhs.name < rhs.name
        }
    }

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
