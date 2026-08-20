import Foundation

/// 中文数词 → 数值。「四十亿被译成 40 billion」那一类差数量级的错，
/// `lostDigits` 完全看不见——「四十亿」里一个 ASCII 数字都没有。
/// 这里把两侧都折算成**数值**再比：原文侧解析中文数词，译文侧解析
/// 「数字 + 倍词」（`TranslatedNumbers`），值对得上才算保住。
///
/// # 只报解析得出的，解析不出的不进分母
///
/// 与 M6 全半角度量同一条哲学：判据窄到「凡它报出来的都无疑是错的」，
/// 读 0 才有意义。「一个亿」「五个亿」这类带量词的口语形态刻意不解析
/// （「个」不在字符集里，整串会断开成解析不出的碎片）——宁可这几条
/// 不被考到，也不要一条把「亿」单独猜成 1e8 的规则串出误报。
///
/// # 为什么只报 1000 以上的数词（加百分比）
///
/// 小数词（「三台」「八十人」）在译文里常拼成目标语言的数词
/// （three / ochenta / drei），要认它们得给六种语言各配一张数词表；
/// 而 ≥1000 的数在译文里几乎总以「数字」或「数字 + 倍词」出现，
/// 万/亿换算的数量级错也全部落在这一档。百分比不设门槛：
/// 「百分之三十」的译文是 `30%`，同样是数字呈现。
enum ChineseNumerals {
    /// 原文里解析出的一个数词。
    struct Occurrence: Equatable {
        /// 原文里的那一段字符（百分比含「百分之」前缀），报告里逐字打印它。
        let text: String
        let value: Double
        let isPercent: Bool
    }

    /// 报告门槛。理由见类型注释「为什么只报 1000 以上」。
    static let reportingThreshold: Double = 1000

    private static let simpleDigits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    private static let sectionUnits: [Character: Double] = ["十": 10, "百": 100, "千": 1000]
    private static let bigUnits: [Character: Double] = ["万": 1e4, "亿": 1e8]

    private static func asciiDigit(_ c: Character) -> Int? {
        guard c.isASCII, c.isNumber else { return nil }
        return c.wholeNumberValue
    }

    private static func isNumeralChar(_ c: Character) -> Bool {
        simpleDigits[c] != nil || sectionUnits[c] != nil || bigUnits[c] != nil
            || c == "点" || asciiDigit(c) != nil
    }

    /// 全文扫描，返回所有该报告的数词（≥1000 或百分比）。
    static func reportableValues(in text: String) -> [Occurrence] {
        scan(Array(text)).map(\.occurrence)
    }

    /// 扫描的唯一实现。度量（`reportableValues`）与改写
    /// （`rewriteAsDigits`）**共用它，不许各抄一份**——分叉的两个方向都
    /// 致命：改写动了度量没看见的数词，或者度量把改写不动的记成丢失。
    /// M6 的全半角度量在同一款坑里栽过。
    private static func scan(_ chars: [Character]) -> [(range: Range<Int>, occurrence: Occurrence)] {
        var out: [(Range<Int>, Occurrence)] = []
        var i = 0
        while i < chars.count {
            // 「百分之」优先于普通数词：它的「百」不是数词的一部分，
            // 不先消费掉就会被下面的通用扫描解析成 100。
            if i + 2 < chars.count, chars[i] == "百", chars[i + 1] == "分", chars[i + 2] == "之" {
                let start = i
                let runStart = i + 3
                let runEnd = endOfRun(chars, from: runStart)
                if runEnd > runStart, let v = value(of: String(chars[runStart..<runEnd])) {
                    out.append((
                        start..<runEnd,
                        Occurrence(text: String(chars[start..<runEnd]), value: v, isPercent: true)
                    ))
                    i = runEnd
                    continue
                }
                // 「百分之」后面解析不出数——当普通文本跳过这三个字
                i += 3
                continue
            }
            if isNumeralChar(chars[i]), chars[i] != "." {
                let runStart = i
                i = endOfRun(chars, from: i)
                let run = String(chars[runStart..<i])
                // 纯 ASCII 数字串是 `lostDigits` 的地盘（原样保留即正确）；
                // 这里只管含中文数词字符的。
                guard run.contains(where: { !$0.isASCII }) else { continue }
                if let v = value(of: run), v >= reportingThreshold {
                    out.append((
                        runStart..<i,
                        Occurrence(text: run, value: v, isPercent: false)
                    ))
                }
                continue
            }
            i += 1
        }
        return out
    }

    /// 翻译前的确定性改写：把解析得出的数词替换成阿拉伯数字。
    ///
    /// **这是数量级错的修法本体，提示词不是。** 2026-08-20 前后对照：
    /// 给提示词加「万=10⁴、亿=10⁸」的换算定义，真错 33/192 → 40/192，
    /// 一点用没有——qwen3-4b 不是不知道万是多少，是换算不稳。而「照抄
    /// 阿拉伯数字」它实测可靠（digits 语料 12/12）。所以把换算从模型
    /// 手里拿走：四百六十万 → 4600000、96万8 → 968000、百分之三十 → 30%，
    /// 模型只做它擅长的那半。
    ///
    /// 改写范围与 `reportableValues` 完全一致——**共用同一个 `scan`**：
    /// 解析不出的（一个亿）、低于 1000 的（三台）原样留给模型——改写只在
    /// 「解析器无疑读对了」的地方动手，这正是解析器判据窄的回报。
    /// 输出不带千分位分组：分组符号在六种目标语言里习惯不同（1,000 对
    /// 1.000 对 1 000），带哪种都会有一半场景要模型再转一次。
    static func rewriteAsDigits(_ text: String) -> String {
        let chars = Array(text)
        let hits = scan(chars)
        guard !hits.isEmpty else { return text }
        var out = ""
        var i = 0
        for (range, occurrence) in hits {
            out.append(contentsOf: chars[i..<range.lowerBound])
            out += formatted(occurrence.value) + (occurrence.isPercent ? "%" : "")
            i = range.upperBound
        }
        out.append(contentsOf: chars[i...])
        return out
    }

    /// 数值 → 文本。整数不带小数点；小数按最短写法（45.6 不是 45.60）。
    private static func formatted(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value))
        }
        // 数词的小数位来自「点」后逐位累积，最多几位；%g 去掉浮点尾巴
        return String(format: "%g", value)
    }

    /// 数词串的右边界。ASCII 小数点只在两侧都是 ASCII 数字时属于数词
    /// （`4.5亿` 的 `4.5`）——句号跟在数字后面（`共 3.`）不能被吞进来。
    private static func endOfRun(_ chars: [Character], from start: Int) -> Int {
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == "." {
                let prevOK = i > start && asciiDigit(chars[i - 1]) != nil
                let nextOK = i + 1 < chars.count && asciiDigit(chars[i + 1]) != nil
                if prevOK && nextOK { i += 1; continue }
                break
            }
            if isNumeralChar(c) { i += 1; continue }
            break
        }
        return i
    }

    /// 一个数词串的值。解析不出返回 nil——调用方会把它排除在分母外。
    static func value(of run: String) -> Double? {
        let chars = Array(run)
        guard !chars.isEmpty else { return nil }
        if run.contains("点") {
            return decimalValue(chars)
        }
        if asciiDigit(chars[0]) != nil {
            return asciiWithUnits(chars)
        }
        // 纯简单数字串（二零二六）：按位拼。放在通用解析之前，
        // 因为它没有单位字符，通用解析会把「二零二六」拒掉（数字相连）。
        //
        // 只认三种形态：单个数字（百分之三的三）、带零的（二零二六）、
        // 四位以上的（一九九八）。两三位又不带零的「三五」「三五七」
        // 是约数口语（三五好友），读成 35 就是误报。
        if chars.allSatisfy({ simpleDigits[$0] != nil }) {
            let positional = chars.count == 1 || chars.count >= 4
                || chars.contains("零") || chars.contains("〇")
            guard positional else { return nil }
            var v = 0.0
            for c in chars { v = v * 10 + Double(simpleDigits[c]!) }
            return v
        }
        return bigUnitValue(chars)
    }

    /// 万/亿 层级。「一百二十万亿」靠递归自然成立：亿的左边可以再含万，
    /// (一百二十万)×10⁸ = 1.2×10¹⁴。
    private static func bigUnitValue(_ chars: [Character]) -> Double? {
        for (unit, factor) in [("亿", 1e8), ("万", 1e4)] {
            guard let idx = chars.lastIndex(of: Character(unit)) else { continue }
            let left = Array(chars[..<idx])
            let right = Array(chars[(idx + 1)...])
            // 裸单位（「万一」「亿」）走到这里 left 为空，由 sectionValue
            // 的空判据统一拒绝——这里不再重复判空（冗余分支测不红）。
            guard let leftValue = bigUnitValue(left) else { return nil }
            guard let rightValue = remainder(right, unit: factor) else { return nil }
            return leftValue * factor + rightValue
        }
        return sectionValue(chars)
    }

    /// 大单位后面的余数。空 = 0；单个数字是口语简写
    /// （「一亿二」= 1.2 亿、「一万五」= 15000）；再长就按低位数词解析，
    /// 且必须小于单位本身（「一亿三千万」的三千万 < 亿）。
    private static func remainder(_ chars: [Character], unit: Double) -> Double? {
        if chars.isEmpty { return 0 }
        if chars.count == 1, let d = simpleDigits[chars[0]] ?? asciiDigit(chars[0]) {
            return Double(d) * unit / 10
        }
        guard let v = bigUnitValue(chars), v < unit else { return nil }
        return v
    }

    /// 节内（千百十）。规则：数字与单位交替、单位严格递减、
    /// 「十」可以裸用（十三）。
    ///
    /// 「零」只是跳位标记，唯一的约束是**后面必须紧跟数字**：
    /// 一万零五百（合法，零后是五）、一百零十（不合法，零后直接接单位）。
    /// 尾数字的读法取决于它是否紧跟在零后面：紧跟零是个位
    /// （一百零五 = 105），否则是上一个单位的简写（三千五 = 3500、
    /// 一万零五百三 = 10530——三紧跟的是百不是零）。
    private static func sectionValue(_ chars: [Character]) -> Double? {
        guard !chars.isEmpty else { return nil }
        var total = 0.0
        var pending: Double?
        var lastUnit = 0.0
        var zeroPending = false  // 刚读到零，下一个必须是数字
        var digitAfterZero = false  // 当前 pending 是否紧跟在零后面
        for c in chars {
            if c == "零" || c == "〇" {
                guard pending == nil, !zeroPending else { return nil }  // 「三零」「零零」
                zeroPending = true
                continue
            }
            if let d = simpleDigits[c] {
                guard pending == nil else { return nil }  // 「三五」在节内没有读法
                pending = Double(d)
                digitAfterZero = zeroPending
                zeroPending = false
                continue
            }
            if let unit = sectionUnits[c] {
                guard !zeroPending else { return nil }  // 「一百零十」
                guard lastUnit == 0 || unit < lastUnit else { return nil }  // 「二百三千」
                guard let coeff = pending ?? (unit == 10 ? 1 : nil) else { return nil }
                total += coeff * unit
                pending = nil
                // digitAfterZero 不必在这里复位：它只在收尾处对最后一个
                // pending 生效，而每个数字读入时都会重新赋值（变异验证
                // 实测过，这里复位是死代码）
                lastUnit = unit
                continue
            }
            return nil  // 万/亿/点/ASCII 不该出现在节内
        }
        guard !zeroPending else { return nil }  // 「一百零」
        if let pending {
            if digitAfterZero || lastUnit == 0 {
                total += pending  // 一百零五；或单独一个数字
            } else {
                total += pending * lastUnit / 10  // 三千五 → 3500
            }
        }
        return total
    }

    /// 混写形态：ASCII 数字打头（128万、4.5亿、3万5、96万8）。
    private static func asciiWithUnits(_ chars: [Character]) -> Double? {
        var i = 0
        var numStr = ""
        while i < chars.count, chars[i] == "." || asciiDigit(chars[i]) != nil {
            numStr.append(chars[i])
            i += 1
        }
        guard let base = Double(numStr) else { return nil }
        // 纯 ASCII 串不该走到这（调用方已排除），但「百分之30」会：
        // 百分比的数值部分允许是纯 ASCII。
        if i == chars.count { return base }
        var factor = 1.0
        var lastFactor = 0.0
        while i < chars.count, let f = bigUnits[chars[i]] {
            // 「万亿」是 10¹²（单位递增合法）；「亿万」不是数词
            guard lastFactor == 0 || f > lastFactor else { return nil }
            factor *= f
            lastFactor = f
            i += 1
        }
        guard lastFactor > 0 else { return nil }  // 数字后面跟的不是单位
        var value = base * factor
        if i < chars.count {
            // 简写尾数字：96万8 → 968000。只许一个数字收尾，且底数是整数。
            guard i == chars.count - 1,
                let d = simpleDigits[chars[i]] ?? asciiDigit(chars[i]),
                !numStr.contains(".")
            else { return nil }
            value += Double(d) * factor / 10
        }
        return value
    }

    /// 带「点」的形态：<整数部分>点<逐位小数>[万|亿|万亿]?
    /// （一点五亿、四十五点六、三点零五）。小数部分必须逐位，
    /// 「点」后面出现十百千没有读法。
    private static func decimalValue(_ chars: [Character]) -> Double? {
        var body = chars
        var factor = 1.0
        var lastFactor = Double.infinity
        while let last = body.last, let f = bigUnits[last] {
            // 从尾部往前剥，「万亿」剥出来的顺序是 亿、万——必须严格递减
            guard f < lastFactor else { return nil }
            factor *= f
            lastFactor = f
            body.removeLast()
        }
        let parts = body.split(separator: "点", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        guard let intPart = value(of: String(parts[0])), !String(parts[0]).contains("点")
        else { return nil }
        var frac = 0.0
        var scale = 0.1
        for c in parts[1] {
            guard let d = simpleDigits[c] ?? asciiDigit(c) else { return nil }
            frac += Double(d) * scale
            scale /= 10
        }
        return (intPart + frac) * factor
    }
}

/// 译文侧：把「数字 + 倍词」折算成数值候选。
///
/// # 倍词表必须按语言分开，不能合成一张
///
/// 「billion」在英文是 10⁹，在德文（Billion）是 10¹²；西语 billón 也是
/// 10¹²。合成一张表就得二选一，选哪边都会把另一边的正确译文记成丢失、
/// 或把差三个数量级的错译记成保住。表由 `TranslationTarget` 索引，
/// 加语种忘了配表是编译错误（穷尽 switch，无 default）。
///
/// # 候选是集合，比较带相对容差
///
/// `1.28 million` 算出来是 1.28×10⁶，与 128×10⁴ 在浮点上差最后一位，
/// 严格相等会把保住的记成丢失；相对容差 10⁻⁹ 远小于任何真实错误
/// （最小的数量级错也是 10 倍）。分组符的两种读法（`4.000` 是德式的
/// 4000 还是英式的 4.0）都进候选：多一个候选只可能把「丢了」误记成
/// 「保住」，方向是漏报不是误报，且要恰好撞上另一个期望值才会发生。
enum TranslatedNumbers {
    /// 每语言的倍词 → 倍数。全部小写；带音标符的给出带与不带两个拼法
    /// （模型输出偶尔丢音标符）。缩写（Mio./Mrd.）刻意不收：
    /// 听写译文是行文不是表格，收了反而要处理「mio 是不是人名缩写」。
    static func multiplierTable(for target: TranslationTarget) -> [String: Double] {
        switch target {
        case .chinese:
            return [:]  // 不翻译，永远用不到
        case .english:
            return ["thousand": 1e3, "million": 1e6, "billion": 1e9, "trillion": 1e12]
        case .spanish:
            // 西语 10⁹ 的标准说法是复合词 mil millones——靠链式连乘成立：
            // mil(10³) × millones(10⁶) = 10⁹。billón 是 10¹²，不是 10⁹。
            return [
                "mil": 1e3, "millón": 1e6, "millon": 1e6, "millones": 1e6,
                "billón": 1e12, "billon": 1e12, "billones": 1e12,
            ]
        case .german:
            // 德语 Billion 是 10¹²。这是这张表按语言分开的首要理由。
            return [
                "tausend": 1e3, "million": 1e6, "millionen": 1e6,
                "milliarde": 1e9, "milliarden": 1e9,
                "billion": 1e12, "billionen": 1e12,
            ]
        case .portuguese:
            // bilhão/bilião 按巴西读法记 10⁹（模型输出以巴葡习惯为主）。
            // 欧葡把 bilião 当 10¹²——若将来对欧葡市场，这一格要重审。
            return [
                "mil": 1e3, "milhão": 1e6, "milhao": 1e6, "milhões": 1e6, "milhoes": 1e6,
                "bilhão": 1e9, "bilhao": 1e9, "bilhões": 1e9, "bilhoes": 1e9,
                "bilião": 1e9, "biliao": 1e9, "biliões": 1e9, "bilioes": 1e9,
                "trilhão": 1e12, "trilhao": 1e12, "trilhões": 1e12, "trilhoes": 1e12,
            ]
        case .french:
            return [
                "mille": 1e3, "million": 1e6, "millions": 1e6,
                "milliard": 1e9, "milliards": 1e9,
                "billion": 1e12, "billions": 1e12,
            ]
        case .italian:
            return [
                "mille": 1e3, "mila": 1e3, "milione": 1e6, "milioni": 1e6,
                "miliardo": 1e9, "miliardi": 1e9,
                "bilione": 1e12, "bilioni": 1e12,
            ]
        }
    }

    /// 系数词 → 数值（1–20 与整十，单词形态）。基线实测（2026-08-20）里
    /// 德语把八百万译成 `acht Millionen`、意语译成 `otto milioni`；
    /// 提示词对照轮里英语把七十亿（错译成 7×10¹⁰ 时）写成
    /// `seventy billion`——系数拼成单词，只认「数字 + 倍词」既会把正确
    /// 译文记成丢失，也会让错译逃过按值判定。收整词能查表的这一档；
    /// **组合数词**（soixante-dix、venticinque、cuatro millones
    /// seiscientos mil 的 seiscientos）刻意不做——那要背六种语言的组合
    /// 语法，错一条就是新的误报源。没认出来的后果有界：至多把「保住」
    /// 记成「丢失」，报告里译文就在旁边，人过一眼即知。
    static func smallWordTable(for target: TranslationTarget) -> [String: Double] {
        switch target {
        case .chinese:
            return [:]
        case .english:
            return [
                "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
                "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
                "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
                "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
                "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
                "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
            ]
        case .spanish:
            return [
                "un": 1, "uno": 1, "una": 1, "dos": 2, "tres": 3, "cuatro": 4,
                "cinco": 5, "seis": 6, "siete": 7, "ocho": 8, "nueve": 9,
                "diez": 10, "once": 11, "doce": 12, "trece": 13, "catorce": 14,
                "quince": 15, "dieciséis": 16, "dieciseis": 16, "diecisiete": 17,
                "dieciocho": 18, "diecinueve": 19, "veinte": 20, "treinta": 30,
                "cuarenta": 40, "cincuenta": 50, "sesenta": 60, "setenta": 70,
                "ochenta": 80, "noventa": 90,
            ]
        case .german:
            return [
                "ein": 1, "eine": 1, "einen": 1, "einer": 1, "zwei": 2, "drei": 3,
                "vier": 4, "fünf": 5, "funf": 5, "sechs": 6, "sieben": 7, "acht": 8,
                "neun": 9, "zehn": 10, "elf": 11, "zwölf": 12, "zwolf": 12,
                "dreizehn": 13, "vierzehn": 14, "fünfzehn": 15, "funfzehn": 15,
                "sechzehn": 16, "siebzehn": 17, "achtzehn": 18, "neunzehn": 19,
                "zwanzig": 20, "dreißig": 30, "dreissig": 30, "vierzig": 40,
                "fünfzig": 50, "funfzig": 50, "sechzig": 60, "siebzig": 70,
                "achtzig": 80, "neunzig": 90,
            ]
        case .portuguese:
            return [
                "um": 1, "uma": 1, "dois": 2, "duas": 2, "três": 3, "tres": 3,
                "quatro": 4, "cinco": 5, "seis": 6, "sete": 7, "oito": 8,
                "nove": 9, "dez": 10, "onze": 11, "doze": 12, "treze": 13,
                "catorze": 14, "quatorze": 14, "quinze": 15, "dezesseis": 16,
                "dezasseis": 16, "dezessete": 17, "dezassete": 17, "dezoito": 18,
                "dezenove": 19, "dezanove": 19, "vinte": 20, "trinta": 30,
                "quarenta": 40, "cinquenta": 50, "sessenta": 60, "setenta": 70,
                "oitenta": 80, "noventa": 90,
            ]
        case .french:
            return [
                "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5,
                "six": 6, "sept": 7, "huit": 8, "neuf": 9, "dix": 10,
                "onze": 11, "douze": 12, "treize": 13, "quatorze": 14,
                "quinze": 15, "seize": 16, "vingt": 20, "trente": 30,
                "quarante": 40, "cinquante": 50, "soixante": 60,
            ]
        case .italian:
            return [
                "un": 1, "uno": 1, "una": 1, "due": 2, "tre": 3, "quattro": 4,
                "cinque": 5, "sei": 6, "sette": 7, "otto": 8, "nove": 9,
                "dieci": 10, "undici": 11, "dodici": 12, "tredici": 13,
                "quattordici": 14, "quindici": 15, "sedici": 16,
                "diciassette": 17, "diciotto": 18, "diciannove": 19,
                "venti": 20, "trenta": 30, "quaranta": 40, "cinquanta": 50,
                "sessanta": 60, "settanta": 70, "ottanta": 80, "novanta": 90,
            ]
        }
    }

    /// 译文里所有数值候选。
    ///
    /// 数字串允许包含分组/小数符号（`, . ' 空格 不换行空格`），
    /// 其后跳过空格与连字符去找倍词，倍词可以连乘（mil millones）。
    /// `7-billion-parameter` 里的连字符就是这么接上的——那是 2026-08-19
    /// 实测里模型真实的输出形态。系数也可以是 1–12 的单词
    /// （`acht Millionen`），见 `smallWordTable`；**必须带倍词才算数**——
    /// 光一个 `eight` 不产生候选，否则译文里每个小词都会变成候选值，
    /// 判据就宽得没有意义了。
    static func candidateValues(in text: String, target: TranslationTarget) -> [Double] {
        let table = multiplierTable(for: target)
        let smallWords = smallWordTable(for: target)
        var out: [Double] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i].isLetter {
                // 系数词（acht Millionen）：整词匹配，且必须带倍词——
                // 光一个小词不产生候选
                var n = i
                var word: [Character] = []
                while n < chars.count, chars[n].isLetter {
                    word.append(chars[n])
                    n += 1
                }
                if let coeff = smallWords[String(word).lowercased()] {
                    let (factor, end, factored) = multiplierChain(chars, from: n, table: table)
                    if factored {
                        out.append(coeff * factor)
                        i = end
                        continue
                    }
                }
                i = n
                continue
            }
            guard chars[i].isASCII, chars[i].isNumber else {
                i += 1
                continue
            }
            var j = i
            var token: [Character] = []
            while j < chars.count {
                let c = chars[j]
                if c.isASCII, c.isNumber {
                    token.append(c)
                    j += 1
                    continue
                }
                // 分隔符只在后面紧跟数字时属于数字串——
                // 句末的 `4.` 不能把句号吞进来
                if c == "," || c == "." || c == "'" || c == " " || c == "\u{00A0}",
                    j + 1 < chars.count, chars[j + 1].isASCII, chars[j + 1].isNumber
                {
                    token.append(c == "\u{00A0}" ? " " : c)
                    j += 1
                    continue
                }
                break
            }
            let bases = interpretations(of: String(token))
            out.append(contentsOf: bases)

            let (factor, end, factored) = multiplierChain(chars, from: j, table: table)
            if factored { out.append(contentsOf: bases.map { $0 * factor }) }
            i = max(j, end)
        }
        return out
    }

    /// 从 `from` 起跳过空格/连字符逐词找倍词，连乘（mil millones = 10⁹）。
    private static func multiplierChain(
        _ chars: [Character], from: Int, table: [String: Double]
    ) -> (factor: Double, end: Int, factored: Bool) {
        var k = from
        var factor = 1.0
        var factored = false
        while true {
            var m = k
            while m < chars.count, chars[m] == " " || chars[m] == "-" || chars[m] == "\u{00A0}" {
                m += 1
            }
            var word: [Character] = []
            var n = m
            while n < chars.count, chars[n].isLetter {
                word.append(chars[n])
                n += 1
            }
            guard !word.isEmpty, let f = table[String(word).lowercased()] else { break }
            factor *= f
            factored = true
            k = n
        }
        return (factor, k, factored)
    }

    /// 一个数字串的全部读法。
    ///
    /// 空格分组（法语 `4 000 000 000`）：后续组全为 3 位数字才合并；
    /// 无论合并与否，各组单独的读法也进候选（电话号码那种 4 位分组
    /// 只会走这条）。
    static func interpretations(of token: String) -> [Double] {
        var out: [Double] = []
        let groups = token.split(separator: " ")
        if groups.count > 1 {
            if groups.first!.count <= 3,
                groups.dropFirst().allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isNumber) })
            {
                out += separatorInterpretations(groups.joined())
            }
            for g in groups { out += separatorInterpretations(String(g)) }
        } else {
            out += separatorInterpretations(token)
        }
        return out
    }

    /// 逗号/句点二义：`1,234.56`（英式）与 `1.234,56`（欧式）都要认。
    /// 分组符的组必须是标准 3 位（首组 1–3 位），否则那种读法作废——
    /// `1.28` 因此只有小数一种读法，不会多出一个 128 的候选。
    private static func separatorInterpretations(_ s: String) -> [Double] {
        let stripped = s.replacingOccurrences(of: "'", with: "")
        guard stripped.contains(",") || stripped.contains(".") else {
            return Double(stripped).map { [$0] } ?? []
        }
        var out: [Double] = []
        for (group, decimal) in [(Character(","), Character(".")), (Character("."), Character(","))] {
            let parts = stripped.split(separator: decimal, omittingEmptySubsequences: false)
            guard parts.count <= 2, let intPart = parts.first,
                parts.count == 1 || parts[1].allSatisfy(\.isNumber)
            else { continue }
            guard groupingValid(String(intPart), separator: group) else { continue }
            let digits = String(intPart).replacingOccurrences(of: String(group), with: "")
            let joined = parts.count == 2 ? "\(digits).\(parts[1])" : digits
            if let v = Double(joined) { out.append(v) }
        }
        return out
    }

    private static func groupingValid(_ s: String, separator: Character) -> Bool {
        let groups = s.split(separator: separator, omittingEmptySubsequences: false)
        if groups.count == 1 { return groups[0].allSatisfy(\.isNumber) && !groups[0].isEmpty }
        guard let first = groups.first, (1...3).contains(first.count),
            first.allSatisfy(\.isNumber)
        else { return false }
        return groups.dropFirst().allSatisfy { $0.count == 3 && $0.allSatisfy(\.isNumber) }
    }

    /// 值比较。相对容差的理由见类型注释。
    static func matches(_ expected: Double, anyOf candidates: [Double]) -> Bool {
        candidates.contains { abs($0 - expected) <= max(abs($0), abs(expected)) * 1e-9 }
    }
}
