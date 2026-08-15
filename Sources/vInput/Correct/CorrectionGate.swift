import Foundation

/// 判定一条替换是否安全，并把放行的替换应用到文本上。
///
/// **这是唯一挡在「LLM 改写用户说的话」前面的东西。**
/// 它刻意位于 `Corrector` protocol 之外：M4 只做本地实现，云端排在
/// 其后，若把闸门写进某个实现内部，接云端时就得重写一遍——而两份
/// 闸门就会有两种松紧。
///
/// 全部是纯函数，不依赖模型，可穷举测试。
enum CorrectionGate {
    /// 短于此长度的原文片段不接受替换。
    ///
    /// 单字替换缺少消歧所需的上下文：模型说「的→得」，我们无从知道句子里
    /// 哪个「的」该改，而 `apply` 会替换全部出现处，把本来正确的字一并改坏
    /// （实测「我的书写得很好，他的笔也不错」→「我得书写得很好，他得笔也不错」）。
    /// 多字片段自带上下文，全局替换才是安全的。
    ///
    /// 取舍是明确的：漏掉真正的单字错误，换取不改坏一整句。设计文档的原则是
    /// 「改坏原本正确的内容，比漏改一个错字严重得多」。
    ///
    /// **计长的单位是音节，不是字符。** 阈值的本意是「要有足够的上下文来
    /// 消歧」：对中文，2 个字符 ≈ 2 个音节；但对拉丁文，`String.count` 毫无
    /// 意义——`AI` 是 2 个字符却只是一个词、约一个音节，用字符数量它就能
    /// 蒙混过关（实测 `[AI→爱]`、`[he→和]`、`[long→龙]` 全部被字符数放行，
    /// 而设计文档要求「英文单词、代码标识符一律保持原样」）。改用
    /// `Pinyin.toneless` 的分段数：拉丁词整体不含内部空格，天然只有 1 段；
    /// 中文按音节分段，`耀空气` 是 3 段。
    static let minimumOriginalLength = 2

    /// 替换前后读音必须一致，否则不是「改错字」而是「改写」。
    static func allows(_ edit: CorrectionEdit) -> Bool {
        // 计长用未归一化的原文：归一化会把「Use Effect」塌成一个 1 段的
        // 「UseEffect」，刚放行的这类替换又会被长度规则拦回去。
        guard syllableCount(edit.original) >= minimumOriginalLength else { return false }
        return reading(of: edit.original) == reading(of: edit.replacement)
    }

    /// 按 `Pinyin.toneless` 的空格分段数计长，而非 `String.count`。
    /// 见 `minimumOriginalLength` 的注释。
    private static func syllableCount(_ text: String) -> Int {
        Pinyin.toneless(text).split(separator: " ").count
    }

    /// 供闸门比对用的读音：先合并拉丁词，再转拼音。
    private static func reading(of text: String) -> String {
        Pinyin.toneless(joiningLatinWords(in: text))
    }

    /// 删掉「夹在两个拉丁字母之间」的空白。
    ///
    /// 主场景是给 AI 写 prompt，用户大量口述英文标识符，而 Whisper 惯于
    /// 把它们拆开并首字母大写：说 useEffect，写出来是「Use Effect」。
    /// 模型给的 `Use Effect→useEffect` 是对的，闸门却因为
    /// `use effect` ≠ `useeffect` 永远拒绝它——差的只是一个空格。
    ///
    /// **必须在转拼音之前做。** 转换之后两种空格长得一模一样：
    /// `耀空气`→`yao kong qi` 的空格是 ICU 插的音节分隔，
    /// `Use Effect`→`use effect` 的空格是原文里真实存在的词间空格，
    /// 事后无从分辨。放在原始字符串上判断，汉字之间压根没有空白可删，
    /// 于是「西安」(xi an) 与「先」(xian) 仍然判定为不同音——
    /// 这条放宽一步也不碰汉字。
    ///
    /// **代价要说清楚：闸门在拉丁段上只剩「字母序列一致」这一层保证。**
    /// 大小写本来就被 `Pinyin.toneless` 抹平，现在词边界也被抹平了，于是
    /// 反方向同样会被放行：原文含空格时，`Use Effect→USEEFFECT`、
    /// 乃至英文里意思完全不同的 `not able→notable` 都过得去。真机上出过
    /// 事故——某一版提示词让模型把本来正确的 `useEffect` 改成 `useeffect`。
    /// 挡住它的是两样东西，都不是这里的读音比对：一是长度规则（单个拉丁
    /// 词只有 1 段，够不着 `minimumOriginalLength`），二是提示词里那条
    /// 「不许改大小写，useEffect 就该一直是 useEffect」。
    /// 原文一旦被拆成两段以上，就只剩提示词兜着了。
    ///
    /// **代价已经在真机上兑现了一次，记在这里。** 端到端那句
    /// 「…我们说Claude CodeOpen AILLM这种识别度如何」本是「一个字都不能动」
    /// 的样本，改完之后模型的建议
    /// `…Claude CodeOpen AILLM→…Claude Code Open AI LLM` 被放行了：
    /// 往拉丁段里**插**空格，在归一化之后同样看不见。
    /// 合并方向是我们想要的，拆分方向是顺带来的，这条规则区分不了两者
    /// （只归一化箭头左边能区分，但那样一来右边带正常空格的建议
    /// ——如 `Use Effect Hook→useEffect hook`——又会被误拦）。
    private static func joiningLatinWords(in text: String) -> String {
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(characters.count)

        var index = 0
        while index < characters.count {
            guard characters[index].isWhitespace else {
                result.append(characters[index])
                index += 1
                continue
            }
            // 连续空白按一整段看待：「Use  Effect」两侧同样是拉丁字母。
            var end = index
            while end < characters.count, characters[end].isWhitespace { end += 1 }

            let isSandwiched = result.last.map(isLatinLetter) == true
                && end < characters.count && isLatinLetter(characters[end])
            if !isSandwiched {
                result.append(contentsOf: characters[index..<end])
            }
            index = end
        }
        return result
    }

    /// 只认 ASCII 字母。
    ///
    /// 刻意不含数字：字母删空格不改读音（`Use Effect` 与 `useEffect` 一个读法），
    /// 数字删空格会改——「26 3」读作「二十六、三」，「263」读作「二百六十三」，
    /// 那正是闸门该拦下的一类。也刻意不含带变音符的拉丁字母与其他字母文字，
    /// 代码标识符用不上，放进来只是多一处说不清的行为。
    private static func isLatinLetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    /// 应用替换的结果。`applied` 与 `rejected` 供日志使用——
    /// 闸门的松紧要能从日常使用的日志中判断，而不是靠专门安排测试。
    struct Outcome: Equatable {
        let text: String
        let applied: [CorrectionEdit]
        let rejected: [CorrectionEdit]
    }

    /// 把通过闸门的替换应用到文本上。
    static func apply(_ edits: [CorrectionEdit], to text: String) -> Outcome {
        var result = text
        var applied: [CorrectionEdit] = []
        var rejected: [CorrectionEdit] = []

        // 按原文长度降序：短片段先替换会破坏长片段的匹配，
        // 例如「据裤→据库」先跑，「数据裤」就再也匹配不上了。
        for edit in edits.sorted(by: { $0.original.count > $1.original.count }) {
            guard allows(edit) else {
                rejected.append(edit)
                continue
            }
            // 原文片段必须原样存在。模型偶尔会「引用」一个它自己改写过的
            // 片段，那种条目无从定位，宁可不改。
            guard result.contains(edit.original) else {
                rejected.append(edit)
                continue
            }
            // 全部出现处一起替换：同一个词在一句话里听错两次会错成同一个
            // 样子，只改第一处会留下一个自相矛盾的句子。
            result = result.replacingOccurrences(of: edit.original, with: edit.replacement)
            applied.append(edit)
        }

        return Outcome(text: result, applied: applied, rejected: rejected)
    }
}
