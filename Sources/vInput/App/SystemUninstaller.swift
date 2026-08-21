import AppKit
import Foundation

/// 目录占了多少字节。卸载确认里那个「共约 1.61 GB」就是它算出来的。
///
/// **必须是真扫，不能写死**：模型下没下、下了几个、校正模型有没有装，
/// 差着一个数量级。用户点开这个入口就是想知道「删掉能腾出多少」。
enum DiskUsage {
    private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
    ]

    /// 路径不存在时返回 0，不报错：模型还没下载时 `Application Support/vInput`
    /// 根本不存在，那是正常状态，不该让卸载入口报错或消失。
    static func bytes(at path: String) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return 0 }
        let url = URL(fileURLWithPath: path)
        guard isDirectory.boolValue else { return fileBytes(url) }

        // **不设 `.skipsPackageDescendants`**：模型目录里全是 `.mlmodelc`，
        // 而它在 URL 层面是个 package——跳过包内容的话，1.5GB 会被数成几 KB，
        // 确认框上写着「共约 12 KB」，用户以为删的是个零头。
        // 也不设 `.skipsHiddenFiles`：藏起来的东西照样占盘。
        guard
            let enumerator = fm.enumerator(
                at: url, includingPropertiesForKeys: Array(keys), options: [])
        else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator { total += fileBytes(child) }
        return total
    }

    private static func fileBytes(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: keys),
            values.isRegularFile == true
        else { return 0 }
        // 优先取「实际占用」（含稀疏文件与簇对齐），取不到再退回逻辑大小。
        let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize
        return Int64(bytes ?? 0)
    }
}

/// 真删东西的那一版 `Uninstalling`。
///
/// **本类型在测试里一次都不会被构造**——测试全部走 `UninstallPlanTests` 与
/// `UninstallFlowTests` 里的假实现。理由不是洁癖：它的 `removeItem` 删的是
/// 家目录下的真实目录，跑错一次就是把开发机上的模型和日志清了。
@MainActor
struct SystemUninstaller: Uninstalling {
    func removeItem(at path: String) {
        do {
            try FileManager.default.removeItem(atPath: path)
            AppLogger.shared.log("卸载：已删除 \(path)")
        } catch {
            // 不中断：某一项删不掉（权限、正被占用）时，剩下的仍然该删干净。
            // 用户看到的结果最差是「少删了一样」，而不是「删了一半就退出了」。
            AppLogger.shared.log("卸载：删除失败 \(path)：\(error)")
        }
    }

    /// 清偏好。
    ///
    /// `UninstallPlan.defaultsSuite` 就是本应用的 bundle id
    /// （`Resources/Info.plist` 里的 `com.vinput.app`），也就是
    /// `UserDefaults.standard` 的持久化域名——所以这一行清的正是全部设置。
    /// 不清的话，用户「卸载」完重装，校正开关、输出语言、云端后端全都还在，
    /// 他会以为没删干净（`UninstallPlanTests` 单列了这一条）。
    func clearDefaults() {
        UserDefaults.standard.removePersistentDomain(forName: UninstallPlan.defaultsSuite)
        AppLogger.shared.log("卸载：已清除偏好域 \(UninstallPlan.defaultsSuite)")
    }

    func clearKeychain() {
        let removed = TranslationKey.delete(service: TranslationKey.geminiService)
        // 只记成败，**不记 key 本身**（`presentCloudAPIKeyPanel` 同一条纪律）。
        AppLogger.shared.log("卸载：Keychain 条目删除结果=\(removed)")
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}

/// 卸载的完整流程：扫体积 → 问一次 → 真删。
///
/// **每一件事都从参数进来**，于是这条流程能被完整跑一遍而不碰真实家目录
/// （`UninstallFlowTests`）。视图里只留一次调用，见 `MenuPanelView` 的
/// 「卸载 vInput 的数据…」。
///
/// 文案一个字都不在这里拼：标题、正文、两个按钮全部来自
/// `UninstallPlan.confirmation(sizeText:)`，由 `UninstallPlanTests` 钉着
/// 「必须说清两件我们做不到的事」。
/// 三个替身参数都是 `nil` 默认值、在函数体里才取生产实现：默认参数表达式
/// 在 **nonisolated 上下文**里求值，而 `SystemUninstaller` 与那个确认框都是
/// `@MainActor` 的（`Wiring.makeBackend` 同一个坑，那边的解法是包一层闭包）。
@MainActor
func runUninstallFlow(
    home: String = NSHomeDirectory(),
    sizeOf: ((String) -> Int64)? = nil,
    confirm: ((String) -> Bool)? = nil,
    uninstaller: (any Uninstalling)? = nil
) async {
    let sizeOf = sizeOf ?? { DiskUsage.bytes(at: $0) }
    let confirm = confirm ?? { presentUninstallConfirmation(sizeText: $0) }
    let uninstaller = uninstaller ?? SystemUninstaller()

    let items = UninstallPlan.items(home: home)
    // 逐项记一行。**`Item.label` 的用处就在这里**：出问题时「哪一样没删掉」
    // 得能从日志里读出来，而一串路径读起来要慢一拍。
    for item in items {
        AppLogger.shared.log(
            "卸载扫描：\(item.label) \(UninstallPlan.humanSize(sizeOf(item.path))) \(item.path)")
    }

    let total = UninstallPlan.totalBytes(items: items, sizeOf: sizeOf)
    guard confirm(UninstallPlan.humanSize(total)) else {
        AppLogger.shared.log("卸载：用户取消")
        return
    }
    AppLogger.shared.log("卸载：用户确认，开始删除")
    await UninstallPlan.execute(items: items, using: uninstaller)
}
