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
    private static let trailingFiller = try! NSRegularExpression(
        pattern: "\\s*[，,]?\\s*(谢谢大家观看|谢谢大家收看|谢谢观看|感谢观看|谢谢收看|谢谢大家|谢谢您的观看)[。.！!\\s]*$",
        options: []
    )

    /// 结尾处的「求点赞订阅打赏」频道套话。
    ///
    /// 与上面那条分开，因为**按字面列举这一类是列不完的**。它此前写在
    /// `trailingFiller` 里，形如 `请不吝点赞\s*订阅[^。]*`，被两种真实形态
    /// 先后击穿：
    ///
    /// - `请不吝点赞 讨订阅 转发 打赏支持明镜与点点栏目`
    ///   ——ASR 在中间多听出一个「讨」，`\s*` 吃不掉它；
    /// - `用转发 打赏支持明镜与点点栏目。`
    ///   ——开头压根不是「请不吝点赞」。
    ///
    /// 同一句套话每次转写出来都不完全一样，继续往字面清单里加只会被下一个
    /// 错字再击穿一次。改为**锚在最独特的词上**，整句连坐：
    ///
    /// - 「不吝」——口语里几乎只出现在这句套话中；
    /// - 「打赏支持」——同上，且是两种已知形态的公共部分。
    ///
    /// **不用正则做这一条。** 先试过
    /// `[^。.！!？?]*(不吝|打赏支持)[^。.！!？?]*$`，它会把
    /// 「我准备打赏支持一下他，然后再看看后面的更新怎么样。」整句吃掉——
    /// 字符类里没排除逗号，`stringByReplacingMatches` 又取最左最长匹配，
    /// 于是从句首一路咬到句尾。要在正则里同时表达「末句」「多个促销词」
    /// 两个条件，写出来没人看得懂，也不好测。
    ///
    /// 改成：**取末句，数促销词，两个及以上才删。**
    /// 真实幻觉整句都是促销词堆砌，命中五六个；用户真话最多蹭到一个。
    private static let promoTokens = [
        "不吝", "点赞", "订阅", "转发", "打赏", "栏目", "关注",
    ]

    /// 末句里促销词达到这个数量就整句删掉。
    ///
    /// 2 是权衡出来的：已知的两种真实形态分别命中 6 个和 3 个，
    /// 而用户真话（「我准备打赏支持一下」「记得帮我点赞」）只命中 1 个。
    /// 定成 1 会把后者一起误伤，定成 3 则挡不住更短的变形。
    private static let promoTokenThreshold = 2

    /// 剥掉结尾处的「求点赞订阅打赏」频道套话。
    ///
    /// 与 `trailingFiller` 分开，因为**按字面列举这一类是列不完的**。
    /// 它此前写在那条规则里，形如 `请不吝点赞\s*订阅[^。]*`，被两种真实形态
    /// 先后击穿：
    ///
    /// - `请不吝点赞 讨订阅 转发 打赏支持明镜与点点栏目`
    ///   ——ASR 在中间多听出一个「讨」，`\s*` 吃不掉它；
    /// - `用转发 打赏支持明镜与点点栏目。`
    ///   ——开头压根不是「请不吝点赞」。
    ///
    /// 同一句套话每次转写出来都不一样，继续往字面清单里加只会被下一个错字
    /// 再击穿一次。
    ///
    /// M6 之后这条更要紧了：独立验收实测，VAD 分块本身在超 30 秒底噪上压着
    /// 这类幻觉（只差分块开关的两个变体，`noise45` 分别是 0/4 与 4/4，
    /// 完全翻转），而 M6 把分块关掉了，**上游那道防线没有了**。
    static func strippingChannelPromo(_ text: String) -> String {
        let terminators = CharacterSet(charactersIn: "。.！!？?")
        // 末句 = 最后一个句末标点之后的部分。整段没有句末标点时，整段就是末句。
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let body = trimmed.hasSuffix("。") || trimmed.hasSuffix(".")
            || trimmed.hasSuffix("！") || trimmed.hasSuffix("!")
            || trimmed.hasSuffix("？") || trimmed.hasSuffix("?")
            ? String(trimmed.dropLast())
            : trimmed

        let lastBreak = body.rangeOfCharacter(from: terminators, options: .backwards)
        let sentenceStart = lastBreak.map { body.index(after: $0.lowerBound) } ?? body.startIndex
        let lastSentence = String(body[sentenceStart...])

        let hits = promoTokens.filter { lastSentence.contains($0) }.count
        guard hits >= promoTokenThreshold else { return text }

        return String(body[..<sentenceStart])
    }

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
        // 排在 trailingFiller 之后：套话末尾常跟着「谢谢观看」，
        // 先剥掉后者，末句才是促销词那一句。
        result = strippingChannelPromo(result)
        result = normalizePunctuation(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把中文语境里的半角标点转成全角。
    ///
    /// 说中文时 Whisper 输出的是半角 `,`，句号却是全角 `。`——同一句话里
    /// 两种宽度混着（2026-08-17 用户报告）。问号同样：用户日志里那句
    /// `把 M8 的分场景优化改成?` 就是句号全角、问号半角。
    ///
    /// **不能靠改 prompt 修，那条路实测会炸。**
    /// `WhisperKitTranscriber.swift:164` 记着：全角「，」是 UTF-8 三字节
    /// （EF BC 8C），用全角的 prompt 候选在 24 秒的 long.wav 上**稳定复现**
    /// 同前缀字节级乱码（`Ｂ` EF BC A2、`４` EF BC 94），换成半角后 90 次
    /// 转写零乱码。Whisper 跟着 prompt 的习惯走，输出也就成了半角。
    /// 所以只能在转写之后做字符替换。
    ///
    /// **难点是中英混排。** 判据在 `ChineseScript.fullWidthConversions`，
    /// 与 `CorrectionGate.joiningLatinWords` 同一种做法：在原始字符串上看
    /// 邻居，不做整段语言判定——整段判定在
    /// `他说 "Hello, world" 然后走了` 上必然出错。
    ///
    /// 这条规则同时挡住了最贵的那个误伤：千分位 `1,200,000` 两侧都是数字，
    /// 数字不算中文语境，一个字都不会动。
    ///
    /// **范围**（2026-08-17 用户把它从「只有逗号」扩成「中文语境下的标点
    /// 全部全角」）：`, ? ! : ;` 加上成对的 `( )`，**不含句号**。
    /// 判据、范围与「为什么不含句号」都记在
    /// `ChineseScript.fullWidthConversions` 与 `normalizedHalfWidth` 上，
    /// 因为度量要用同一份。
    static func normalizePunctuation(_ text: String) -> String {
        guard text.contains(where: { ChineseScript.normalizedHalfWidth.contains($0) })
        else { return text }

        let characters = Array(text)
        let conversions = ChineseScript.fullWidthConversions(in: characters)
            .filter { ChineseScript.normalizedHalfWidth.contains(characters[$0.key]) }
        guard !conversions.isEmpty else { return text }

        var result: [Character] = []
        result.reserveCapacity(characters.count)

        var index = 0
        while index < characters.count {
            guard let fullWidth = conversions[index] else {
                result.append(characters[index])
                index += 1
                continue
            }

            // 转换时连带吃掉紧邻的空白：全角标点本身就占一个全宽位，
            // 再留一个空格会出现双倍间距，而中文排版里标点紧跟前一个字。
            //
            // **换行不吃**：它是内容边界，吃掉会把两行并成一行；而判定时
            // 又必须跳过它（`。\n(中文)` 的括号确实在中文语境里），
            // 所以「跳过」与「吃掉」的范围不同。
            while let last = result.last, last.isWhitespace, !last.isNewline {
                result.removeLast()
            }
            result.append(fullWidth)
            index += 1
            while index < characters.count,
                  characters[index].isWhitespace, !characters[index].isNewline {
                index += 1
            }
        }
        return String(result)
    }
}
