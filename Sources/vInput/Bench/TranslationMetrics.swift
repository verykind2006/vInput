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
    static func lostDigits(source: String, translation: String) -> [String] {
        let inTranslation = Set(digitsIn(translation))
        return digitsIn(source).filter { !inTranslation.contains($0) }
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
