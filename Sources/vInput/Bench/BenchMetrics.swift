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

    /// 中文语境里被写成半角的标点个数。越小越好，标准文本上应当是 0。
    ///
    /// **补这一格是因为前面两格合起来正好把这件事屏蔽掉了。** 基准集 23 条
    /// 标准文本里 20 个逗号全是全角，转写输出全是半角，而
    /// `characterErrorRate` **刻意排除标点**（「一次标点改善会掩盖一次真实
    /// 的漏字」），`punctuationCount` 只数个数不分全半角——两个数都纹丝
    /// 不动。这个不匹配从第一天就在基准集里，直到 2026-08-17 用户自己看
    /// 输出才发现。
    ///
    /// 不补这一格，M6 ⑤ 修完之后它会再次无声退化，而这已经是同一个盲区
    /// 的第三次了。
    ///
    /// **这条判据刻意不共用转换器的函数，而且比它窄。**
    ///
    /// 最初的实现是 `ChineseScript.fullWidthConversions(in:).count`——与
    /// `TranscriptCleaner.normalizePunctuation` 用同一个函数。当时的理由是
    /// 「两把尺子不一样会各错各的」，理由本身没错，但结果更糟：**度量跑在
    /// 转换之后，凡是这个函数认得出的半角标点都已经被同一个函数转掉了，
    /// 指标必然读 0**。基准集 26 条全是「半角=0/0」，那不是测量结果，
    /// 是恒等式。
    ///
    /// 代价还是双向的：既量不出误伤（规则太激进），也量不出漏转（规则太
    /// 保守）——**规则越保守，指标越漂亮**。这是 M5「把答案抄进被测系统」
    /// 那个错误的同形缩小版，独立验收 2026-08-17 指出。
    ///
    /// 现在的判据：**半角 `,;:?!` 的左右紧邻（跳过空格）都是汉字；
    /// 位于文本末尾时只要求左邻是汉字。**
    ///
    /// 末尾那一档不能省——它恰是最常见的真实形态。用户 2026-08-17 的日志
    /// 里就是「…把 M8 的分场景优化改成**?**」：句号是全角、句末问号是半角。
    /// 要求右邻存在的话，这一类一个都数不到。开头那一档不补：文本以半角
    /// 逗号起头本来就少见，且没有左邻就没有「中文语境」可言。
    ///
    /// 它比转换器窄——转换器是「任一侧是中文语境」（还包括 CJK 标点、
    /// 全角形式），这里要求「两侧都是汉字」。窄的好处是**凡它报出来的都
    /// 无疑是错的**：两个汉字中间夹半角逗号，没有任何正当解释。千分位、
    /// `foo(a, b)`、`3:30`、URL 全部自动排除，不需要特例。
    ///
    /// 于是读 0 是有意义的（没有无争议的漏网），读非 0 就是转换器真漏了。
    /// 判据是独立写的，转换器那边的规则被改窄、改坏、或被括号那套三条件
    /// 逻辑连累时，这里能独立发现。
    ///
    /// **它只能发现漏转，发现不了误伤。** 误伤（该留半角的被转成全角）
    /// 需要另一把尺子，目前没有——已知的两条误伤
    /// （`int x = 1; 然后编译`、`fix: 中文`）靠钉死的测试守着。
    static func halfWidthPunctuationInChinese(_ text: String) -> Int {
        let chars = Array(text)
        let targets: Set<Character> = [",", ";", ":", "?", "!"]

        func isHan(_ c: Character) -> Bool {
            guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else {
                return false
            }
            // CJK 统一表意文字基本区。扩展区在听写场景里见不到，
            // 漏掉它们只会让这个指标更保守，不会误报。
            return (0x4E00...0x9FFF).contains(scalar.value)
        }

        /// 跳过空白找相邻的实字符。
        func neighbor(from index: Int, step: Int) -> Character? {
            var i = index + step
            while chars.indices.contains(i) {
                if !chars[i].isWhitespace { return chars[i] }
                i += step
            }
            return nil
        }

        return chars.indices.filter { i in
            guard targets.contains(chars[i]) else { return false }
            guard let left = neighbor(from: i, step: -1), isHan(left) else { return false }
            // 右邻不存在＝位于文本末尾，只看左邻。见上面注释里那条真机例子。
            guard let right = neighbor(from: i, step: 1) else { return true }
            return isHan(right)
        }.count
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
