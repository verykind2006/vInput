import Foundation

/// 基准集的类别。
///
/// 四类各有明确职责，缺一类就有一块覆盖不到，而覆盖缺口不会自己叫。
enum BenchCategory: String, Codable, CaseIterable, Sendable {
    /// 技术术语与代码标识符。用户主场景，也是 M4 收尾时错得最惨的一类。
    case technical
    /// 长句与标点。连说 15–30 秒不停顿，守住 initial prompt 已取得的改善。
    case punctuation
    /// 同音陷阱。直接考验校正层，也是判断「换模型/改 prompt 有没有用」的主依据。
    case homophone
    /// 口语与日常表达。验证「不该改的不要改」——**这一类的改动数是硬约束**。
    case colloquial
    /// 数字、金额、日期、型号、单号。**只喂翻译层，没有录音。**
    ///
    /// 单开一类而不是塞进 `colloquial`：报告里逐条打印类别名，混进去会让
    /// 「这一批考的是数字」这件事在报告里看不出来。
    ///
    /// 存在的理由是 `manifest.json` 那 26 条里**一个 ASCII 数字都没有**
    /// （2026-08-18 实地数过），于是 `TranslationMetrics.lostDigits` 的分母
    /// 恒为 0，提示词里「Keep all numbers exactly as they appear」这条规则
    /// 本基准集根本考不到。而数字译错是报价场景里最贵的错。
    ///
    /// **不进 `manifest.json`**：那份清单的每一条都要有 `Bench/audio/<id>.wav`
    /// （`BenchManifest.audioURL(for:)` 就是这么假设的），加进去会让录音界面
    /// 凭空多出十几条录不了的条目。这一类住在
    /// `Bench/translate-digits.json`，由 `--corpus` 指定。
    case digits

    /// 需要录音的类别。`manifest.json` 只装这四类。
    ///
    /// 单列出来是为了让「哪些类别要有录音」这件事有一个可断言的定义，
    /// 而不是散在测试里的一串字面量——加了新类别却忘了录音，
    /// `BenchManifestTests` 会响。
    static let recorded: [BenchCategory] = [.technical, .punctuation, .homophone, .colloquial]
}

/// 基准集的一条：一段标准文本，对应一段录音。
struct BenchEntry: Codable, Equatable, Sendable {
    /// 同时用作录音文件名（`Bench/audio/<id>.wav`），因此必须唯一。
    let id: String
    /// 标准文本。录制时提示用户照读，对照时作为参考答案。
    let text: String
    let category: BenchCategory
}

struct BenchManifest: Codable, Equatable, Sendable {
    let entries: [BenchEntry]

    /// 仓库内的基准集目录。
    ///
    /// 用 `#filePath` 回溯仓库根，不依赖进程的当前工作目录——`swift test`
    /// 与 `xcodebuild test` 下的 cwd 并不相同（M4 期间踩过）。
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Bench
            .deletingLastPathComponent()   // vInput
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // 仓库根
    }

    static var manifestURL: URL {
        repositoryRoot.appendingPathComponent("Bench/manifest.json")
    }

    static var audioDirectory: URL {
        repositoryRoot.appendingPathComponent("Bench/audio", isDirectory: true)
    }

    static func loadFromRepository() throws -> BenchManifest {
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(BenchManifest.self, from: data)
    }

    /// 某条目的录音路径。文件可能不存在（还没录）。
    static func audioURL(for entry: BenchEntry) -> URL {
        audioDirectory.appendingPathComponent("\(entry.id).wav")
    }
}
