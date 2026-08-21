import Foundation
import Testing

@testable import vInput

/// 卸载的完整流程：扫体积 → 问一次 → 真删。
///
/// **一次都不碰真实家目录**：`home`、`sizeOf`、`confirm`、`uninstaller` 四样
/// 全部从参数进来，生产实现（`SystemUninstaller`）在这个文件里一次都不会被
/// 构造。这条纪律不是洁癖——它的 `removeItem` 删的是家目录下的真实目录。
@MainActor
struct UninstallFlowTests {
    /// **不确认就什么都不做。** 这是最要紧的一条：几个 GB、不可撤销。
    @Test func cancelDeletesNothing() async {
        let recorder = FlowRecorder()
        await runUninstallFlow(
            home: "/Users/x",
            sizeOf: { _ in 1_000 },
            confirm: { _ in false },
            uninstaller: recorder)
        #expect(recorder.log.isEmpty, "用户取消了，却还是动了手：\(recorder.log)")
    }

    /// 确认之后，`UninstallPlan.items` 里的每一项都要真的被删，
    /// 顺序仍是「文件 → 偏好 → 钥匙串 → 退出」。
    @Test func confirmRunsTheWholePlanInOrder() async {
        let recorder = FlowRecorder()
        await runUninstallFlow(
            home: "/Users/x",
            sizeOf: { _ in 1_000 },
            confirm: { _ in true },
            uninstaller: recorder)
        let expected =
            UninstallPlan.items(home: "/Users/x").map { "remove:\($0.path)" }
            + ["defaults", "keychain", "quit"]
        #expect(recorder.log == expected, "卸载动作或顺序不对：\(recorder.log)")
    }

    /// 确认框里那个体积是**扫出来的合计**，不是某一项、也不是写死的数。
    ///
    /// 变异「把 `totalBytes` 换成第一项的大小」由这一条抓：用户看到的数字
    /// 会比实际小，而这个数字正是他决定删不删的依据。
    @Test func confirmationGetsTheMeasuredTotal() async {
        var shown: [String] = []
        await runUninstallFlow(
            home: "/Users/x",
            sizeOf: { path in path.hasSuffix("Application Support/vInput") ? 1_610_612_736 : 4_096 },
            confirm: { text in
                shown.append(text)
                return false
            },
            uninstaller: FlowRecorder())
        #expect(shown.count == 1, "确认框弹了 \(shown.count) 次。")
        #expect(shown.first == UninstallPlan.humanSize(1_610_616_832))
    }

    /// 确认框的每一个字都来自 `UninstallPlan.confirmation(sizeText:)`。
    ///
    /// 这一条与 `presentUninstallConfirmation` 里那段扫源码的断言是一对：
    /// 这里钉「体积真的被插进了那句话」，那里钉「视图/面板层没有另写一份」。
    @Test func confirmationCopyCarriesTheSize() {
        let copy = UninstallPlan.confirmation(sizeText: UninstallPlan.humanSize(1_610_612_736))
        let mentionsSize = copy.message.contains(UninstallPlan.humanSize(1_610_612_736))
        #expect(mentionsSize)
        #expect(copy.cancelButton == "取消")
        #expect(copy.confirmButton == "删除并退出")
    }

    /// `Item.label` 不许与确认文案对不上。
    ///
    /// 那两个 label（「模型与缓存」「日志」）此前没有任何人读，而确认文案里
    /// 逐字列着同样两样东西。将来加第三项（比如「基准集录音」）却忘了改文案，
    /// 用户就会看到一句漏说了一样东西的确认——这条测试逼着两边一起改。
    @Test func everyItemLabelIsMentionedInTheConfirmation() {
        let message = UninstallPlan.confirmation(sizeText: "1 GB").message
        for item in UninstallPlan.items(home: "/Users/x") {
            let mentioned = message.contains(item.label)
            #expect(
                mentioned,
                """
                确认文案里没提「\(item.label)」，而卸载会把它删掉。
                要删的东西必须在确认框里逐样说清——这是不可撤销的操作。
                """
            )
        }
    }

    // MARK: - 真扫体积（在临时目录里，绝不碰家目录）

    /// 不存在的路径算 0，不报错：模型还没下载时那个目录根本不存在。
    @Test func missingPathCountsAsZero() {
        #expect(DiskUsage.bytes(at: "/tmp/vinput-does-not-exist-\(UUID().uuidString)") == 0)
    }

    /// 递归求和：子目录里的文件也要数进去。
    ///
    /// **`.mlmodelc` 那一段是这条的重点**：模型目录里全是它，而它在 URL 层面
    /// 是个 package。枚举时若设了 `.skipsPackageDescendants`，1.5GB 会被数成
    /// 几 KB，确认框上写着「共约 12 KB」，用户以为删的是个零头。
    @Test func sumsNestedFilesIncludingPackageLikeFolders() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vinput-disk-usage-\(UUID().uuidString)")
        let inner = root.appendingPathComponent("AudioEncoder.mlmodelc")
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data(repeating: 0x41, count: 4_096).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 0x42, count: 8_192).write(to: inner.appendingPathComponent("weights"))

        let bytes = DiskUsage.bytes(at: root.path)
        // 断言下界而不是等值：文件系统按簇分配，实际占用只会 ≥ 逻辑大小。
        let countsBoth = bytes >= 12_288
        #expect(countsBoth, "扫出来只有 \(bytes) 字节，两个文件（4096+8192）没数全。")
    }
}

/// 只记下被要求做了什么的假 `Uninstalling`。
@MainActor
private final class FlowRecorder: Uninstalling {
    var log: [String] = []
    func removeItem(at path: String) { log.append("remove:\(path)") }
    func clearDefaults() { log.append("defaults") }
    func clearKeychain() { log.append("keychain") }
    func quit() { log.append("quit") }
}
