import Foundation

/// 「这条译文疑似被截断」的判据。
///
/// **存在的理由：撞 `maxTokens` 上限是静默的。** 表现是「返回半截译文、
/// 成功返回、不报错」，与取消半途而废（见 `MLXTranslator.translate` 里记的
/// 实测：8/8 都成功返回半截译文）**表现一模一样**，事后从结果里分不开。
/// 没有这条判据，一份「26 条全绿」的报告里可能有若干条只译了一半，
/// 而每条的指标——残留汉字 0、术语保留 1.0——全都好看。
///
/// 判据：去掉尾部空白与收尾的引号括号后，最后一个字符不是句末标点。
/// 基准集 26 条标准文本全部以「。」结尾，译文正常收尾就该落在句末标点上。
///
/// **它不是空判据**，两处证据：
/// 1. `TruncationSignalTests` 里拿真实观测到的半截译文验过（不是编的句子）；
/// 2. 把 `maxTokens` 调小到必然撞上限跑一轮，判据应当大面积亮起——
///    这是 `scripts/translate-sweep.sh --max-tokens` 存在的理由。
///
/// **它只是信号不是判决**：正常译文以引号或省略号收尾也可能被标出来，
/// 报告里因此同时打印译文原文，由人过一眼。宁可多报——漏报的那条会被当成
/// 好样本写进 Task 4 的结论。
///
/// ---
///
/// **2026-08-18 从测试目标搬进生产**（原先住在
/// `Tests/vInputTests/TranslationSweepTests.swift`）。搬家的理由是
/// `TranslationGate` 要拿它当截断的主信号，而**判据只能有一份**：本仓库
/// 因为「测试里复刻生产代码」栽过两次（`Bench.swift` 的 shim 漂了两回，
/// M5 期间删掉）。扫描装置现在读的就是这一份。
///
/// 判据本身一个字没改——它的分寸是第 0 步 306 次推理量出来的（只误报 1 次，
/// 数法见 `TranslationGate.check` 里那段注释），
/// 改一笔就得重新量。闸门那边只是给它加了个前置条件（「原文自己得有句末
/// 标点」），那是**用法**上的收紧，见 `TranslationGate.check`。
enum TruncationSignal {
    private static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    /// 可以合法地挂在句末标点右边的收尾字符。
    private static let closers: Set<Character> = [
        "\"", "”", "'", "’", ")", "）", "»", "」", "]", "》",
    ]

    static func looksTruncated(_ text: String) -> Bool {
        var chars = Array(text)
        while let last = chars.last, last.isWhitespace || closers.contains(last) {
            chars.removeLast()
        }
        // 空输出（或只剩引号括号）也算没说完——它同样是「成功返回但没东西」。
        guard let last = chars.last else { return true }
        return !terminators.contains(last)
    }
}
