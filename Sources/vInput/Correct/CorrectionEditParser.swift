import Foundation

/// 把模型输出的替换清单解析成结构化条目。
///
/// 格式是一行一条 `原文→替换`。选这个格式而非 JSON：4B 量级的模型
/// 产出合法 JSON 的可靠性不足，而这个格式几乎不可能写错。
///
/// **格式本身就是第一道保险**——模型只能逐词替换，结构上无法重写整句。
enum CorrectionEditParser {
    /// 认这几种箭头。模型在中英文语境下会写出不同变体，
    /// 与其要求它精确，不如让解析宽容：宽容的代价是多认几种写法，
    /// 严格的代价是整次校正作废。
    private static let arrows = ["→", "=>", "->", "⇒"]

    /// 行首的列表符号与标签前缀。
    ///
    /// 4B 模型输出带项目符号是常态，而提示词里的示例又容易被回显。
    /// 与其要求模型格式精确，不如把这些装饰剥掉——宽容的代价是多认
    /// 几种写法，严格的代价是整次校正静默作废。
    private static let leadingDecorations = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*•·]|\d+[.)]|输出\s*[:：])\s*"#
    )

    static func parse(_ output: String) -> [CorrectionEdit] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            parseLine(String(line))
        }
    }

    private static func parseLine(_ rawLine: String) -> CorrectionEdit? {
        let line = leadingDecorations.stringByReplacingMatches(
            in: rawLine,
            range: NSRange(rawLine.startIndex..., in: rawLine),
            withTemplate: ""
        )

        guard let arrow = arrows.first(where: { line.contains($0) }) else { return nil }

        let parts = line.components(separatedBy: arrow)
        // 多于两段说明一行里有多个箭头，切分点无法确定。整行丢弃：
        // 猜错的代价是改错用户的话，不猜的代价只是少改一处。
        guard parts.count == 2 else { return nil }

        let original = undecorate(parts[0])
        let replacement = undecorate(parts[1])

        guard !original.isEmpty, !replacement.isEmpty, original != replacement else {
            return nil
        }
        return CorrectionEdit(original: original, replacement: replacement)
    }

    /// 剥掉包裹用的引号与行尾句点。
    ///
    /// **只动两端，不动内部**：「三点一四→3.14」里的小数点必须留着。
    /// 过度剥离会悄悄改坏用户的文字，比少改一处严重得多。
    private static func undecorate(_ token: String) -> String {
        var result = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: Set<Character> = ["「", "」", "『", "』", "\"", "\u{201C}", "\u{201D}", "'"]
        while let first = result.first, quotes.contains(first) { result.removeFirst() }
        while let last = result.last, quotes.contains(last) { result.removeLast() }
        while let last = result.last, last == "。" || last == "." || last == "；" || last == ";" {
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
