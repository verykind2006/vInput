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

    /// 仓库根目录下的默认模型位置。
    ///
    /// `.app` 位于 `<仓库>/dist/` 下，因此上溯两级。正式分发时
    /// 应改为应用支持目录（M6 范围）。
    static func defaultRoot(appBundleURL: URL) -> String {
        appBundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("vendor/models")
            .path
    }
}
