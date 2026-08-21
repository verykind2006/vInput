import Foundation

/// 下载源偏好：用户在面板「高级 → 下载源」里选的那一档。
///
/// ## 这个类型存在的唯一理由是「写的人和读的人用同一个 key」
///
/// 面板写、向导读，中间隔着两个文件。两边各写一次 `"download.forcedSource"`
/// 字面量的话，拼错一个字母的表现是**这个设置什么都不做**——用户点了「强制
/// 国内镜像」，下一次下载照样并发探测，而界面上打着勾。没有任何编译错误、
/// 没有任何测试会红。
///
/// 所以 key 只写在下面那一处，任何一侧都必须经由本类型；
/// `DownloadSourceKeyTests` 扫整个 `Sources/` 钉住「这个字面量全仓只有一处」。
///
/// 注入 `UserDefaults` 而非直接用 `.standard`，理由同 `CorrectionPreference`：
/// 测试要互不干扰的独立存储。
struct DownloadSourcePreference {
    /// **全仓唯一的一处。** 别在别处再写一遍这个字符串。
    static let forcedKey = "download.forcedSource"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 强制使用哪个源。**nil 表示「自动」**（并发探测、谁快用谁），也是默认值。
    ///
    /// 默认自动是有意的：用户现在在国内、9 月到西班牙，写死任何一个源都会在
    /// 半年内变成错的那个（见 `DownloadSource.choose` 的注释）。这个设置是给
    /// 「探测选错了」准备的逃生口，不是日常开关，所以它在「高级」里。
    ///
    /// 存的是 `rawValue` 字符串而不是 `Int`：将来加第三个源时，序号会错位，
    /// 而字符串不会。读不出合法值（手改过 plist、旧版本残留）时退回 nil ——
    /// 失败方向是「自动」，而自动在任何网络下都能工作。
    var forced: DownloadSource? {
        get {
            guard let raw = defaults.string(forKey: Self.forcedKey) else { return nil }
            return DownloadSource(rawValue: raw)
        }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: Self.forcedKey)
                return
            }
            defaults.set(newValue.rawValue, forKey: Self.forcedKey)
        }
    }
}
