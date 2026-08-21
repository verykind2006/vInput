import Foundation
import Testing
@testable import vInput

/// 卸载：删什么、多大、说什么。
///
/// **执行部分一律走假实现**——测试里绝不真的去删家目录里的东西。
@MainActor
struct UninstallPlanTests {
    @Test func listsEveryPlaceWeWroteTo() {
        let items = UninstallPlan.items(home: "/Users/x")
        let paths = items.map(\.path)
        #expect(paths.contains("/Users/x/Library/Application Support/vInput"))
        #expect(paths.contains("/Users/x/Library/Logs/vInput"))
        #expect(items.count == 2)
    }

    /// 偏好与 Keychain 不是文件路径，单列——漏了它们，卸载后重装会
    /// 「记得」上次的设置，用户以为没删干净。
    @Test func nonFileItemsAreListedSeparately() {
        #expect(UninstallPlan.defaultsSuite == "com.vinput.app")
    }

    /// **`defaultsSuite` 必须真的等于 app 的 bundle id。**
    ///
    /// `SystemUninstaller.clearDefaults` 用它去 `removePersistentDomain`——
    /// 对不上就是「卸载完偏好还在」，而用户重装后会发现设置全都记得，
    /// 以为没删干净。此前只有一行注释挡着，没有任何东西会红。
    ///
    /// 判据取自 `Resources/Info.plist` 本身，不是再抄一遍字面量：抄一遍的话
    /// 改了 bundle id 两处一起改，这条测试就白写了。
    @Test func defaultsSuiteMatchesTheRealBundleIdentifier() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // vInputTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
        let plist = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let parsed = try PropertyListSerialization.propertyList(
            from: plist, format: nil) as? [String: Any]
        let bundleID = parsed?["CFBundleIdentifier"] as? String
        let matches = bundleID == UninstallPlan.defaultsSuite
        #expect(
            matches,
            """
            UninstallPlan.defaultsSuite（\(UninstallPlan.defaultsSuite)）与
            Info.plist 里的 CFBundleIdentifier（\(bundleID ?? "读不到")）对不上。
            卸载会清一个不存在的偏好域——用户重装后发现设置全都还在。
            """
        )
    }

    /// 体积是扫出来的，不是写死的数字。
    @Test func totalSizeSumsMeasuredBytes() {
        let bytes = UninstallPlan.totalBytes(
            items: UninstallPlan.items(home: "/Users/x"),
            sizeOf: { path in path.hasSuffix("Application Support/vInput") ? 1_610_612_736 : 4_096 }
        )
        #expect(bytes == 1_610_616_832)
    }

    /// 人类可读的体积：要出现单位（GB / KB），不能是一串裸字节数。
    ///
    /// 不断言具体数值（如「1.5」）：`ByteCountFormatter` 按十进制换算，
    /// 1_610_612_736 字节（1.5 GiB）显示成「1.61 GB」而非「1.5 GB」——这是
    /// 换算进制的差异，不是本机 locale 的巧合，断言具体小数位没有意义。
    @Test func formatsSizeForHumans() {
        let gb = UninstallPlan.humanSize(1_610_612_736)
        let gbLooksRight = gb.contains("GB") && !gb.contains("1610612736")
        #expect(gbLooksRight)
        let kb = UninstallPlan.humanSize(4_096)
        let kbLooksRight = kb.contains("KB") && !kb.contains("4096")
        #expect(kbLooksRight)
    }

    /// **确认文案必须说清两件我们做不到的事**，不许假装做到了：
    /// 应用删不掉自己；系统设置里的授权条目也不归我们管。
    /// **小体积不许冒出英文词。** `ByteCountFormatter` 在 1KB 以下会退回
    /// 「Zero KB」「500 bytes」，而这串东西会被插进一句全中文的确认文案里。
    /// 撞上它的场景很实在：模型还没下载、只有日志的那种近乎空的安装。
    @Test func smallSizesNeverLeakEnglishWords() {
        for bytes: Int64 in [0, 1, 500, 999] {
            let text = UninstallPlan.humanSize(bytes)
            let leaks = text.lowercased().contains("byte") || text.lowercased().contains("zero")
            #expect(!leaks, "humanSize(\(bytes)) 冒出了英文词：\(text)")
        }
    }

    @Test func confirmationTellsTheTruthAboutWhatWeCannotDo() {
        let copy = UninstallPlan.confirmation(sizeText: "1.5 GB")
        #expect(copy.message.contains("1.5 GB"))
        #expect(copy.message.contains("废纸篓"))
        #expect(copy.message.contains("系统设置"))
    }

    /// 执行顺序：先删文件、再清偏好，最后才退出。
    /// 反过来的话（先退出）后面几步根本不会发生。
    @Test func executesFilesThenDefaultsThenQuits() async {
        let recorder = RecordingUninstaller()
        let failed = await UninstallPlan.execute(
            items: UninstallPlan.items(home: "/Users/x"), using: recorder)
        #expect(failed.isEmpty)
        #expect(recorder.log.first?.hasPrefix("remove:") == true)
        #expect(recorder.log.contains("defaults"))
        #expect(recorder.log.contains("keychain"))
        #expect(recorder.log.last == "quit")
    }

    /// **删不掉东西就不许退出。**
    ///
    /// 退出之后再说什么都晚了：用户看到应用干净地关掉，以为删完了。而日志
    /// 帮不上忙——日志目录本身就在待删清单里（`items[1]`），
    /// `AppLogger` 只在 init 时建目录，删掉之后后面每一行都静默丢失。
    /// 所以「有失败」这件事只能靠**还活着的界面**说出来。
    @Test func partialFailureKeepsTheAppAlive() async {
        let recorder = RecordingUninstaller()
        let logs = UninstallPlan.items(home: "/Users/x")[1]
        recorder.failing = [logs.path]

        let failed = await UninstallPlan.execute(
            items: UninstallPlan.items(home: "/Users/x"), using: recorder)

        #expect(failed == [logs], "没能删掉的那一项没有被回报上来。")
        let quit = recorder.log.contains("quit")
        #expect(!quit, "有东西没删掉却还是退出了——用户会以为卸载成功了。")
        // 剩下的步骤仍然要走完：少删一样，不等于剩下的都不删了。
        #expect(recorder.log.contains("defaults"))
        #expect(recorder.log.contains("keychain"))
    }

    /// 全删干净时不弹任何提示（`failureNotice` 返回 nil）。
    @Test func noNoticeWhenEverythingWasDeleted() {
        #expect(UninstallPlan.failureNotice(failed: []) == nil)
    }

    /// 提示必须点名**是哪一样、在哪**：用户此刻唯一能做的就是自己去删，
    /// 而「有一样没删掉」这种话帮不了他。两个目录都在 `~/Library` 下，
    /// Finder 默认不显示，所以路径也得给全。
    @Test func failureNoticeNamesTheItemAndItsPath() throws {
        let logs = UninstallPlan.items(home: "/Users/x")[1]
        let notice = try #require(UninstallPlan.failureNotice(failed: [logs]))
        #expect(notice.message.contains(logs.label))
        #expect(notice.message.contains(logs.path))
        // 还要说清「所以我没退出」，否则用户不知道现在是什么状态。
        #expect(notice.message.contains("没有退出"))
    }
}

@MainActor
private final class RecordingUninstaller: Uninstalling {
    var log: [String] = []
    /// 这些路径删不掉（模拟权限不足 / 正被占用）。
    var failing: Set<String> = []
    func removeItem(at path: String) -> Bool {
        log.append("remove:\(path)")
        return !failing.contains(path)
    }
    func clearDefaults() { log.append("defaults") }
    func clearKeychain() { log.append("keychain") }
    func quit() { log.append("quit") }
}
