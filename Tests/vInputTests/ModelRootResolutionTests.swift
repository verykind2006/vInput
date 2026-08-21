import Foundation
import Testing
@testable import vInput

/// 模型根目录的查找顺序。
///
/// 这是本批要修的**核心缺口**：旧实现从 `.app` 往上数两级去找
/// `vendor/models`，因为它假定 app 躺在 `<仓库>/dist/`。装进 `/Applications`
/// 就变成找 `/vendor/models`，必然落空——注释里写着「正式分发时应改为应用
/// 支持目录」，一直没做。
struct ModelRootResolutionTests {
    /// 分发版：开发目录不存在，必须落在应用支持目录。
    @Test func distributionUsesApplicationSupport() {
        let root = ModelCatalog.resolveRoot(
            appSupport: "/Users/someone/Library/Application Support/vInput/huggingface",
            developmentRoot: "/nowhere/vendor/models",
            exists: { $0.hasPrefix("/Users/someone/Library") }
        )
        #expect(root == "/Users/someone/Library/Application Support/vInput/huggingface")
    }

    /// 开发机：`vendor/models` 在，就用它——本机那 4.5GB 重下不现实。
    @Test func developmentPrefersVendorModels() {
        let root = ModelCatalog.resolveRoot(
            appSupport: "/Users/dev/Library/Application Support/vInput/huggingface",
            developmentRoot: "/repo/vendor/models",
            exists: { $0 == "/repo/vendor/models" }
        )
        #expect(root == "/repo/vendor/models")
    }

    /// 两个都在：**开发目录优先**。开发机上应用支持目录也可能有东西
    /// （跑过一次下载），但开发时想用的是 vendor 里那几个。
    @Test func developmentWinsWhenBothExist() {
        let root = ModelCatalog.resolveRoot(
            appSupport: "/as/huggingface",
            developmentRoot: "/repo/vendor/models",
            exists: { _ in true }
        )
        #expect(root == "/repo/vendor/models")
    }

    /// 两个都不在：仍返回应用支持目录——那是**将要下载到**的地方，
    /// 返回 nil 会让调用方误以为「没救了」，而实际只是还没下载。
    @Test func fallsBackToApplicationSupportWhenNothingExists() {
        let root = ModelCatalog.resolveRoot(
            appSupport: "/as/huggingface",
            developmentRoot: "/repo/vendor/models",
            exists: { _ in false }
        )
        #expect(root == "/as/huggingface")
    }

    /// 应用支持目录的具体位置钉死：换了地方，已下载的模型就找不到了。
    @Test func applicationSupportPathIsStable() {
        let path = ModelCatalog.applicationSupportRoot(home: "/Users/x")
        #expect(path == "/Users/x/Library/Application Support/vInput/huggingface")
    }

    /// **我们往盘上写的每一处模型位置，都必须落在卸载清单里面。**
    ///
    /// 这条缝有两个各算各的参与者：
    ///
    /// - `ModelCatalog.applicationSupportRoot(home:)`——向导下载到这儿、
    ///   面板「高级 → 位置」显示的也是这儿；
    /// - `WhisperKitTranscriber.defaultDownloadBasePath()`——tokenizer 缓存
    ///   （turbo 要的 `openai/whisper-large-v3`，约 2.8MB）落在这儿，
    ///   而「本地一个模型都没有」时 WhisperKit 自行下载的那一整份模型
    ///   （`AppModel.bootstrap` 的退化路径）也落在这儿。
    ///
    /// 谁改了自己那一份而卸载清单不知道，表现是**卸载完盘还是满的**：用户看着
    /// 「共约 1.6 GB」的确认框点了「删除并退出」，删完一量还剩几百 MB，
    /// 而这正是这个功能存在的全部理由（用户 2026-08-21：「必须让用户感知
    /// 这个东西是可以卸载」）。
    ///
    /// 此前没有任何东西守着——QA 收尾复验把 `defaultDownloadBase` 改成
    /// `vInput/models`，全仓 1316 条测试**一条都没红**（2026-08-22）。
    @Test func everyModelLocationIsCoveredByTheUninstallPlan() {
        let home = "/Users/x"
        let covered = UninstallPlan.items(home: home).map(\.path)
        func isCovered(_ path: String) -> Bool {
            covered.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        #expect(
            isCovered(ModelCatalog.applicationSupportRoot(home: home)),
            "模型根目录跑到卸载清单外面去了：\(ModelCatalog.applicationSupportRoot(home: home))")

        // `defaultDownloadBasePath()` 只认真实家目录（走 FileManager 的
        // 应用支持目录查询），所以拿真家目录那一份来比。用 `…Path()` 而不是
        // `defaultDownloadBase()`：后者会顺手建目录，测试不该往真家目录里写东西。
        let realHome = NSHomeDirectory()
        let realCovered = UninstallPlan.items(home: realHome).map(\.path)
        let base = WhisperKitTranscriber.defaultDownloadBasePath().path
        #expect(
            realCovered.contains { base == $0 || base.hasPrefix($0 + "/") },
            """
            WhisperKit 的 downloadBase（\(base)）不在卸载清单里：\(realCovered)。
            tokenizer 缓存与「本地没有模型时自行下载」的那一份会在卸载后留在盘上。
            """)
    }
}
