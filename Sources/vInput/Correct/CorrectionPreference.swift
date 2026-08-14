import Foundation

/// 校正相关的用户偏好。
///
/// 注入 `UserDefaults` 而非直接用 `.standard`：测试需要互不干扰的独立
/// 存储，否则测试之间会互相污染。
struct CorrectionPreference {
    private enum Key {
        static let enabled = "correction.enabled"
        static let modelDirectory = "correction.modelDirectory"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 是否启用校正。**默认关闭**——校正需要额外下载一个 2 GB 级的模型
    /// 并带来额外延迟，用户没主动开启前不该承担这些成本。
    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// 本地模型目录。为 nil 时 `MLXCorrector` 按标识符下载。
    var modelDirectory: URL? {
        get { defaults.url(forKey: Key.modelDirectory) }
        nonmutating set { defaults.set(newValue, forKey: Key.modelDirectory) }
    }
}
