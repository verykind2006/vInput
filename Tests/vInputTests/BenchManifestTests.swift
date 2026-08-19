import Foundation
import Testing

@testable import vInput

@Suite("基准集清单")
struct BenchManifestTests {
    /// 仓库自带的 manifest 必须能被解析——它是基准集的定义，
    /// 解析不了就等于基准集不存在。
    @Test("仓库内的 manifest 可解析")
    func repositoryManifestLoads() throws {
        let manifest = try BenchManifest.loadFromRepository()
        #expect(!manifest.entries.isEmpty)
    }

    /// 四个录音类别都要有条目，否则覆盖面就有缺口，而缺口不会自己叫。
    ///
    /// 遍历 `BenchCategory.recorded` 而不是 `allCases`：`digits` 那一类是
    /// 纯文本语料，住在 `Bench/translate-digits.json`、没有录音
    /// （理由见 `BenchCategory.digits`）。下面 `manifestHasOnlyRecordedCategories`
    /// 补上另一半——manifest 里不许混进不需要录音的类别，
    /// 否则这条断言就成了「挑自己能过的类别来查」。
    @Test("四个录音类别都有条目")
    func allRecordedCategoriesPresent() throws {
        let manifest = try BenchManifest.loadFromRepository()
        for category in BenchCategory.recorded {
            let count = manifest.entries.filter { $0.category == category }.count
            #expect(count >= 5, "\(category.rawValue) 只有 \(count) 条，至少要 5 条")
        }
    }

    /// manifest 里的每一条都要有对应录音，所以它的类别必须都在 `recorded` 里。
    ///
    /// 少了这一条，上面那条断言可以靠「把新类别排除在 recorded 之外」
    /// 永远通过，而 manifest 里那些没有录音的条目会在
    /// `BenchRunnerTests` 里变成一片「未录音，跳过」。
    @Test("manifest 里只有需要录音的类别")
    func manifestHasOnlyRecordedCategories() throws {
        let manifest = try BenchManifest.loadFromRepository()
        for entry in manifest.entries {
            #expect(
                BenchCategory.recorded.contains(entry.category),
                "\(entry.id) 的类别 \(entry.category.rawValue) 不需要录音，不该进 manifest.json")
        }
    }

    /// ID 用作文件名，重复会让两条录音互相覆盖。
    @Test("条目 ID 不重复")
    func idsAreUnique() throws {
        let manifest = try BenchManifest.loadFromRepository()
        let ids = manifest.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// 标准文本必须覆盖 M4 真机出现过的错误——它们是已知会失败的样本。
    @Test("包含真机出现过的错误样本")
    func coversKnownRealWorldFailures() throws {
        let manifest = try BenchManifest.loadFromRepository()
        let allText = manifest.entries.map(\.text).joined()
        for token in ["写代码", "句子", "上线", "Claude Code", "GitHub Actions"] {
            #expect(allText.contains(token), "标准文本里没有 \(token)")
        }
    }

    @Test("往返编解码不丢信息")
    func roundTrips() throws {
        let original = BenchManifest(entries: [
            BenchEntry(id: "tech-01", text: "把这个改成 useEffect", category: .technical)
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BenchManifest.self, from: data)
        #expect(decoded == original)
    }
}
