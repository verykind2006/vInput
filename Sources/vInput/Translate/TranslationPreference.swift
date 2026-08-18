import Foundation

/// 翻译相关的用户偏好。
///
/// 注入 `UserDefaults` 而非直接用 `.standard`：测试需要互不干扰的独立
/// 存储，否则测试之间会互相污染（与 `CorrectionPreference` 同款）。
///
/// ## 两个开关是正交的
///
/// `outputLanguage` 管「要不要翻译」，`usesCloudBackend` 管「翻译时用本地
/// 还是云端」。**判断顺序永远是先语言、后后端**，理由与守卫见
/// `AppModel.translationAttachment`：用户可能为某次需要打开过云端然后忘了
/// 关，而只要输出语言是中文就一个字节都不该出站。
///
/// 键名统一带 `translation.` 前缀也是为了这件事：云端开关**只管翻译**，
/// 转写（Whisper）与校正（本地 MLX）永远在本机，不受它影响。
struct TranslationPreference {
    private enum Key {
        static let outputLanguage = "translation.outputLanguage"
        static let usesCloudBackend = "translation.usesCloudBackend"
        static let modelDirectory = "translation.modelDirectory"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 输出语言。**默认中文，即不翻译。**
    ///
    /// 翻译要额外加载一个 2 GB 级的模型并给每句话多加几秒推理，用户没主动
    /// 选之前不该承担这些成本——与 `CorrectionPreference.isEnabled` 默认关闭
    /// 同一条理由。
    ///
    /// **存稳定字符串而不是枚举序号**：`TranslationTarget` 的 rawValue 由
    /// `TranslationTargetTests.rawValuesAreStable` 逐个钉死，加一种语言不会
    /// 把用户已保存的设置挪到别的语言上；存序号的话在中间插一格就全错位了。
    ///
    /// 读到不认识的值时退回中文（应用降级回旧版本、或用户手改 plist）。
    /// **退回中文而不是崩掉或退回上一次的外语**：中文是「不翻译」，是唯一
    /// 不会把用户没要的语言注进输入框的取值。这条退回不必额外提示——
    /// 菜单栏当场就显示成「输出语言：中文」，用户看得见。
    var outputLanguage: TranslationTarget {
        get {
            guard let raw = defaults.string(forKey: Key.outputLanguage) else { return .chinese }
            return TranslationTarget(rawValue: raw) ?? .chinese
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.outputLanguage) }
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
    var modelDirectory: URL? {
        get { defaults.url(forKey: Key.modelDirectory) }
        nonmutating set { defaults.set(newValue, forKey: Key.modelDirectory) }
    }
}
