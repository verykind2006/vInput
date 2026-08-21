import Foundation
import Testing

@testable import vInput

/// 下载源偏好：写的人（面板）和读的人（向导）必须用同一个 key。
struct DownloadSourcePreferenceTests {
    private func makeDefaults() -> UserDefaults {
        let name = "download-source-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// 默认是「自动」。写死任何一个源都会在半年内变成错的那个
    /// （用户 9 月去西班牙，官方源与镜像的快慢会掉个个儿）。
    @Test func defaultsToAutomatic() {
        #expect(DownloadSourcePreference(defaults: makeDefaults()).forced == nil)
    }

    @Test func roundTripsBothSources() {
        let defaults = makeDefaults()
        let preference = DownloadSourcePreference(defaults: defaults)
        preference.forced = .mirror
        #expect(DownloadSourcePreference(defaults: defaults).forced == .mirror)
        preference.forced = .official
        #expect(DownloadSourcePreference(defaults: defaults).forced == .official)
    }

    /// 选回「自动」必须真的把那条记录**抹掉**，而不是留个空值。
    @Test func clearingGoesBackToAutomatic() {
        let defaults = makeDefaults()
        let preference = DownloadSourcePreference(defaults: defaults)
        preference.forced = .mirror
        preference.forced = nil
        #expect(preference.forced == nil)
        #expect(defaults.object(forKey: DownloadSourcePreference.forcedKey) == nil)
    }

    /// 存的是 rawValue 字符串；读不出合法值时退回「自动」。
    ///
    /// 撞得上：旧版本残留、手改过 plist、将来改了 case 名。失败方向必须是
    /// 「自动」——自动在任何网络下都能工作，而崩溃或硬选一个都不行。
    @Test func unknownValueFallsBackToAutomatic() {
        let defaults = makeDefaults()
        defaults.set("carrier-pigeon", forKey: DownloadSourcePreference.forcedKey)
        #expect(DownloadSourcePreference(defaults: defaults).forced == nil)
    }

    // MARK: - 上次实际用的那个源

    /// 没下载过任何东西时是 nil，此时端点按官方源算。
    @Test func resolvedStartsEmpty() {
        #expect(DownloadSourcePreference(defaults: makeDefaults()).resolved == nil)
    }

    /// 存得住、读得回。**这一条决定重启之后 tokenizer 走哪个源**：
    /// 不存的话，一台靠镜像装成的机器重启后会去官方源取 tokenizer 并挂住。
    @Test func resolvedRoundTrips() {
        let defaults = makeDefaults()
        DownloadSourcePreference(defaults: defaults).resolved = .mirror
        #expect(DownloadSourcePreference(defaults: defaults).resolved == .mirror)
    }

    /// 与 `forced` 是**两个独立的格子**。
    ///
    /// 写在同一个 key 上的话，「自动探到镜像」会把用户的「自动」这个选择
    /// 改写成「强制镜像」——他到西班牙之后就再也探不到更快的官方源了，
    /// 而面板上的勾也跟着从「自动」跳到「强制国内镜像」。
    @Test func resolvedDoesNotDisturbForced() {
        let defaults = makeDefaults()
        let preference = DownloadSourcePreference(defaults: defaults)
        preference.forced = nil
        preference.resolved = .mirror
        #expect(preference.forced == nil)
        #expect(preference.resolved == .mirror)

        preference.forced = .official
        #expect(preference.resolved == .mirror)
    }

    /// 读不出合法值时退回 nil（失败方向＝按官方源算，与 HubApi 默认一致）。
    @Test func unknownResolvedValueFallsBackToNil() {
        let defaults = makeDefaults()
        defaults.set("carrier-pigeon", forKey: DownloadSourcePreference.resolvedKey)
        #expect(DownloadSourcePreference(defaults: defaults).resolved == nil)
    }

    /// 存的确实是 rawValue，不是序号。
    ///
    /// 序号会在「将来加第三个源」时错位：用户存的 1（镜像）会变成别的东西，
    /// 而这类错位没有任何征兆。
    @Test func storesRawValueNotAnIndex() {
        let defaults = makeDefaults()
        DownloadSourcePreference(defaults: defaults).forced = .mirror
        #expect(defaults.string(forKey: DownloadSourcePreference.forcedKey) == "mirror")
    }
}

/// **这个 key 的字面量在整个 `Sources/` 里只许出现一次。**
///
/// 面板写、向导读，中间隔着两个文件。两边各写一遍字面量的话，拼错一个字母的
/// 表现是**这个设置什么都不做**——用户点了「强制国内镜像」，下一次下载照样
/// 并发探测，而界面上打着勾。没有编译错误，也没有任何别的测试会红。
///
/// 所以这一条不扫「某一行在不在」，而是数字面量的出现次数。
@Suite("下载源设置的 key 全仓只有一处")
struct DownloadSourceKeyTests {
    @Test func theKeyLiteralAppearsExactlyOnceInSources() throws {
        try Self.expectKeyIsWrittenOnce(
            DownloadSourcePreference.forcedKey, in: "DownloadSourcePreference.swift")
    }

    /// 「上次实际用的源」那个 key 同样只许有一处。
    ///
    /// 它比 `forcedKey` 更难发现拼错：那一条至少还有个勾能看，而这一条
    /// 拼错之后的表现是「重启之后取 tokenizer 又去官方源了」——只在国内、
    /// 只在第五步、只有一次。
    @Test func theResolvedKeyLiteralAppearsExactlyOnceInSources() throws {
        try Self.expectKeyIsWrittenOnce(
            DownloadSourcePreference.resolvedKey, in: "DownloadSourcePreference.swift")
    }

    /// 「导入的模型目录」那个 key 同样只许有一处。拼错的表现是
    /// 「导入的模型下次启动就没了」——正是它存在要修的那件事本身。
    @Test func theImportedModelsKeyLiteralAppearsExactlyOnceInSources() throws {
        try Self.expectKeyIsWrittenOnce(
            ImportedModelPreference.foldersKey, in: "ImportedModelPreference.swift")
    }

    private static func expectKeyIsWrittenOnce(_ key: String, in fileName: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/vInput")

        let literal = "\"\(key)\""
        var hits: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // 先去掉注释再数：`DownloadSourcePreference` 的类型注释里必须能写出
            // 这个 key 长什么样（那段注释解释的正是「为什么只许有一处」），
            // 而整份 `contains` 分不清注释和代码——不去掉的话，这条守卫会因为
            // 一句解释自己的注释而永远红着，而为了让它绿去删注释是更坏的结果。
            let count = MenuPanelViewWiringTests.codeOnly(source)
                .components(separatedBy: literal).count - 1
            for _ in 0..<count { hits.append(url.lastPathComponent) }
        }

        let onlyOnce = hits == [fileName]
        #expect(
            onlyOnce,
            """
            key「\(key)」的字面量出现在：\(hits)。
            它只许写在 \(fileName) 一处——两边各写一遍的话，
            拼错一个字母的表现是「用户点了、勾也在，行为一点没变」，
            而没有任何编译错误或别的测试会红。
            """
        )
    }

    /// 向导那侧确实是**经由这个类型**去读的，不是自己 `UserDefaults` 一把。
    ///
    /// 上面那条数字面量的测试有个漏洞：向导那边写 `UserDefaults.standard
    /// .string(forKey: DownloadSourcePreference.forcedKey)` 也能过，
    /// 而那样等于把「读不出合法值退回自动」那段逻辑绕开。
    @Test func wizardReadsThroughThePreferenceType() throws {
        let source = try MenuPanelViewWiringTests.source(
            "Sources/vInput/Onboarding/OnboardingWindow.swift")
        let code = MenuPanelViewWiringTests.codeOnly(source)
        let readsPreference = code.contains("DownloadSourcePreference().forced")
        #expect(
            readsPreference,
            """
            OnboardingWindow.swift 没有经由 DownloadSourcePreference 读下载源。
            这是面板那个设置唯一的消费方，绕过去等于设置失效。
            """
        )
        let passesForced = code.contains("forced: forced")
        #expect(
            passesForced,
            """
            DownloadSource.choose 的 forced: 参数不再是用户设置的那个值
            （多半又写回了 nil）——「强制官方源」会变成一个纯装饰的勾。
            """
        )
    }
}
