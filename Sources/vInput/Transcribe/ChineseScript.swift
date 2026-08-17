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

    /// 这个字符是否处在「中文语境」里。
    ///
    /// 用途是判断一个半角标点该不该转全角。转换器（`TranscriptCleaner`）与
    /// 度量（`BenchMetrics`）都经由 `fullWidthConversions` 用这同一把尺子，
    /// 否则会出现「转换器改了、度量看不见」或者反过来的情形——而 M6 ⑤ 的
    /// 教训正是度量与实际输出对不上就等于没有度量。
    ///
    /// **判据是字符本身，不是整段文本的语言。** 整段判定在中英混排上必然
    /// 出错：`他说 "Hello, world" 然后走了` 整段是中文，可那个逗号是英文
    /// 短语内部的。逐字符看邻居才分得开。
    ///
    /// 收进来的区段：
    /// - 汉字（含扩展 A/B 与兼容区）
    /// - CJK 符号与标点 `U+3000–U+303F`：、。「」《》…
    /// - 全角形式 `U+FF00–U+FFEF`：，？！：；（）以及全角字母数字
    ///
    /// **刻意不收 `U+2018–U+201D` 那几个弯引号**：英文同样在用它们，
    /// 收进来会把 `he said “Hello, world”` 里的逗号判成中文语境。
    static func isChineseContext(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first else { return false }
        return switch scalar.value {
        case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            true
        default:
            false
        }
    }

    /// 半角标点 → 全角标点。**按邻居规则判定的那一类**（见
    /// `fullWidthConversions`），括号不在其中，它另有一套判据。
    ///
    /// 只收中文里确有对应写法的这几个。`"` `'` 不在其中——中文的引号是
    /// 「」或“”，一对一映射说不清左右，猜错比不改更糟。
    static let fullWidthPunctuation: [Character: Character] = [
        ",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；",
    ]

    /// 半角括号 → 全角括号。
    ///
    /// **和上面那张表分开，因为判据不同。** 括号是成对的，而邻居规则逐个字符
    /// 看：`函数 foo(x) 的返回值` 里左括号前邻是拉丁、右括号后邻是汉字，
    /// 邻居规则会把这一对拆成一半一全。见 `fullWidthConversions`。
    static let fullWidthBrackets: (open: Character, close: Character) = ("（", "）")

    /// `TranscriptCleaner` 实际改写的半角字符。
    ///
    /// **比 `fullWidthConversions` 认出来的少一个句号**，这是 2026-08-17
    /// 用户点名的范围（逗号、问号、叹号、冒号、分号，外加成对的括号），
    /// 句号不在其列。句号也确实不该顺手加进来：`我想想...` 的三个点各自
    /// 都满足邻居规则，转完是「我想想。。。」；而用户给的证据里句号本来
    /// 就是全角的（「把 M8 的分场景优化改成?」——句号全角、问号半角），
    /// 收益也小。度量仍然数它：度量该看见全部，改不改是另一个决定。
    static let normalizedHalfWidth: Set<Character> = [",", "?", "!", ":", ";", "(", ")"]

    /// 找出「写成了半角、但按中文排版该是全角」的标点位置，
    /// 返回「下标 → 全角字符」。
    ///
    /// **转换器（`TranscriptCleaner`）与度量（`BenchMetrics`）共用这一个
    /// 函数，不是各写一遍判据。** 上一轮只有逗号时两处是各自实现的同一条
    /// 规则，扩到括号之后那样必然分叉——括号的判据复杂得多，一旦两把尺子
    /// 不一样，「转换器改了但度量看不见」（或者反过来：度量把转换器刻意
    /// 不改的东西记成退化，指标从此恒不为零、没人再看）就会发生。
    /// 而 M6 ⑤ 的教训正是度量与实际输出对不上就等于没有度量。
    ///
    /// 两类判据：
    ///
    /// **① `, . ? ! : ;`——看邻居。** 跳过空白与相连的标点（见
    /// `isSkippableNeighbor`）之后离它最近的那个实字符，
    /// 两侧任一处在中文语境就转。这条同时挡住了最贵的误伤：千分位
    /// `1,200,000` 两侧都是数字，一个字都不会动。
    ///
    /// **② `( )`——成对判断，且严格得多。** 括号在代码、路径、函数签名里
    /// 极常见，误伤代价高。三条同时满足才转：
    /// - 成对（有配得上的另一半）；
    /// - 括号内有中文、且**没有拉丁字母**——数字放行，`（见 2.1 节）` 是
    ///   正常中文行文，一刀切禁数字会漏掉一大类；
    /// - 括号外紧邻处**没有拉丁字母或数字粘着**，且两侧至少一处是中文语境。
    ///   粘连（`bin(不要改)`、`render(这里传中文)`）是函数调用与路径的形状，
    ///   中文行文里几乎不这么写。
    static func fullWidthConversions(in characters: [Character]) -> [Int: Character] {
        var conversions: [Int: Character] = [:]
        var openBrackets: [Int] = []

        for (index, character) in characters.enumerated() {
            if let fullWidth = fullWidthPunctuation[character] {
                if isChineseContext(precedingCharacter(in: characters, before: index))
                    || isChineseContext(followingCharacter(in: characters, after: index)) {
                    conversions[index] = fullWidth
                }
            } else if character == "(" {
                openBrackets.append(index)
            } else if character == ")" {
                // 配不上的右括号直接丢弃：不成对时括号的范围是未知的，
                // 也就无从判断「里面是什么」。Whisper 漏掉一半括号是常事。
                if let open = openBrackets.popLast(),
                   isChineseBracketPair(in: characters, open: open, close: index) {
                    conversions[open] = fullWidthBrackets.open
                    conversions[index] = fullWidthBrackets.close
                }
            }
        }
        return conversions
    }

    /// 这一对括号是不是「中文的括号」。判据见 `fullWidthConversions` 的 ②。
    private static func isChineseBracketPair(
        in characters: [Character], open: Int, close: Int
    ) -> Bool {
        let content = characters[(open + 1)..<close]
        guard content.contains(where: { isChineseContext($0) }) else { return false }
        guard !content.contains(where: { $0.isASCII && $0.isLetter }) else { return false }

        let before = precedingCharacter(in: characters, before: open)
        let after = followingCharacter(in: characters, after: close)
        guard !isLatinOrDigit(before), !isLatinOrDigit(after) else { return false }
        return isChineseContext(before) || isChineseContext(after)
    }

    /// 括号紧贴着它就判成代码：函数调用 `render(…)`、路径 `bin(…)`、
    /// 下标 `arr2(…)` 都是这个形状。
    private static func isLatinOrDigit(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isASCII && (character.isLetter || character.isNumber)
    }

    /// 找邻居时可以跨过去的字符：空白，以及别的半角标点。
    ///
    /// **必须跨过标点**：`真的吗?!` 里叹号紧挨着问号，只看紧邻的实字符会把
    /// 叹号判成「不在中文语境」，转出「真的吗？!」这种一半一半的结果。
    /// 连写的标点（`?!`、`!!!`）在口语转写里常见，一串必须一起转或一起不转。
    ///
    /// **数字与字母不在其列**，千分位 `1,200,000` 的保护正来自这一点：
    /// 逗号两边紧挨着的是数字，跨不过去。
    private static func isSkippableNeighbor(_ character: Character) -> Bool {
        character.isWhitespace || fullWidthPunctuation[character] != nil
            || character == "(" || character == ")"
    }

    /// 跳过空白与标点后，`index` 左边最近的那个实字符。`nil` 表示这一侧到头了。
    ///
    /// **判据只看原文**：不看已经转换过的中间结果，否则判定会跟着改写顺序
    /// 走——同一段文本，度量（不改写）与转换器（边改边看）会得出两种答案。
    private static func precedingCharacter(
        in characters: [Character], before index: Int
    ) -> Character? {
        var cursor = index - 1
        while cursor >= 0, isSkippableNeighbor(characters[cursor]) { cursor -= 1 }
        return cursor >= 0 ? characters[cursor] : nil
    }

    /// 跳过空白与标点后，`index` 右边最近的那个实字符。
    private static func followingCharacter(
        in characters: [Character], after index: Int
    ) -> Character? {
        var cursor = index + 1
        while cursor < characters.count, isSkippableNeighbor(characters[cursor]) { cursor += 1 }
        return cursor < characters.count ? characters[cursor] : nil
    }
}
