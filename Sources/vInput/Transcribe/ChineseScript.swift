import Foundation

/// 中文字形规范化。
///
/// Whisper 的中文训练数据里繁体占比很高，即便指定 `language: "zh"`
/// 也经常输出繁体（Task 2 实测：「幫我把這個…裏…測試」）。产品需要简体，
/// 因此在转写层出口统一转换一次。
///
/// 使用系统内置的 ICU 音译器，无需任何第三方依赖或词表文件。
/// 它只改字形，不改用词——同音错字（如「函数」被听成「寒暑」）
/// 属于识别错误，由模型选型或 M4 的润色层负责。
enum ChineseScript {
    /// 把文本中的繁体字转成简体。
    ///
    /// 已是简体的字符、拉丁字母、数字与标点均原样保留。
    static func toSimplified(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        // "Hant-Hans"：ICU 的繁体→简体音译器 ID。
        CFStringTransform(mutable as CFMutableString, nil, "Hant-Hans" as CFString, false)
        return mutable as String
    }
}
