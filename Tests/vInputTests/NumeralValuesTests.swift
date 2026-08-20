import Foundation
import Testing

@testable import vInput

/// `ChineseNumerals` / `TranslatedNumbers` / `lostNumerals` 的判据测试。
///
/// 变异验证（每条判据故意改坏跑一遍，确认对应用例真的红）的记录
/// 在本文件末尾的注释里。
@Suite("中文数词的数值解析")
struct ChineseNumeralsTests {
    /// 表驱动：形态 × 期望值。每一行都是语料或真实转写里出现过的形态。
    @Test(
        "各形态解析出正确数值",
        arguments: [
            // 纯中文，万/亿 层级
            ("四十亿", 4e9),
            ("七十亿", 7e9),
            ("二十亿", 2e9),
            ("两亿", 2e8),
            ("一百二十八万", 1_280_000),
            ("三千五百万", 35_000_000),
            ("五千万", 50_000_000),
            ("八百万", 8_000_000),
            ("八千万", 80_000_000),
            ("一千三百万", 13_000_000),
            ("四百六十万", 4_600_000),
            ("六千八百万", 68_000_000),
            ("三百五十万", 3_500_000),
            ("一亿三千万", 130_000_000),
            ("一万二千", 12000),
            ("三千五百", 3500),
            // 口语简写：大单位后单个数字是下一级的系数
            ("一亿二", 120_000_000),
            ("一万五", 15000),
            ("两万三", 23000),
            ("十三万五", 135_000),
            ("三千五", 3500),
            // 零：跳位标记，尾数字紧跟零时是个位，否则仍是简写
            ("一百零五", 105),
            ("一万零五百", 10500),
            ("三千零二十", 3020),
            ("一万零五百三", 10530),
            ("十万零三百", 100_300),
            // 万亿 = 10¹²（亿的左边可以再含万）
            ("一百二十万亿", 1.2e14),
            // 混写：ASCII 数字 + 中文单位
            ("128万", 1_280_000),
            ("12万", 120_000),
            ("1.5亿", 150_000_000),
            ("3万5", 35000),
            ("96万8", 968_000),
            // 带「点」的小数
            ("一点五亿", 150_000_000),
            ("二点六亿", 260_000_000),
            ("三点零五万", 30500),
            // 按位数字串（年份）
            ("二零二六", 2026),
        ] as [(String, Double)])
    func parsesValue(run: String, expected: Double) {
        #expect(ChineseNumerals.value(of: run) == expected, "「\(run)」")
    }

    /// 解析不出的形态必须返回 nil——它们会被排除在分母外，
    /// 而不是被一条宽松规则猜出一个错的值。
    @Test(
        "不是数词的串拒绝解析",
        arguments: [
            "万一", "千万", "亿", "万", "十百", "三五", "一百零十", "一百零十五",
            "亿万", "点五", "二百三千", "一百零",
        ])
    func rejectsNonNumerals(run: String) {
        #expect(ChineseNumerals.value(of: run) == nil, "「\(run)」不该解析出值")
    }

    @Test("全文扫描：分母只收 1000 以上的数词与百分比")
    func reportableRespectsThreshold() {
        let occurrences = ChineseNumerals.reportableValues(
            in: "一共八十台，总价四十亿，首付百分之三十。")
        #expect(
            occurrences == [
                ChineseNumerals.Occurrence(text: "四十亿", value: 4e9, isPercent: false),
                ChineseNumerals.Occurrence(text: "百分之三十", value: 30, isPercent: true),
            ])
    }

    @Test("百分比：小数与整数都解析，且「百分之」的百不算数词")
    func percentages() {
        let occurrences = ChineseNumerals.reportableValues(
            in: "良品率百分之九十八点五，利息百分之四点二五。")
        #expect(occurrences.map(\.value) == [98.5, 4.25])
        let allPercent = occurrences.allSatisfy(\.isPercent)
        #expect(allPercent)
    }

    /// 「一个亿」的「个」不在字符集里，整串断开后各碎片都解析不出
    /// 或低于门槛——刻意不支持，理由见 `ChineseNumerals` 的类型注释。
    @Test("带量词的口语形态不进分母")
    func classifierFormsAreExcluded() {
        #expect(ChineseNumerals.reportableValues(in: "去年亏了一个亿。").isEmpty)
        #expect(ChineseNumerals.reportableValues(in: "千万别答应他。").isEmpty)
        #expect(ChineseNumerals.reportableValues(in: "万一他不来呢。").isEmpty)
    }

    @Test("人名与序数里的小数词不报告")
    func smallNumbersInNamesAreExcluded() {
        #expect(ChineseNumerals.reportableValues(in: "十三爷讲耶稣，第三批发货。").isEmpty)
    }

    /// 句号紧跟数字（「共 3.」）不能被吞进数词串。
    @Test("ASCII 小数点只在两侧都是数字时属于数词")
    func asciiDotBoundary() {
        let occurrences = ChineseNumerals.reportableValues(in: "报价4.5亿。尾款3万.")
        #expect(occurrences.map(\.value) == [450_000_000, 30000])
    }
}

@Suite("翻译前的数词改写")
struct RewriteAsDigitsTests {
    /// 改写是数量级错的修法本体（提示词那条路实测无效，33/192 → 40/192，
    /// 见 TranslationPrompt 注释）。范围与度量共用同一个扫描：
    /// 解析得出且 ≥1000 的数词、以及百分比，其余一个字不动。
    @Test(
        "解析得出的数词换成阿拉伯数字，其余原样",
        arguments: [
            ("合同金额四百六十万，分三期付款。", "合同金额4600000，分三期付款。"),
            ("报价单上写的是96万8，不含运费。", "报价单上写的是968000，不含运费。"),
            ("这批设备总价三千五百万，首付百分之三十。", "这批设备总价35000000，首付30%。"),
            ("良品率百分之九十八点五。", "良品率98.5%。"),
            ("他们开价1.5亿，我们最多出一亿二。", "他们开价150000000，我们最多出120000000。"),
            ("那个大模型有七十亿参数，小的那个只有四十亿。", "那个大模型有7000000000参数，小的那个只有4000000000。"),
            // 低于 1000 的、解析不出的、纯 ASCII 的都不动
            ("一共八十台，三天到货。", "一共八十台，三天到货。"),
            ("去年亏了一个亿。", "去年亏了一个亿。"),
            ("这个方案的报价是 128000 元。", "这个方案的报价是 128000 元。"),
            ("千万别答应他。", "千万别答应他。"),
            // 约数形态整串不动——量级单位在 多/几/来/余 后面，解析器只吃
            // 得到半个数词。2026-08-20 QA 实测「百分之十几」曾被改写成
            // 「10%几」，语义直接损坏，比不改写更糟
            ("涨了百分之十几。", "涨了百分之十几。"),
            ("一千几百万的样子。", "一千几百万的样子。"),
            ("预算两千多万。", "预算两千多万。"),
            ("有几十万用户。", "有几十万用户。"),
            ("数百万的预算。", "数百万的预算。"),
            ("库存十余万件。", "库存十余万件。"),
            ("大概三十来万。", "大概三十来万。"),
            // 「约/大约」不拖累后面的完整数词——它以数字开头，值无疑是对的
            ("大约四百六十万。", "大约4600000。"),
        ] as [(String, String)])
    func rewrites(source: String, expected: String) {
        #expect(ChineseNumerals.rewriteAsDigits(source) == expected, "「\(source)」")
    }

    /// 改写后的文本再改写一遍必须不变——阿拉伯数字不在这条度量的射程里，
    /// 二次改写有变化就说明改写把自己的输出又当成了数词。
    @Test("改写是幂等的")
    func idempotent() {
        let once = ChineseNumerals.rewriteAsDigits("总预算四十亿，首付百分之三十。")
        #expect(ChineseNumerals.rewriteAsDigits(once) == once)
    }
}

@Suite("译文侧的数值候选")
struct TranslatedNumbersTests {
    /// 真实案例（2026-08-19 长文本实测）：模型把「四十亿」译成
    /// `40-billion-parameter`，差十倍。提取器必须能从连字符复合词里
    /// 读出 4e10，判据才能发现它不等于 4e9。
    @Test("数字 + 倍词的各种形态")
    func multiplierForms() {
        func has(_ v: Double, _ text: String, _ t: TranslationTarget) -> Bool {
            TranslatedNumbers.matches(v, anyOf: TranslatedNumbers.candidateValues(in: text, target: t))
        }
        #expect(has(4e9, "a 4 billion parameter model", .english))
        #expect(has(4e10, "a 40-billion-parameter model", .english))
        #expect(!has(4e9, "a 40-billion-parameter model", .english))
        #expect(has(4e9, "4,000,000,000 parámetros", .spanish))
        #expect(has(4e9, "4 mil millones de parámetros", .spanish))
        #expect(has(4e9, "4.000 millones de parámetros", .spanish))
        #expect(has(4e9, "4 Milliarden Parameter", .german))
        #expect(has(4e9, "4 milliards de paramètres", .french))
        #expect(has(4e9, "4 000 000 000 de paramètres", .french))
        #expect(has(4e9, "4 bilhões de parâmetros", .portuguese))
        #expect(has(4e9, "4 miliardi di parametri", .italian))
        #expect(has(1.28e6, "1.28 million yuan", .english))
        #expect(has(1.28e6, "1,28 Millionen Yuan", .german))
        #expect(has(23.5, "una tasa del 23,5 %", .spanish))
        #expect(has(12000, "12.000 Quadratmeter", .german))
        #expect(has(12000, "12,000 square meters", .english))
    }

    /// 系数拼成单词的形态。**这两句是 2026-08-20 基线里真实的误报**：
    /// 德语把八百万（正确地）译成 `acht Millionen`、意语译成
    /// `otto milioni`，只认「数字 + 倍词」的第一版把它们记成了丢失。
    /// 光一个小词不带倍词不产生候选——否则译文里每个 `one`/`un` 都成了
    /// 候选值，判据宽得没有意义。
    @Test("系数词 + 倍词（acht Millionen）")
    func spelledOutCoefficients() {
        func has(_ v: Double, _ text: String, _ t: TranslationTarget) -> Bool {
            TranslatedNumbers.matches(v, anyOf: TranslatedNumbers.candidateValues(in: text, target: t))
        }
        #expect(has(8e6, "der tägliche Nutzerverkehr beträgt etwa acht Millionen", .german))
        #expect(has(8e6, "un numero di utenti attivi giornalieri di circa otto milioni", .italian))
        #expect(has(1e9, "eine Milliarde Parameter", .german))
        #expect(has(2e6, "two million users", .english))
        // 五千万被错译成 fünf Millionen（基线真实错误）——系数词认出来
        // 也依然是 5e6，不能等于 5e7
        #expect(!has(5e7, "überschreitet fünf Millionen", .german))
        // 光一个小词不算数
        #expect(!has(8, "acht Stück", .german))
    }

    /// **倍词表按语言分开的理由**：billion 在英文是 10⁹、在德文是 10¹²，
    /// 西语 billón 也是 10¹²。合表就会把「4 Billionen」（差三个数量级的
    /// 错译）记成保住了 4e9。
    @Test("假朋友：德语 Billion 与西语 billón 是万亿")
    func falseFriends() {
        let de = TranslatedNumbers.candidateValues(in: "4 Billionen", target: .german)
        #expect(TranslatedNumbers.matches(4e12, anyOf: de))
        #expect(!TranslatedNumbers.matches(4e9, anyOf: de))
        let es = TranslatedNumbers.candidateValues(in: "4 billones", target: .spanish)
        #expect(TranslatedNumbers.matches(4e12, anyOf: es))
        #expect(!TranslatedNumbers.matches(4e9, anyOf: es))
        // 同一个词在英文里是 10⁹
        let en = TranslatedNumbers.candidateValues(in: "4 billion", target: .english)
        #expect(TranslatedNumbers.matches(4e9, anyOf: en))
    }

    /// `1.28` 不能多出一个 128 的候选（分组必须是标准 3 位），
    /// 否则「期望 128 万、译文只有 1.28」这种真丢失会被误记成保住。
    @Test("分组读法要求标准三位")
    func groupingRequiresThreeDigits() {
        #expect(TranslatedNumbers.interpretations(of: "1.28") == [1.28])
        #expect(TranslatedNumbers.interpretations(of: "4.000").sorted() == [4.0, 4000])
        #expect(TranslatedNumbers.interpretations(of: "1.234,56") == [1234.56])
        #expect(TranslatedNumbers.interpretations(of: "1,234.56") == [1234.56])
    }

    /// 浮点：原文侧「四点五六万」的小数累积（`frac += d × scale`）算出的
    /// 值与译文侧的精确整数 45600 **在位级不相等**（挑这条是实测过的：
    /// 大多数小数样本恰好整圆相等，这条不），严格相等会把保住的记成丢失。
    /// 容差同时不能宽到把十倍错也放过去。
    @Test("值比较的容差：吞浮点误差，不吞数量级错")
    func toleranceIsRelative() {
        // 走真实管线：两侧各自算各自的浮点
        let parsed = ChineseNumerals.value(of: "四点五六万")
        #expect(parsed != nil && parsed != 45600, "样本失效：两侧位级相等，这条测不到容差了")
        #expect(
            TranslationMetrics.lostNumerals(
                source: "预算四点五六万。", translation: "A budget of 45,600.",
                target: .english
            ).isEmpty)
        #expect(!TranslatedNumbers.matches(4e9, anyOf: [4e10]))
        #expect(!TranslatedNumbers.matches(4e9, anyOf: [4.0000001e9]))
    }
}

@Suite("数词丢失判据（lostNumerals / lostDigits 分工）")
struct LostNumeralsTests {
    /// **这条就是 2026-08-19 抓到的那个 bug。** 同一段话里
    /// 七十亿译对、四十亿译成 40 billion——判据必须只报后者。
    @Test("四十亿被译成 40 billion 时报告丢失")
    func catchesTheObservedBug() {
        let source = "那个模型有七十亿参数，小的那个只有四十亿。"
        let wrong = "That model has 7-billion-parameter, the small one only 40 billion."
        let right = "That model has 7 billion parameters, the small one only 4 billion."
        #expect(
            TranslationMetrics.lostNumerals(source: source, translation: wrong, target: .english)
                == ["四十亿"])
        #expect(
            TranslationMetrics.lostNumerals(source: source, translation: right, target: .english)
                .isEmpty)
    }

    @Test("百分比按数值比对")
    func percentByValue() {
        let source = "首付百分之三十，利息百分之四点二五。"
        #expect(
            TranslationMetrics.lostNumerals(
                source: source, translation: "30% down, 4.25% interest.", target: .english
            ).isEmpty)
        #expect(
            TranslationMetrics.lostNumerals(
                source: source, translation: "30% down, 42.5% interest.", target: .english
            ) == ["百分之四点二五"])
    }

    /// `lostDigits` 的分工修正：「128万」的 128 不该被要求原样出现——
    /// 正确译文 `1.28 million` 里没有 128，那是 `lostNumerals` 按值
    /// 比对的对象。不带单位的 ASCII 数字（128000）行为不变。
    @Test("混写数字归数值判据，纯数字仍要求原样保留")
    func mixedFormsBelongToNumerals() {
        let mixed = "全年营收128万，比去年多了3万5。"
        #expect(TranslationMetrics.copyableDigits(in: mixed).isEmpty)
        #expect(
            TranslationMetrics.lostDigits(
                source: mixed, translation: "Annual revenue of 1.28 million, up 35,000."
            ).isEmpty)
        #expect(
            TranslationMetrics.lostNumerals(
                source: mixed, translation: "Annual revenue of 1.28 million, up 35,000.",
                target: .english
            ).isEmpty)

        let plain = "这个方案的报价是 128000 元，45.6 美元一件。"
        #expect(TranslationMetrics.copyableDigits(in: plain) == ["128000", "45", "6"])
        #expect(
            TranslationMetrics.lostDigits(
                source: plain, translation: "The quote is 96000 yuan, 45.6 dollars each."
            ) == ["128000"])
    }

    /// 小数混写「4.5亿」要整个让给数值判据——把 4 留在 `lostDigits` 里，
    /// 正确译文 `450 million` 会被记成丢了 4。
    @Test("小数混写整体排除出 lostDigits")
    func decimalMixedFormsExcluded() {
        let source = "他们开价1.5亿。"
        #expect(TranslationMetrics.copyableDigits(in: source).isEmpty)
        #expect(
            TranslationMetrics.lostDigits(
                source: source, translation: "They asked for 150 million."
            ).isEmpty)
        #expect(
            TranslationMetrics.lostNumerals(
                source: source, translation: "They asked for 150 million.", target: .english
            ).isEmpty)
        #expect(
            TranslationMetrics.lostNumerals(
                source: source, translation: "They asked for 15 million.", target: .english
            ) == ["1.5亿"])
    }

    /// 解析不出的数词不进分母：译文再离谱也不报，
    /// 因为报了就可能是误报（宁可漏报，判据要窄）。
    @Test("解析不出的形态不产生任何报告")
    func unparsedFormsNeverReport() {
        #expect(
            TranslationMetrics.lostNumerals(
                source: "去年亏了一个亿。", translation: "Lost ten yuan last year.",
                target: .english
            ).isEmpty)
    }

    /// 约数形态也不进分母——「两千多万」的正确译文是 over twenty
    /// million，里面理所当然没有 2000，把 两千 当分母就是**必然误报**，
    /// 违反「凡报出来的都无疑是错的」（2026-08-20 QA 发现）。
    @Test("约数形态不进分母")
    func approximateFormsNeverReport() {
        #expect(TranslationMetrics.numeralsIn("预算两千多万。").isEmpty)
        #expect(TranslationMetrics.numeralsIn("有几十万用户。").isEmpty)
        #expect(
            TranslationMetrics.lostNumerals(
                source: "预算两千多万。", translation: "A budget of over twenty million.",
                target: .english
            ).isEmpty)
    }
}

// 变异验证记录（2026-08-20，每处改坏 → 跑 --filter NumeralValues →
// 确认对应用例红 → 改回）：
//
// | # | 变异 | 结果 |
// |---|---|---|
// | 1 | 简写系数 `unit / 10` → `unit` | 抓到（一亿二 → 3e8） |
// | 2 | reportingThreshold 1000 → 0 | 抓到（八十进了分母） |
// | 3 | 大单位左侧判空删除 | **等价变异**——空串被 sectionValue 的空判据拒绝，冗余 guard 已删 |
// | 4 | 按位读法的形态门槛删除 | 抓到（三五 → 35） |
// | 5 | 「百分之」分支停用 | 抓到（百分比两条用例红） |
// | 6 | 德语 Billion 1e12 → 1e9 | 抓到（假朋友用例） |
// | 7 | 分组「后续组必须 3 位」放松 | 抓到（1.28 多出 128 候选） |
// | 8 | 倍词链 `factor *= f` → `factor = f` | 抓到（mil millones 变 1e6） |
// | 9 | 容差 → 严格相等 | 抓到（四点五六万 vs 45,600——样本是实测挑的，多数小数恰好整圆相等，测不到） |
// | 10 | lostDigits 的混写排除删除 | 抓到（1.5亿 的 1、5 漏回 copyable） |
// | 11 | lostNumerals 过滤条件反转 | 抓到（多条用例红） |
// | 12 | 节内单位递减校验删除 | 抓到（二百三千 → 3200） |
// | 13 | 个位/简写分界坍缩 | 抓到（一百零五 → 150）。**这条变异顺带挖出解析器真 bug**：初版把「零后接单位」一律拒绝，连一万零五百都被拒，已修 |
// | 14 | 「零后必须接数字」删除 | 抓到（一百零十五——尾部守卫救不了这条） |
// | 15 | 单位分支复位 digitAfterZero | **等价变异**——数字读入时每次重新赋值，该复位是死代码，已删 |
// | 16 | 系数词分支停用 | 抓到（acht Millionen 用例） |
// | 17 | 系数词「必须带倍词」放松 | 抓到（acht Stück 不产生候选） |
// | 18–20 | 改写器：% 后缀 / 间隙文本 / 整数格式 | 各自抓到（改写表驱动用例） |
// | 21 | 管线不改写（translate 传原文） | 抓到（翻译器收到改写后文本） |
//
// 独立 QA（2026-08-20，另一名代理亲手做，不照抄本表）：9 处变异抓 7、
// 存活 2——闸门拒绝与超时路径改回 rewritten 无测试红，成因是那两条用例
// 素材不含数词。已补三条「退回未改写原文」用例（素材带数词）并复验：
// 同样的两处变异现在当场红。QA 同时发现约数形态（两千多万、几十万、
// 百分之十几）被吃掉半个数词，scan 加 approxTrailing/approxLeading 整串
// 放弃；三处新守卫的变异（尾随/前置/百分比分支各删一处）全部抓到。
