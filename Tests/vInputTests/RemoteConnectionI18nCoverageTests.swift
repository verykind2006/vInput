import Foundation
import Testing

@testable import vInput

@Suite("遥控器文案 i18n 覆盖")
struct RemoteConnectionI18nCoverageTests {
    /// 上游产生但**不会**作为故障原因展示给用户的 key。
    ///
    /// 这些是「正在往连上走」的中间态，`RemoteConnectionState` 把它们
    /// 统一收敛成「搜索中…」，从不显示原文，因此不需要逐条翻译。
    ///
    /// 名单显式写死：新 key 出现时必须有人判断它属于哪一类，
    /// 而不是让它悄悄落进兜底文案。
    static let notShownAsFailure: Set<String> = [
        "common.status.stopped",
        "connection.status.searching",
        "connection.status.connecting",
        "connection.status.connected_to_device",
        "connection.status.initializing_voice",
        "connection.status.reconnecting",
    ]

    /// 扫描源码里所有 `LocalizedMessage("…")` 构造点，取出 key。
    ///
    /// 直接读源码而不是维护一份手抄清单：手抄清单会和上游代码脱节，
    /// 而这条路径上「脱节」的表现恰恰是用户看到一串英文 key。
    static func keysInSource() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // vInputTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
            .appendingPathComponent("Sources/vInput")

        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        let pattern = try NSRegularExpression(pattern: #"LocalizedMessage\(\s*"([^"]+)""#)
        var keys: Set<String> = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                if let r = Range(match.range(at: 1), in: text) {
                    keys.insert(String(text[r]))
                }
            }
        }
        return keys
    }

    /// 这条断言替代了「关掉 Mac 蓝牙看看文案对不对」那个手工验收项，
    /// 而且覆盖面严格更大：手工只能触发 13 个可达 key 中的 1 个。
    @Test("每个可达的 i18n key 都有中文映射")
    func everyReachableKeyIsTranslated() throws {
        let keys = try Self.keysInSource()
        #expect(!keys.isEmpty, "没扫到任何 key，正则或路径可能失效了")

        let untranslated = keys
            .subtracting(RemoteConnectionState.translations.keys)
            .subtracting(Self.notShownAsFailure)

        #expect(
            untranslated.isEmpty,
            """
            以下 i18n key 会退化成「\(RemoteConnectionState.untranslatedFallback)」：
            \(untranslated.sorted().joined(separator: "\n"))

            请在 RemoteConnectionState.translations 里补上中文，
            或——若它只是连接中间态、不作为故障展示——加进本测试的
            notShownAsFailure 名单。
            """
        )
    }

    /// 反向守卫：表里不该有源码中已不存在的 key。
    /// 上游删改 key 时，留着的死条目会掩盖真正缺失的翻译。
    @Test("映射表里没有源码中已不存在的 key")
    func noStaleTranslations() throws {
        let keys = try Self.keysInSource()
        let stale = Set(RemoteConnectionState.translations.keys).subtracting(keys)
        #expect(stale.isEmpty, "映射表存在失效条目：\(stale.sorted())")
    }

    @Test("译文不得泄漏原始 key")
    func translationsNeverLeakKeys() {
        for (key, chinese) in RemoteConnectionState.translations {
            #expect(!chinese.contains("."), "「\(chinese)」看起来仍是 key（\(key)）")
            #expect(
                chinese.range(of: "\\p{Han}", options: .regularExpression) != nil,
                "「\(chinese)」不含汉字（\(key)）"
            )
        }
    }

    @Test("未知 key 走兜底而不是直接显示")
    func unknownKeyFallsBack() {
        let label = RemoteConnectionState(
            bridgeState: .failed(LocalizedMessage("some.brand.new.upstream.key"))
        ).menuLabel

        #expect(label == "遥控器：\(RemoteConnectionState.untranslatedFallback)")
        #expect(!label.contains("some.brand.new"))
    }

    @Test("蓝牙关闭显示中文")
    func bluetoothOffShowsChinese() {
        let label = RemoteConnectionState(
            bridgeState: .bluetoothUnavailable(LocalizedMessage("bluetooth.status.off"))
        ).menuLabel

        #expect(label == "遥控器：蓝牙已关闭")
    }
}
