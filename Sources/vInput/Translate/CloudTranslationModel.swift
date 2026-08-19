import Foundation

/// 云端翻译可选的模型。
///
/// # 这张表里没有一个是验证过的
///
/// 截至 2026-08-19，vInput **一次真实的 Gemini 请求都没发过**——用户尚未
/// 提供 API key，`GeminiTranslator` 的全部测试都用假的网络会话验请求形状。
/// 所以：
///
/// - **模型标识符只对着文档写**，Google 改名或下线时这里不会有任何东西报警；
/// - **译文质量、耗时、价格一概没有实测支撑**。本机那三个数
///   （英文术语保留 1.00 / 西语 0.92 / 德语 0.89）是本机模型的，
///   **不许拿来替云端说话**。
///
/// 因此每一项都带 `note` 说明它是什么档位，而**不带任何质量数字**——
/// 编一个「大概更好」的数比不给数更糟。真要给数，得先跑
/// `./scripts/gemini-e2e.sh`。
///
/// 允许自定义标识符（`custom`）正是因为上面这条：这张表迟早过时，
/// 而用户不该为此等一次发版。
enum CloudTranslationModel: Equatable, Sendable {
    /// 表里预置的一项。
    case known(KnownModel)
    /// 用户自己填的标识符。
    case custom(String)

    enum KnownModel: String, CaseIterable, Sendable {
        case flash2 = "gemini-2.0-flash"
        case flash25 = "gemini-2.5-flash"
        case pro25 = "gemini-2.5-pro"

        /// 这一项是什么档位。**刻意不含任何质量或速度的数字。**
        var note: String {
            switch self {
            case .flash2: "默认，轻量"
            case .flash25: "较新的轻量档"
            case .pro25: "更大的档位"
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
        guard !trimmed.isEmpty else { return .known(.flash2) }
        if let known = KnownModel(rawValue: trimmed) { return .known(known) }
        return .custom(trimmed)
    }

    /// 默认值。第 0 步没有测过云端，这个选择的唯一依据是「它是轻量档、
    /// 最可能便宜且够用」——**是个假设，不是结论**。
    static let `default` = CloudTranslationModel.known(.flash2)
}
