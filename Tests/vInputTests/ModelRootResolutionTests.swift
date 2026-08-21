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
}
