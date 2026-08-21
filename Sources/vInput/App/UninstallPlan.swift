import Foundation

/// 真正动手删东西的能力。抽协议是为了能测——测试里绝不真的删家目录。
@MainActor
protocol Uninstalling {
    func removeItem(at path: String)
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
    static let removesKeychainAPIKey = true

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
                将删除模型与缓存、日志、偏好设置，以及 Keychain 里的云端 API key，\
                共约 \(sizeText)。此操作不可撤销。

                有两件事需要你自己做：把 vInput 拖进废纸篓（应用删不掉自己），\
                以及到「系统设置 → 隐私与安全性」里移除麦克风与辅助功能的授权条目。
                """,
            confirmButton: "删除并退出",
            cancelButton: "取消")
    }

    /// 顺序是契约：**先删文件、再清偏好、最后退出**。
    /// 把退出放前面的话，后面几步根本不会发生。
    @MainActor
    static func execute(items: [Item], using uninstaller: Uninstalling) async {
        for item in items { uninstaller.removeItem(at: item.path) }
        uninstaller.clearDefaults()
        uninstaller.clearKeychain()
        uninstaller.quit()
    }
}
