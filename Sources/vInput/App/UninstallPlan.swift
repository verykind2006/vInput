import Foundation

/// 真正动手删东西的能力。抽协议是为了能测——测试里绝不真的删家目录。
///
/// `removeItem` **必须回报成败**：删不掉的那一项此前只写一行日志，而日志写在
/// `~/Library/Logs/vInput`——正是这次要删的第二样东西。也就是说部分失败对
/// 用户和对我们都不可见：他看到应用干净退出，以为删完了。
@MainActor
protocol Uninstalling {
    /// 返回是否真的删掉了（路径本来就不存在也算成功——目标是「它不在了」）。
    func removeItem(at path: String) -> Bool
    func clearDefaults()
    func clearKeychain()
    func quit()
}

/// 卸载：删哪些、多大、跟用户怎么说。
///
/// **这个功能的存在理由是一条产品义务**：我们把几个 GB 塞进了用户看不见的
/// 目录（`~/Library/Application Support/vInput/`），就有义务让他能一键清干净。
/// 用户 2026-08-21 原话：「你装到了一个用户不感知的目录下，又下载了几个 G 的
/// 文件在该目录当中，所以必须让用户感知这个东西是可以卸载」。
///
/// 本文件只是纯逻辑 + 协议——面板按钮与真删除的接线是另一个任务，这里不碰
/// `MenuPanelView.swift` / `AppModel.swift`。
enum UninstallPlan {
    struct Item: Equatable {
        let path: String
        /// 给用户看的说明，例如「模型与缓存」。
        let label: String
    }

    static let defaultsSuite = "com.vinput.app"

    nonisolated static func items(home: String) -> [Item] {
        [
            Item(
                path: (home as NSString)
                    .appendingPathComponent("Library/Application Support/vInput"),
                label: "模型与缓存"),
            Item(
                path: (home as NSString).appendingPathComponent("Library/Logs/vInput"),
                label: "日志"),
        ]
    }

    nonisolated static func totalBytes(items: [Item], sizeOf: (String) -> Int64) -> Int64 {
        items.reduce(0) { $0 + sizeOf($1.path) }
    }

    nonisolated static func humanSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // 这两行是给中文句子用的，不是调格式偏好：
        //
        // `ByteCountFormatter` 在 1KB 以下会退回**英文单词**——实测
        // 0 → 「Zero KB」、500 → 「500 bytes」，而这串东西会被原样插进
        // 「共约 …。」这句全中文的确认文案里，非技术用户看到的就是一句
        // 半英半中的坏话。GB/KB 这类缩写本身与语言无关，所以只要不让它
        // 走到「bytes」和「Zero」那两档即可。
        //
        // 什么时候会撞上：模型还没下载、只有日志的那种近乎空的安装。
        formatter.allowsNonnumericFormatting = false
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    struct Confirmation: Equatable {
        let title: String
        let message: String
        let confirmButton: String
        let cancelButton: String
    }

    /// **必须说清两件我们做不到的事**：应用删不掉自己，系统设置里的授权条目
    /// 也不归我们管。含糊过去的话，用户会以为卸载完了，实际留着两处残留。
    nonisolated static func confirmation(sizeText: String) -> Confirmation {
        Confirmation(
            title: "卸载 vInput 的数据？",
            message: """
                将删除模型与缓存、日志、偏好设置，以及你之前输入的 Gemini API 密钥（存在系统「钥匙串」里），\
                共约 \(sizeText)。此操作不可撤销。

                有两件事需要你自己做：把 vInput 拖进废纸篓（应用删不掉自己），\
                以及到「系统设置 → 隐私与安全性」里移除麦克风与辅助功能的授权条目。
                """,
            confirmButton: "删除并退出",
            cancelButton: "取消")
    }

    /// 删不掉的那些东西要跟用户说的话。全删干净时返回 nil。
    ///
    /// **必须点名是哪一样、在哪**：用户此刻唯一能做的事就是自己去 Finder 里
    /// 把它删掉，而「有一样没删掉」这种话帮不了他。路径也给全，
    /// 因为这两个目录都在 `~/Library` 下——Finder 默认不显示。
    nonisolated static func failureNotice(failed: [Item]) -> Failure? {
        guard !failed.isEmpty else { return nil }
        let list = failed.map { "\($0.label)：\($0.path)" }.joined(separator: "\n")
        return Failure(
            title: "有东西没能删掉",
            message: """
                下面这些没能删除，vInput 因此没有退出（其余部分已经删了）：

                \(list)

                可以在「访达」里按 ⇧⌘G 输入上面的路径手动删除，然后再退出 vInput。
                """)
    }

    struct Failure: Equatable {
        let title: String
        let message: String
    }

    /// 顺序是契约：**先删文件、再清偏好、最后退出**。
    /// 把退出放前面的话，后面几步根本不会发生。
    ///
    /// 返回**没能删掉的那些项**。有失败就**不退出**：这是用户唯一还能看见
    /// 这件事的时机（日志目录本身就在待删清单里，删掉之后
    /// `AppLogger` 连目录都不会重建，后面几步的日志全部落空）。
    /// 退出之后再说什么都晚了——他看到的只是应用干净地关掉了。
    @MainActor
    static func execute(items: [Item], using uninstaller: Uninstalling) async -> [Item] {
        let failed = items.filter { !uninstaller.removeItem(at: $0.path) }
        uninstaller.clearDefaults()
        uninstaller.clearKeychain()
        guard failed.isEmpty else { return failed }
        uninstaller.quit()
        return []
    }
}
