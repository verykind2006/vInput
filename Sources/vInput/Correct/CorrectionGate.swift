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
    /// 替换前后读音必须一致，否则不是「改错字」而是「改写」。
    static func allows(_ edit: CorrectionEdit) -> Bool {
        Pinyin.toneless(edit.original) == Pinyin.toneless(edit.replacement)
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
