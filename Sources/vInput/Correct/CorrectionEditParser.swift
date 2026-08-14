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

    static func parse(_ output: String) -> [CorrectionEdit] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            parseLine(String(line))
        }
    }

    private static func parseLine(_ line: String) -> CorrectionEdit? {
        guard let arrow = arrows.first(where: { line.contains($0) }) else { return nil }

        let parts = line.components(separatedBy: arrow)
        // 多于两段说明一行里有多个箭头，切分点无法确定。整行丢弃：
        // 猜错的代价是改错用户的话，不猜的代价只是少改一处。
        guard parts.count == 2 else { return nil }

        let original = parts[0].trimmingCharacters(in: .whitespaces)
        let replacement = parts[1].trimmingCharacters(in: .whitespaces)

        guard !original.isEmpty, !replacement.isEmpty, original != replacement else {
            return nil
        }
        return CorrectionEdit(original: original, replacement: replacement)
    }
}
