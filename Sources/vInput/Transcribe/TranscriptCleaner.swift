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
    /// Whisper 的原始特殊标记：`<|zh|>`、`<|0.00|>`、`<|endoftext|>` 等。
    ///
    /// 只匹配 `<|…|>` 这一形式，用户真说的 `<div>` 不受影响。
    private static let specialToken = try! NSRegularExpression(
        pattern: "<\\|[^|]*\\|>",
        options: []
    )

    /// 剥除特殊标记。
    ///
    /// **两条路径都需要它。** `TranscriptionResult.text` 是处理过的，
    /// 而 `segment.text` 是原始的——预览一直读 segments，最终转写在改用
    /// 分段过滤后也开始读 segments，两处都会漏出标记。真机上两次都出现过。
    static func stripSpecialTokens(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return specialToken.stringByReplacingMatches(
            in: text, options: [], range: range, withTemplate: ""
        )
    }

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

    /// 结尾处的套话式幻觉。
    ///
    /// 这些是 Whisper 中文训练数据（大量带字幕视频）的高频尾巴，在静音段
    /// 尤其容易凭空生成。真机验收中「谢谢观看」反复出现。
    ///
    /// **这里推翻了此前的判断。** 最初认为「用户可能真的会说谢谢观看」而
    /// 不予过滤，实际使用下来它作为幻觉出现的频率远高于用户真说的频率。
    /// 折中：只删**位于结尾**且**独立成句**的这几句，句中出现一律保留——
    /// 「今天就讲到这里，谢谢观看大家的支持」不会被误伤。
    /// 只吞掉幻觉前的空白与逗号，**保留句末标点**——
    /// 「今天下午三点开会。谢谢观看」应还原成「今天下午三点开会。」，
    /// 把句号一起删掉是过度清理。
    /// 短语列表按「长的在前」排列，避免「谢谢大家观看」先被「谢谢大家」
    /// 截掉一半而留下「观看」。
    ///
    /// **「谢谢大家」比「谢谢观看」更可能是真话**（微信消息里完全可能这么
    /// 收尾）。之所以仍然收进来，是因为它作为幻觉出现的频率在真机使用中
    /// 明显更高。
    ///
    /// **订正：此处原先写着「主防线是分段级的无语音概率过滤」，那句是错的。**
    /// 实测（large-v3-turbo，bench 的 9 段静音/底噪各 4 次）产出的 18 条
    /// 幻觉分段，`noSpeechProb` 全部是 0.0000——
    /// `WhisperKitTranscriber.textDroppingTrailingNonSpeech` 在这个模型上
    /// 从来不会触发。真正在拦幻觉的是同文件里的
    /// `segmentsDroppingFallbackFiller`（温度大于 0 且整段恰是套话），
    /// 而那一条已实测会误伤嘈杂环境下用户真说的「谢谢」。
    /// 所以这里不是「兜底的兜底」，是**并列的第二道**，且两道都会误删。
    /// 若日后发现误删，先放宽的应是这一条——它只按字面匹配，最容易判断。
    ///
    /// 「点赞」与「订阅」之间必须允许空白。模型实际吐出来的是
    /// 「请不吝点赞 订阅 转发 打赏支持明镜与点点栏目」——中间带空格，
    /// 而此前模式写死了「点赞订阅」相连，于是这一条**从来没有生效过**：
    /// bench 的静音音频上 35 次转写里漏出去 2 次，一字未删。
    private static let trailingFiller = try! NSRegularExpression(
        pattern: "\\s*[，,]?\\s*(谢谢大家观看|谢谢大家收看|请不吝点赞\\s*订阅[^。]*|谢谢观看|感谢观看|谢谢收看|谢谢大家|谢谢您的观看)[。.！!\\s]*$",
        options: []
    )

    static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // 必须先剥标记。否则文本以 <|endoftext|> 结尾，下面几条
        // 「结尾处」的规则一条都匹配不上——真机上就是这样两道防线一起失效。
        var result = stripSpecialTokens(text)

        for regex in [bracketedCredit, trailingCredit, trailingFiller] {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: ""
            )
        }
        result = normalizeCommas(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把中文语境里的半角逗号转成全角。
    ///
    /// 说中文时 Whisper 输出的是半角 `,`，句号却是全角 `。`——同一句话里
    /// 两种宽度混着（2026-08-17 用户报告）。
    ///
    /// **不能靠改 prompt 修，那条路实测会炸。**
    /// `WhisperKitTranscriber.swift:164` 记着：全角「，」是 UTF-8 三字节
    /// （EF BC 8C），用全角的 prompt 候选在 24 秒的 long.wav 上**稳定复现**
    /// 同前缀字节级乱码（`Ｂ` EF BC A2、`４` EF BC 94），换成半角后 90 次
    /// 转写零乱码。Whisper 跟着 prompt 的习惯走，输出也就成了半角。
    /// 所以只能在转写之后做字符替换。
    ///
    /// **难点是中英混排。** 判据取「离逗号最近的那个实字符是不是中文语境」，
    /// 与 `CorrectionGate.joiningLatinWords` 同一种做法：在原始字符串上看
    /// 邻居，不做整段语言判定——整段判定在
    /// `他说 "Hello, world" 然后走了` 上必然出错。
    ///
    /// 这条规则同时挡住了最贵的那个误伤：千分位 `1,200,000` 两侧都是数字，
    /// 数字不算中文语境，一个字都不会动。
    ///
    /// **范围只有逗号**（2026-08-17 已定）。半角问号同样会出现（Roadmap 里
    /// session 103 的日志就是「改成?」），但那不在本轮定下的范围里；
    /// `BenchMetrics.halfWidthPunctuationInChinese` 会把它数出来，
    /// 要不要一起改由用户再定。
    static func normalizeCommas(_ text: String) -> String {
        guard text.contains(",") else { return text }
        guard let fullWidth = ChineseScript.fullWidthPunctuation[","] else { return text }

        let characters = Array(text)
        var result: [Character] = []
        result.reserveCapacity(characters.count)

        var index = 0
        while index < characters.count {
            guard characters[index] == "," else {
                result.append(characters[index])
                index += 1
                continue
            }

            // 往两边跳过空白再看：「这个逗号属于中文还是英文」看的是词，
            // 不是词与逗号之间有没有空格。
            var previous = result.count - 1
            while previous >= 0, result[previous].isWhitespace { previous -= 1 }
            var next = index + 1
            while next < characters.count, characters[next].isWhitespace { next += 1 }

            let before = previous >= 0 ? result[previous] : nil
            let after = next < characters.count ? characters[next] : nil

            guard ChineseScript.isChineseContext(before)
                || ChineseScript.isChineseContext(after) else {
                result.append(characters[index])
                index += 1
                continue
            }

            // 转换时连带吃掉紧邻的空白：全角逗号本身就占一个全宽位，
            // 再留一个空格会出现双倍间距，而中文排版里标点紧跟前一个字。
            result.removeLast(result.count - 1 - previous)
            result.append(fullWidth)
            index = next
        }
        return String(result)
    }
}
