import Foundation

/// 汉字到拼音的转换，用于判定两段文本是否同音。
///
/// 用系统内置的 ICU 音译器，无第三方依赖，与繁简转换
/// （`ChineseScript`）使用同一套机制。
enum Pinyin {
    /// 转成小写、无声调的拼音，音节间以单个空格分隔。
    ///
    /// **忽略声调是有意的。** 同音错字绝大多数是声调差异
    /// （yào 耀 / yáo 遥），要求声调一致会把最该修的那一类全部拦掉。
    ///
    /// **拉丁字母与数字原样穿过。** 因此 `useEffect` 与 `useState`
    /// 靠同一套比对就能区分，不需要为非汉字另设一条规则——
    /// 少一条规则就少一处出错的地方。
    static func toneless(_ text: String) -> String {
        let buffer = NSMutableString(string: text) as CFMutableString
        // 汉字 → 带声调拼音
        CFStringTransform(buffer, nil, kCFStringTransformMandarinLatin, false)
        // 去掉声调符号（ā á ǎ à → a）
        CFStringTransform(buffer, nil, kCFStringTransformStripDiacritics, false)

        return (buffer as String)
            .lowercased()
            // 音译器在音节间插入空格，数量随上下文变化，统一压成单个空格。
            // 保留空格而非全部删除：删掉会让「西安」(xi an) 与「先」(xian)
            // 混为一谈，那是两个不同的词。
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
