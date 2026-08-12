import Foundation

/// 清除 Whisper 的字幕署名类幻觉。
///
/// Whisper 的训练数据含大量带字幕的视频，因此在静音段或音频结尾
/// 容易凭空生成「( 字幕:XXX )」「Subtitles by the Amara.org community」
/// 之类的署名尾巴。真机验收中实际出现过。
///
/// WhisperKit 未实现 OpenAI 参考实现里默认启用的 `nonSpeechTokens`
/// 抑制（其源码中该处仅有一行 TODO），因此需要在应用侧兜底。
///
/// **设计取向：宁可漏删，不可误删。** 只匹配明确无歧义的字幕署名模式；
/// 「谢谢观看」这类用户可能真的会说的话一律保留。
enum TranscriptCleaner {
    /// 括号内含字幕署名关键词的整段。
    ///
    /// 关键词紧跟在开括号后（允许空白），避免误删
    /// 「（就是那个处理登录的）」这类正常内容。
    private static let bracketedCredit = try! NSRegularExpression(
        pattern: "[（(\\[【]\\s*(字幕|中文字幕|subtitles?|Amara|MultiSub)[^）)\\]】]*[）)\\]】]",
        options: [.caseInsensitive]
    )

    /// 结尾处不带括号的字幕署名，如「… 字幕:王五」。
    /// 必须在末尾且前面有空白，避免误删「视频的字幕文件」。
    private static let trailingCredit = try! NSRegularExpression(
        pattern: "\\s+(字幕|中文字幕|subtitles?)\\s*[:：].*$",
        options: [.caseInsensitive]
    )

    static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = text
        for regex in [bracketedCredit, trailingCredit] {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: ""
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
