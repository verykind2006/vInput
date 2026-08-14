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
}
