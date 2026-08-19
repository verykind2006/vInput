import Foundation

/// 云端翻译可选的模型。
///
/// # 这张表是实测出来的，而它的前一版全是错的
///
/// 2026-08-19 第一次真发请求之前，这里写的是 `gemini-2.0-flash` /
/// `gemini-2.5-flash` / `gemini-2.5-pro`，照文档抄的。**一发就知道全错**：
///
/// - `gemini-2.0-flash` → `404 NOT_FOUND`，模型不存在
/// - `gemini-2.5-flash` → `404`，且 Google 在错误消息里直接给了替代品：
///   "no longer available to new users. Please update your code to use
///   models/gemini-3.6-flash"
///
/// **教训不是「查文档要仔细」，是「不发一次请求就什么都不知道」。**
/// 这张表迟早会再过时，所以 `custom` 那条路必须留着。
///
/// # 下面的数字全是中国 VPN 下测的，去西班牙要重测
///
/// 用户 2026-09-01 从中国搬到西班牙，在那之前访问 Gemini 靠 VPN。
/// 2026-08-19 的实测：
///
/// | 模型 | 成功 | 均 | 最长 |
/// |---|---|---|---|
/// | `gemini-3.6-flash` | 7/8 | 7.2 秒 | 12.7 秒 |
/// | `gemini-3.5-flash` | 7/8 | 17.3 秒 | **88.2 秒** |
/// | `gemini-3.1-flash-lite` | 3/3 | 1.4 秒 | 1.7 秒 |
///
/// 失败一律是 `400 FAILED_PRECONDITION: User location is not supported`
/// ——Google 按 IP 判的，**与模型无关**。慢也大概率是 VPN 的账。
///
/// **所以：这些数字不是 Gemini 的表现，是「中国 + VPN 下 Gemini 的表现」。**
/// 由它们定下来的东西（云端超时下限、默认模型、以及「云端比本机慢五倍」
/// 这个判断）到西班牙都要重来一遍。
///
/// # 为什么默认不选实测最快的那个
///
/// `gemini-3.1-flash-lite` 实测 1.4 秒，比 `gemini-3.6-flash` 快五倍。
/// 但**样本只有一句话**，而用户的主场景是技术术语与报价——lite 档在
/// 术语保留上会不会掉，一个字都没量过。默认取 Google 自己给的替代品
/// `gemini-3.6-flash`（完整档，非 lite），把 lite 放进列表让用户自己选。
enum CloudTranslationModel: Equatable, Sendable {
    /// 表里预置的一项。
    case known(KnownModel)
    /// 用户自己填的标识符。
    case custom(String)

    /// **每一项都在 2026-08-19 真发过请求、真拿到过译文。**
    /// 没验过的一律不进这张表——上一版全是照文档抄的，一发就知道全错。
    enum KnownModel: String, CaseIterable, Sendable {
        case flash36 = "gemini-3.6-flash"
        case flashLite31 = "gemini-3.1-flash-lite"
        case flash37 = "gemini-3.7-flash"

        /// 这一项是什么档位。**刻意不含任何质量数字。**
        ///
        /// 速度那句是中国 VPN 下量的，所以写成相对说法而不是绝对秒数——
        /// 到西班牙绝对值会变，相对关系大概率还在。
        var note: String {
            switch self {
            case .flash36: "默认，Google 给的替代品"
            case .flashLite31: "轻量档，实测明显更快"
            case .flash37: "更新的一档"
            }
        }
    }

    var identifier: String {
        switch self {
        case .known(let model): model.rawValue
        case .custom(let id): id
        }
    }

    /// 菜单上那一行。
    ///
    /// 自定义项**不带说明**：说明是我们对预置项的描述，
    /// 而用户自己填的那个我们一无所知，附一句话上去就是在编。
    var menuLabel: String {
        switch self {
        case .known(let model): "\(model.rawValue)（\(model.note)）"
        case .custom(let id): id
        }
    }

    /// 从存下来的字符串还原。认不出就当自定义——**不要退回默认值**：
    /// 用户明明填过一个，却被静默换成别的，是最难查的一类问题。
    static func from(identifier: String) -> CloudTranslationModel {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .default }
        if let known = KnownModel(rawValue: trimmed) { return .known(known) }
        return .custom(trimmed)
    }

    /// 默认值。理由见类型注释「为什么默认不选实测最快的那个」。
    static let `default` = CloudTranslationModel.known(.flash36)
}
