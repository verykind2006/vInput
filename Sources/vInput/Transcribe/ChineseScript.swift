import Foundation

/// 中文字形规范化。
///
/// Whisper 的中文训练数据里繁体占比很高，即便指定 `language: "zh"`
/// 也经常输出繁体（Task 2 实测：「幫我把這個…裏…測試」）。产品需要简体，
/// 因此在转写层出口统一转换一次。
///
/// 使用系统内置的 ICU 音译器，无需任何第三方依赖或词表文件。
/// 它只改字形，不改用词——同音错字（如「函数」被听成「寒暑」）
/// 属于识别错误，由模型选型或 M4 的润色层负责。
enum ChineseScript {
    /// 把文本中的繁体字转成简体。
    ///
    /// 已是简体的字符、拉丁字母、数字与标点均原样保留。
    static func toSimplified(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        // "Hant-Hans"：ICU 的繁体→简体音译器 ID。
        CFStringTransform(mutable as CFMutableString, nil, "Hant-Hans" as CFString, false)
        return mutable as String
    }

    /// 这个字符是否处在「中文语境」里。
    ///
    /// 用途是判断一个半角标点该不该转全角（`TranscriptCleaner`）以及该不该
    /// 被算作退化（`BenchMetrics`）。两处必须用同一把尺子，否则会出现
    /// 「转换器改了、度量看不见」或者反过来的情形——而 M6 ⑤ 的教训正是
    /// 度量与实际输出对不上就等于没有度量。
    ///
    /// **判据是字符本身，不是整段文本的语言。** 整段判定在中英混排上必然
    /// 出错：`他说 "Hello, world" 然后走了` 整段是中文，可那个逗号是英文
    /// 短语内部的。逐字符看邻居才分得开。
    ///
    /// 收进来的区段：
    /// - 汉字（含扩展 A/B 与兼容区）
    /// - CJK 符号与标点 `U+3000–U+303F`：、。「」《》…
    /// - 全角形式 `U+FF00–U+FFEF`：，？！：；（）以及全角字母数字
    ///
    /// **刻意不收 `U+2018–U+201D` 那几个弯引号**：英文同样在用它们，
    /// 收进来会把 `he said “Hello, world”` 里的逗号判成中文语境。
    static func isChineseContext(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first else { return false }
        return switch scalar.value {
        case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            true
        default:
            false
        }
    }

    /// 半角标点 → 全角标点。
    ///
    /// 只收中文里确有对应写法的这几个。`"` `'` 不在其中——中文的引号是
    /// 「」或“”，一对一映射说不清左右，猜错比不改更糟。
    static let fullWidthPunctuation: [Character: Character] = [
        ",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；",
    ]
}
