import Foundation

/// 翻译相关的用户偏好。
///
/// 注入 `UserDefaults` 而非直接用 `.standard`：测试需要互不干扰的独立
/// 存储，否则测试之间会互相污染（与 `CorrectionPreference` 同款）。
///
/// ## 两个开关是正交的
///
/// `choice` 管「要不要翻译」，`usesCloudBackend` 管「翻译时用本地
/// 还是云端」。**判断顺序永远是先语言、后后端**，理由与守卫见
/// `AppModel.translationAttachment`：用户可能为某次需要打开过云端然后忘了
/// 关，而只要输出语言是中文就一个字节都不该出站。
///
/// 键名统一带 `translation.` 前缀也是为了这件事：云端开关**只管翻译**，
/// 转写（Whisper）与校正（本地 MLX）永远在本机，不受它影响。
struct TranslationPreference {
    private enum Key {
        static let choice = "translation.choice"
        /// 原 `outputLanguage` 键名改任此职，只为迁移保留。
        static let legacyOutputLanguage = "translation.outputLanguage"
        static let usesCloudBackend = "translation.usesCloudBackend"
        static let modelDirectory = "translation.modelDirectory"
        static let cloudModel = "translation.cloudModel"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 翻译目标。默认「不翻译」——理由与旧 outputLanguage 默认中文相同：
    /// 翻译要多加载一个 2 GB 级模型，用户没主动选之前不该承担。
    ///
    /// 存的是 `TranslationChoice.storageValue`（稳定字符串而不是枚举序号），
    /// 认不出的值退回「不翻译」——两条理由都写在 `TranslationChoice` 上。
    var choice: TranslationChoice {
        get {
            guard let raw = defaults.string(forKey: Key.choice) else { return .off }
            return TranslationChoice(storageValue: raw)
        }
        nonmutating set { defaults.set(newValue.storageValue, forKey: Key.choice) }
    }

    /// 一次性迁移旧键。**旧键的 "zh" 含义是「不翻译」**，不能直译成
    /// 「译成中文」——否则老用户升级后一开口就被翻译。返回是否真的迁移了
    /// （调用方据此记日志）。新键已存在时不动任何东西。
    func migrateLegacyOutputLanguageIfNeeded() -> Bool {
        guard defaults.string(forKey: Key.choice) == nil,
            let legacy = defaults.string(forKey: Key.legacyOutputLanguage)
        else { return false }
        let migrated: TranslationChoice =
            legacy == Language.chinese.rawValue
            ? .off
            : TranslationChoice(storageValue: legacy)
        defaults.set(migrated.storageValue, forKey: Key.choice)
        return true
    }

    /// 是否使用云端后端翻译。**默认关闭。**
    ///
    /// 默认关闭的理由和校正不同：这里不是成本，是出站。本工具把文字直接注进
    /// 用户即将发出的窗口，默认值必须是「什么都不出去」。
    ///
    /// 本轮（Task 9）只有本地后端；云端实现是 Task 13。
    var usesCloudBackend: Bool {
        get { defaults.bool(forKey: Key.usesCloudBackend) }
        nonmutating set { defaults.set(newValue, forKey: Key.usesCloudBackend) }
    }

    /// 本地翻译模型目录。
    ///
    /// 为 nil 时**退回校正层的模型目录**，见 `AppModel.translationAttachment`
    /// ——今天两层用的就是同一个模型（M8 第 0 步实测定的
    /// `qwen3-4b-instruct-2507-4bit`），而这个退回正是
    /// `ModelContainerRegistry` 能省下一份权重的前提：同一个目录 → 同一个键
    /// → 同一份权重。
    /// 云端用哪个模型。
    ///
    /// 存标识符字符串而不是枚举序号，理由与 `choice` 相同：
    /// 这张表迟早会变（Google 改名、下线），而用户存下来的选择不该因此
    /// 指到别的模型上。认不出的值当自定义处理，**不静默退回默认**。
    var cloudModel: CloudTranslationModel {
        get { CloudTranslationModel.from(identifier: defaults.string(forKey: Key.cloudModel) ?? "") }
        nonmutating set { defaults.set(newValue.identifier, forKey: Key.cloudModel) }
    }

    var modelDirectory: URL? {
        get { defaults.url(forKey: Key.modelDirectory) }
        nonmutating set { defaults.set(newValue, forKey: Key.modelDirectory) }
    }
}
