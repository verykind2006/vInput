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
        guard syllableCount(edit.original) >= minimumOriginalLength else { return false }
        return Pinyin.toneless(edit.original) == Pinyin.toneless(edit.replacement)
    }

    /// 按 `Pinyin.toneless` 的空格分段数计长，而非 `String.count`。
    /// 见 `minimumOriginalLength` 的注释。
    private static func syllableCount(_ text: String) -> Int {
        Pinyin.toneless(text).split(separator: " ").count
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
