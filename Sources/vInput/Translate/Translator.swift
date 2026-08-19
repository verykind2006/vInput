import Foundation

enum TranslatorError: Error, Equatable {
    /// 模型尚未加载。
    case modelNotReady
    /// 底层引擎报错。
    case engineFailed(String)
    /// 推理超时。
    case timedOut
    /// 云端后端选中了但没配 API key。
    ///
    /// 比 `CorrectorError` 多出来的一格：校正只有本地实现，翻译一开始就
    /// 规划了云端后端（GeminiTranslator），缺 key 是配置问题不是引擎故障，
    /// 提示用户的话术完全不同，所以单列。
    case missingAPIKey
    /// 云端拒绝服务，理由是**调用方所在的地理位置不支持**。
    ///
    /// **单列而不是并进 `engineFailed`**：这一条用户有明确的动作可做
    /// （换网络位置 / 开 VPN / 改用本机），而 `engineFailed` 那格的措辞是
    /// 「翻译失败」——它会让用户去重说一遍，而重说一百遍也没用。
    ///
    /// 2026-08-19 实测，中国 + VPN 下约 **1/8** 的请求撞上它，
    /// 报文是 `400 FAILED_PRECONDITION: User location is not supported
    /// for the API use.`（只取 gRPC 状态名，不取 message——见
    /// `GeminiTranslator` 里那段关于回显用户内容的注释）。
    case locationNotSupported
}

/// 把中文转写译成目标语言。
///
/// **实现只负责产出译文，不负责判断译文是否可用**——那是
/// `TranslationGate` 的职责，且它位于本 protocol 之外，
/// 任何实现（本地、云端）共用同一道闸门。与 `Corrector` 同一个分工。
protocol Translator: Sendable {
    /// 是否已经能立刻推理。
    ///
    /// **调用方据此决定「这次干脆不翻译」，而不是等模型加载完。**
    /// 加载一次本地模型要几十秒，谁都不该在注入路径上等它。
    /// 读这个值本身也必须是立刻返回的，实现里不许顺手去加载。
    var isReady: Bool { get async }

    /// 确保模型已加载。可重复调用，已就绪时立即返回。
    ///
    /// 会一直等到加载完成，**只应在后台预热时调用**，不要放在注入路径上。
    func prepare() async throws

    /// 把 `text` 译成 `target`。
    ///
    /// 未就绪时应立即抛 `.modelNotReady`，而不是就地加载模型——
    /// 同上，注入路径不等加载。
    func translate(_ text: String, to target: TranslationTarget) async throws -> String
}

extension Translator {
    /// 默认视为就绪：不需要加载模型的实现（云端、测试替身）天然就绪，
    /// 只有本地模型这类有加载成本的实现才必须覆盖。
    var isReady: Bool { get async { true } }
}
