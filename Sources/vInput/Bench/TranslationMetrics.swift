import Foundation

/// 翻译质量的机械度量。
///
/// **全部只做机器可判的检查，不碰语义正确性。** 判断「译得对不对」需要
/// 另一个模型，而「用更强的模型检查更强的模型」是无穷回退。这里只回答
/// 「有没有明显没译干净」，与 `CorrectionGate` 同一个定位。
///
/// 素材复用 M5 基准集的 23 条真人录音：标准文本已知，所以下面每一项都能
/// 无人值守地算出来。
///
/// **度量点在闸门之前。** 后面的 `TranslationGate` 会用同一批判据
/// （残留汉字、中文标点），但它跑在注入路径上、会把不合格的译文换成中文
/// 原文；度量必须看**未经过滤的原始译文**，否则指标读的是过滤后的结果。
/// M6 在这上面栽过：`BenchMetrics.halfWidthPunctuationInChinese` 与转换器
/// 共用同一个函数又跑在转换之后，成了恒等式，26 条基准集全读 0——
/// 那不是测量结果，是定义。
enum TranslationMetrics {
    /// CJK 统一表意文字基本区。扩展区在听写场景里见不到，
    /// 漏掉它们只会让这个指标更保守，不会误报。
    ///
    /// **下面的「单 scalar」守卫没有测试覆盖**，别以为查过了：变异验证时
    /// 把它去掉，10 条用例全绿。要触发它得用组合字符或 emoji，而听写译文里
    /// 见不到。刻意不补——`BenchMetrics.halfWidthPunctuationInChinese` 里
    /// 同一个守卫也是这个状态，单独给这一处补测试只会造成不一致的严格度。
    private static func isHan(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let scalar = c.unicodeScalars.first else {
            return false
        }
        return (0x4E00...0x9FFF).contains(scalar.value)
    }

    private static let chinesePunctuation: Set<Character> = [
        "，", "。", "？", "！", "：", "；", "、", "（", "）", "「", "」", "《", "》",
    ]

    /// 译文里残留的汉字个数。**应为 0。** 这是最硬的一条：
    /// 拉丁字母译文里出现汉字，只可能是没译完或者退回了中文。
    static func residualHanCount(_ text: String) -> Int {
        text.filter(isHan).count
    }

    /// 译文里残留的中文标点个数。与残留汉字分开数——
    /// 「英文句子配全角逗号」和「整段没译」是两种不同的失败形态，
    /// 混在一起会看不出是哪种。
    static func residualChinesePunctuationCount(_ text: String) -> Int {
        text.filter { chinesePunctuation.contains($0) }.count
    }

    /// 原文里的技术术语有多少在译文里原样出现。
    ///
    /// 术语用 `BenchMetrics.technicalTerms` 抽而不是手写清单——
    /// 标准文本改了词表自动跟着改，不会漏（M5 的做法）。
    ///
    /// 原文没有术语时返回 1.0：「没有术语可丢」不该被算成「术语全丢了」，
    /// 否则口语类样本会把平均值拖垮。
    static func termPreservationRate(source: String, translation: String) -> Double {
        let terms = BenchMetrics.technicalTerms(in: source)
        guard !terms.isEmpty else { return 1.0 }
        return BenchMetrics.termHitRate(terms: terms, in: translation)
    }

    /// 术语保留率，**忽略大小写**。
    ///
    /// # 为什么翻译这一层需要这个，而校正那一层不需要
    ///
    /// `BenchMetrics.termHitRate` 严格比大小写，那是给**校正层**定的：
    /// 中文语音转写里 `GitHub Actions` 被写成 `github actions` 是真实的
    /// 失败形态（M4 实测），大小写丢了就是丢了。
    ///
    /// **翻译这一层不一样：大小写是目标语言的正字法。**
    /// 2026-08-19 六语对照实测，德语在严格判据下只有 0.84、六种里最差——
    /// 逐条看下来**一个术语都没真丢**：
    ///
    /// | 原文 | 德语译文 |
    /// |---|---|
    /// | `token` | `Token` |
    /// | `refresh` | `Refresh-Endpoint` |
    /// | `store` | `Zustand-Store` |
    /// | `selector` | `Selector` |
    ///
    /// **德语所有名词首字母大写，那是正确的德语。** 而同一轮里西语葡语是
    /// 真把 `refresh` 译成了 `actualización`、把 `store` 译成了 `almacén`
    /// ——那才是丢失。严格判据把这两件事记成同一件，**于是菜单上给用户看的
    /// 语种等级是反的**。
    ///
    /// # 两个都要报，不要只留一个
    ///
    /// 严格的那个回答「术语逐字保留了吗」，宽松的这个回答「术语活下来了吗」。
    /// 只留宽松的会漏掉「`useMemo` 被写成 `usememo`」这类真问题——那在代码
    /// 标识符上是致命的（用户会把译文里的标识符复制走）。**两个数并排看，
    /// 差值就是「只差大小写」的那部分。**
    static func termPreservationRateIgnoringCase(source: String, translation: String) -> Double {
        let terms = BenchMetrics.technicalTerms(in: source)
        guard !terms.isEmpty else { return 1.0 }
        let haystack = translation.lowercased()
        let hits = terms.filter { haystack.contains($0.lowercased()) }.count
        return Double(hits) / Double(terms.count)
    }

    /// 文本里出现的阿拉伯数字串，按出现顺序。
    ///
    /// **判据是 ASCII 的 0–9，不能用 `Character.isNumber`。** 后者对
    /// 「三」「两」「百」「十」「零」「①」「Ⅲ」全部返回 true（Swift 标准库
    /// 的文档里就把「三」列为 number），于是 `lostDigits` 会把每一个中文
    /// 数字都当成「原文里的阿拉伯数字」，而译文里它们理应变成
    /// `three`/`two` 这样的英文词、永远匹配不上——**每一条都记成丢失**。
    ///
    /// 2026-08-18 Task 4 实测：qwen2.5-7b × 英文 × 26 条标准文本，
    /// 用 `isNumber` 版本跑出来的汇总是「数字丢失 17 / 原文共 17 个」，
    /// 逐条标记全是 `丢数字一`、`丢数字三,一,二,三,一` 这样的中文数字，
    /// 而这 26 条里**一个 ASCII 数字都没有**（`grep -c '[0-9]'` 为 0）。
    /// 也就是说那一列 100% 是假阳性，而它看起来像「模型把数字全译丢了」——
    /// 一个看着很像真的数。改判据后同一批素材的分母回到 0，
    /// 报告会如实写「分母为 0，这一列读不出任何东西」。
    ///
    /// 中文数字译成 `three` 是**正确行为**，本来就不该由这条指标管；
    /// 要考数字必须给带 ASCII 数字的素材（`Bench/translate-digits.json`）。
    static func digitsIn(_ text: String) -> [String] {
        text.split(whereSeparator: { !($0.isASCII && $0.isNumber) })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// 原文里有、译文里没有的阿拉伯数字。
    ///
    /// **数字译错是报价场景最贵的错**，而它恰好是可机器检的少数几件事之一。
    /// 只查原文已经是阿拉伯数字的那些——中文数字（「五百」）译成 `500`
    /// 是正确行为，不该被算成不一致。
    ///
    /// **带中文数量单位的混写数字不归这条管**：「128万」的正确译文是
    /// `1.28 million`，里面既没有 `128` 也没有 `万`——要求 128 原样出现
    /// 就是把正确译文记成丢失。这一类（数字串紧邻 万/亿/千/百，
    /// 或紧跟在 万/亿 之后的简写尾数「3万5」的 5）由 `lostNumerals`
    /// 按**数值**比对，见 `ChineseNumerals`。
    static func lostDigits(source: String, translation: String) -> [String] {
        let inTranslation = Set(digitsIn(translation))
        return copyableDigits(in: source).filter { !inTranslation.contains($0) }
    }

    /// 原文里「译文应当原样保留」的阿拉伯数字串。
    /// `digitsIn` 减去与中文数量单位粘着的那些（理由见 `lostDigits`）。
    /// 排除时把小数一起排掉：「4.5亿」整个属于数值比对，
    /// 不能把 `4` 留下来当成一个要原样保留的数。
    static func copyableDigits(in text: String) -> [String] {
        var out: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i].isASCII, chars[i].isNumber else {
                i += 1
                continue
            }
            // 整个 ASCII 数字串（内部小数点两侧都是数字时含小数点）
            var j = i
            while j < chars.count {
                if chars[j].isASCII, chars[j].isNumber { j += 1; continue }
                if chars[j] == ".", j + 1 < chars.count, chars[j + 1].isASCII,
                    chars[j + 1].isNumber, j > i
                { j += 1; continue }
                break
            }
            let followedByUnit = j < chars.count && "万亿千百".contains(chars[j])
            let precededByUnit = i > 0 && "万亿".contains(chars[i - 1])
            if !followedByUnit && !precededByUnit {
                // 按 `digitsIn` 的粒度切开（小数点两侧各算一段），
                // 译文那一侧仍用 `digitsIn`，两侧粒度必须一致
                out.append(
                    contentsOf: String(chars[i..<j]).split(separator: ".").map(String.init))
            }
            i = j
        }
        return out
    }

    /// 原文里该报告的中文数词（≥1000 或百分比），作为 `lostNumerals` 的分母。
    static func numeralsIn(_ text: String) -> [ChineseNumerals.Occurrence] {
        ChineseNumerals.reportableValues(in: text)
    }

    /// 原文里有、译文里**按数值**找不到的中文数词。
    ///
    /// **「四十亿被译成 40 billion」这一类差数量级的错，上面那条
    /// `lostDigits` 完全看不见**——「四十亿」里一个 ASCII 数字都没有，
    /// 2026-08-19 长文本实测里它就这么静默漏过去了。这里把原文数词
    /// 折算成数值（`ChineseNumerals`），在译文里找「数字 + 倍词」
    /// （`TranslatedNumbers`，倍词表按语言分，德语 Billion 是 10¹²），
    /// 值对不上才报。返回的是原文里那段数词，报告里逐字打印。
    static func lostNumerals(
        source: String, translation: String, target: Language
    ) -> [String] {
        let candidates = TranslatedNumbers.candidateValues(in: translation, target: target)
        return numeralsIn(source)
            .filter { !TranslatedNumbers.matches($0.value, anyOf: candidates) }
            .map(\.text)
    }

    /// 译文看起来像是把原文原样抄了一遍。
    ///
    /// **存在的理由是 `termPreservationRate` 的分母是从原文抽的术语——
    /// 模型把原文原样吐回来就是满分。** M5 那次「术语命中率测的是词在不在
    /// prompt 里」是同一款陷阱的另一个形态：一个看起来很好的数，实际什么
    /// 都没发生。所以「零汉字残留 + 术语满分」和「大量汉字残留 + 术语满分」
    /// 必须能在报告里分开，后者根本不是翻译。
    ///
    /// 判据取「译文里的汉字数达到原文汉字数的一半」：零星残留一两个字是
    /// 漏译，过半就只能是抄。原文没有汉字时（例如纯数字语料）返回 false
    /// ——那种素材上这条指标本来就无从谈起。
    ///
    /// 这条原先长在 `TranslationSweepTests.Row` 里。基准集报告的翻译段要用
    /// 同一条判据，**提上来共用而不是照抄一份**：抄一份就会有一天两处的
    /// 阈值不一样，而那时两份报告里同名的一列说的不是同一件事。
    static func looksCopiedFromSource(source: String, translation: String) -> Bool {
        let sourceHan = residualHanCount(source)
        return sourceHan > 0 && residualHanCount(translation) * 2 >= sourceHan
    }

    /// 译文与原文的显著字符数之比。**漏译会明显偏短。**
    ///
    /// 用 `BenchMetrics.significantCharacters` 而不是 `count`：
    /// 标点与空白不该计入，否则中英文的标点密度差异会污染这个比值。
    ///
    /// 原文为空时返回 0 而不是除零崩溃。
    static func lengthRatio(source: String, translation: String) -> Double {
        let sourceCount = BenchMetrics.significantCharacters(source).count
        guard sourceCount > 0 else { return 0 }
        let translationCount = BenchMetrics.significantCharacters(translation).count
        return Double(translationCount) / Double(sourceCount)
    }
}
