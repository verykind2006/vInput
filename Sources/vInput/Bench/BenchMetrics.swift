import Foundation

/// 基准集的度量。全部是纯函数，可穷举测试。
///
/// **三层指标缺一不可**：总体的字错误率看全局，分类指标定位「改动影响了
/// 哪一类」，逐段 diff 让人看得见具体错在哪。
///
/// 分类指标不能被总体指标取代：一次改动可能让字错误率微降却把技术词全毁掉。
/// M4 期间就出现过——某个 prompt 变体在多数音频上标点持平，却把两段的标点
/// 砍掉一半。只看一个数会漏掉。
enum BenchMetrics {
    /// 计入字错误率的字符：汉字、字母、数字。
    ///
    /// **标点刻意排除**，由 `punctuationCount` 独立衡量。混在一起的话，
    /// 一次标点改善会掩盖一次真实的漏字。
    static func significantCharacters(_ text: String) -> [Character] {
        text.filter { $0.isLetter || $0.isNumber }
    }

    /// 字错误率：编辑距离 / 参考文本长度。
    ///
    /// 参考文本为空时返回 0（无从判断），假设为空时返回 1（全错）。
    static func characterErrorRate(reference: String, hypothesis: String) -> Double {
        let ref = significantCharacters(reference)
        let hyp = significantCharacters(hypothesis)
        guard !ref.isEmpty else { return 0 }
        return Double(editDistance(ref, hyp)) / Double(ref.count)
    }

    /// Levenshtein 距离。滚动数组实现，只留两行，长文本也不会撑爆内存。
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,        // 删除
                    current[j - 1] + 1,     // 插入
                    previous[j - 1] + cost  // 替换
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// 中英文标点的个数。
    static func punctuationCount(_ text: String) -> Int {
        text.filter { $0.isPunctuation || $0.isSymbol }.count
    }

    /// 从标准文本里抽出技术词：连续的拉丁字母序列（可含空格连接的多词）。
    ///
    /// 抽而不是手工列表：标准文本改了，词表自动跟着改，不会漏。
    static func technicalTerms(in text: String) -> [String] {
        let pattern = #"[A-Za-z][A-Za-z0-9]*(?: [A-Z][A-Za-z0-9]*)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// 技术词的命中率。**大小写严格比对**——`github actions` 不算命中，
    /// M4 真机上大小写丢失正是主要失败形态之一。
    static func termHitRate(terms: [String], in text: String) -> Double {
        guard !terms.isEmpty else { return 1.0 }
        let hits = terms.filter { text.contains($0) }.count
        return Double(hits) / Double(terms.count)
    }
}
