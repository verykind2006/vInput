# M9 第二批 · 首次启动向导与可卸载性 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让一个只会双击安装包的人，装完能自己说出第一句话——首次启动向导（权限 + 下模型 + 试说一句）、存储位置规范化到应用支持目录、面板里可一键卸载。

**Architecture:** 逻辑与副作用严格分层。步骤推进、源选择、卸载清单、路径解析全部做成 `nonisolated static` 纯函数或可注入类型；网络探测、下载、TCC 查询、文件删除各抽协议，测试用假实现。窗口与 SwiftUI 视图只画，不含判断。

**Tech Stack:** Swift 6 / SwiftUI / AppKit / Swift Testing。`WhisperKit.download(...)` 是公开 API（带 `endpoint` 与 `progressCallback`），**不改 `vendor/`**。

设计定稿：`docs/superpowers/specs/2026-08-21-m9-batch2-onboarding-design.md`。

---

## 全局规矩（每个任务都适用）

1. **变异验证是强制的。** 每写一条测试，故意把被测判据改坏、跑一遍、确认对应用例真的红、再改回。被抓形态有三种：断言失败、**编译错误**、挂起——看完整输出，别只 grep 一个词。**「没打出红」和「真没抓到」必须分清**：上一批两次栽在这儿（一次是变异触发编译错误被 grep 滤掉，一次是 `sed` 模式压根没匹配上、文件根本没改）。提交信息附变异表。
2. **`vendor/` 一个字节都不要动**（在 `.gitignore` 里，改了会无声丢失）。
3. **`Sources/vInput/App/vInputApp.swift` 的 I 是大写的。** macOS 文件系统不区分大小写，`git add` 写成小写会**静默漏收**——改动在磁盘上、测试和构建都吃得到，git 里却没有。上一批因此漏掉过一个修复。
4. **测试里绝不真的删家目录里的东西。** 卸载相关一律走假实现。
5. 断言先算成 Bool 再 `#expect`，不要把整份源码交给它。
6. `swift test --filter X` 按**源文件名**选，且被跳过的套件照样打「passed」——判「有没有真跑」要数逐条 ✓ 结果行。
7. 若 `swift test` 报 `library load disallowed by system policy`：`xattr -cr .build` 后重签 xctest（OneDrive quarantine，见 `docs/dev-dependencies.md`）。
8. 每个任务收尾跑一次 `./scripts/test.sh`。**基线 1190 条 / 158 套件全绿。**
9. 不要 `killall`/`open` 应用——真机验收是用户的步骤（Task 8）。

## 文件地图

| 文件 | 动作 | 职责 |
|---|---|---|
| `Sources/vInput/Transcribe/ModelCatalog.swift` | 修改 | 模型根目录解析：应用支持目录 → `vendor/models` 回退 |
| `Sources/vInput/Onboarding/DownloadSource.swift` | 创建 | 下载源探测与选择（纯策略 + 探测协议） |
| `Sources/vInput/Onboarding/OnboardingState.swift` | 创建 | 向导步骤、推进规则、落盘与恢复 |
| `Sources/vInput/Onboarding/ModelDownloader.swift` | 创建 | 包 `WhisperKit.download`，进度 → 可观察状态 |
| `Sources/vInput/App/UninstallPlan.swift` | 创建 | 卸载清单（删哪些、多大、文案）+ 执行协议 |
| `Sources/vInput/Onboarding/OnboardingWindow.swift` | 创建 | 窗口控制器（照 `BenchRecordingWindowController`） |
| `Sources/vInput/Onboarding/OnboardingView.swift` | 创建 | 五步视图，只画 |
| `Sources/vInput/UI/MenuPanelView.swift` | 修改 | 「高级」折叠区：在访达中显示 / 下载源 / 卸载 |
| `Sources/vInput/App/AppModel.swift` | 修改 | 接线：首次启动判断、卸载执行 |
| `Sources/vInput/App/vInputApp.swift` | 修改 | `AppDelegate` 里按需拉起向导 |

**任务顺序有依赖**：1–5 是纯逻辑，可各自独立完成；6 依赖 4/5；7 依赖 2；8 收尾。

---

### Task 1: 模型根目录解析（应用支持目录 → vendor 回退）

**Files:**
- Modify: `Sources/vInput/Transcribe/ModelCatalog.swift`
- Test: `Tests/vInputTests/ModelRootResolutionTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ModelRootResolutionTests`
Expected: 编译错误（`resolveRoot` / `applicationSupportRoot` 不存在）——算「红」。

- [ ] **Step 3: 实现**

在 `ModelCatalog` 里加（保留既有 `defaultRoot`，标注为开发期用途）：

```swift
    /// 应用支持目录下的模型位置。
    ///
    /// **与 `WhisperKitTranscriber.defaultDownloadBase()` 必须是同一个地方**
    /// ——那边是「下载到哪」，这边是「去哪找」，对不上就会下完还说找不到。
    nonisolated static func applicationSupportRoot(home: String) -> String {
        (home as NSString)
            .appendingPathComponent("Library/Application Support/vInput/huggingface")
    }

    /// 模型根目录的查找顺序：**开发目录优先，其次应用支持目录**。
    ///
    /// 判据就是「那个目录在不在」，不需要环境变量或构建配置来区分开发与分发：
    /// - 分发版那台机器上 `vendor/models` 不存在 → 走应用支持目录；
    /// - 开发机上它存在（4.5GB，重下不现实）→ 继续用它。
    ///
    /// 两个都不在时返回应用支持目录：那是**将要下载到**的地方，返回 nil 会让
    /// 调用方误判成「没救了」，而实际只是还没下载。
    nonisolated static func resolveRoot(
        appSupport: String,
        developmentRoot: String,
        exists: (String) -> Bool
    ) -> String {
        if exists(developmentRoot) { return developmentRoot }
        return appSupport
    }
```

调用方接线：找到 `defaultRoot(appBundleURL:)` 的调用点（`AppModel` 里刷新可用模型那条路），改为

```swift
        let root = ModelCatalog.resolveRoot(
            appSupport: ModelCatalog.applicationSupportRoot(
                home: NSHomeDirectory()),
            developmentRoot: ModelCatalog.defaultRoot(appBundleURL: Bundle.main.bundleURL),
            exists: { FileManager.default.fileExists(atPath: $0) }
        )
```

并把 `defaultRoot` 的文档注释改成「**开发期**位置」，删掉那句已过时的「正式分发时应改为应用支持目录（M6 范围）」。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter ModelRootResolutionTests` → 逐条 ✓（5 条）。
Run: `swift test --filter ModelCatalogTests` → 既有用例不回归。

- [ ] **Step 5: 变异验证**

1. `resolveRoot` 里两个分支对调（先 appSupport）→ `developmentPrefersVendorModels`、`developmentWinsWhenBothExist` 红。
2. 两个都不在时改成返回 `developmentRoot` → `fallsBackToApplicationSupportWhenNothingExists` 红。
3. `applicationSupportRoot` 的路径少一层 `vInput` → `applicationSupportPathIsStable` 红。
4. 接线变异：把调用方改回直接用 `defaultRoot(appBundleURL:)` → **预计没有测试会红**（那是接线，不是逻辑）。如实记录，并在 `AppModelWiringTests` 里补一条源码扫描断言钉住 `resolveRoot(` 出现在接线处，确认它对这个变异红。

- [ ] **Step 6: Commit**

```bash
git add Sources/vInput/Transcribe/ModelCatalog.swift Tests/vInputTests/ModelRootResolutionTests.swift Sources/vInput/App/AppModel.swift Tests/vInputTests/AppModelWiringTests.swift
git commit -m "feat: 模型根目录改为应用支持目录，开发机回退 vendor/models"
```

---

### Task 2: 卸载清单（纯逻辑 + 执行协议）

**Files:**
- Create: `Sources/vInput/App/UninstallPlan.swift`
- Test: `Tests/vInputTests/UninstallPlanTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import Foundation
import Testing
@testable import vInput

/// 卸载：删什么、多大、说什么。
///
/// **执行部分一律走假实现**——测试里绝不真的去删家目录里的东西。
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
        #expect(UninstallPlan.removesKeychainAPIKey)
    }

    /// 体积是扫出来的，不是写死的数字。
    @Test func totalSizeSumsMeasuredBytes() {
        let bytes = UninstallPlan.totalBytes(
            items: UninstallPlan.items(home: "/Users/x"),
            sizeOf: { path in path.hasSuffix("Application Support/vInput") ? 1_610_612_736 : 4_096 }
        )
        #expect(bytes == 1_610_616_832)
    }

    /// 人类可读的体积。1.5 GiB 要显示成「1.5 GB」而不是一串字节。
    @Test func formatsSizeForHumans() {
        #expect(UninstallPlan.humanSize(1_610_612_736).contains("1.5"))
        #expect(UninstallPlan.humanSize(4_096).contains("KB"))
    }

    /// **确认文案必须说清两件我们做不到的事**，不许假装做到了：
    /// 应用删不掉自己；系统设置里的授权条目也不归我们管。
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
        await UninstallPlan.execute(items: UninstallPlan.items(home: "/Users/x"), using: recorder)
        #expect(recorder.log.first?.hasPrefix("remove:") == true)
        #expect(recorder.log.contains("defaults"))
        #expect(recorder.log.contains("keychain"))
        #expect(recorder.log.last == "quit")
    }
}

@MainActor
private final class RecordingUninstaller: Uninstalling {
    var log: [String] = []
    func removeItem(at path: String) { log.append("remove:\(path)") }
    func clearDefaults() { log.append("defaults") }
    func clearKeychain() { log.append("keychain") }
    func quit() { log.append("quit") }
}
```

- [ ] **Step 2: 跑测试确认失败** → `swift test --filter UninstallPlanTests` → 编译错误。

- [ ] **Step 3: 实现**

```swift
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
```

- [ ] **Step 4: 跑测试确认通过** → 逐条 ✓（6 条）。

- [ ] **Step 5: 变异验证**

1. `items` 里删掉日志那一项 → `listsEveryPlaceWeWroteTo` 红。
2. `execute` 把 `quit()` 挪到最前 → `executesFilesThenDefaultsThenQuits` 红。
3. `execute` 删掉 `clearKeychain()` → 同上红。
4. `confirmation` 的 message 去掉「废纸篓」那句 → `confirmationTellsTheTruthAboutWhatWeCannotDo` 红。
5. `totalBytes` 改成只算第一项 → `totalSizeSumsMeasuredBytes` 红。

- [ ] **Step 6: Commit** — `feat: 卸载清单与执行协议——删哪些、多大、说清我们做不到的两件事`

---

### Task 3: 下载源并发探测

**Files:**
- Create: `Sources/vInput/Onboarding/DownloadSource.swift`
- Test: `Tests/vInputTests/DownloadSourceTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import Foundation
import Testing
@testable import vInput

/// 下载源选择：官方与国内镜像并发探测，谁先响应用谁。
///
/// 用户 2026-08-21 在国内，9 月 1 日去西班牙——**同一套代码两边都要能用，
/// 且都不该问用户任何问题**。
struct DownloadSourceTests {
    @Test func endpointsAreStable() {
        #expect(DownloadSource.official.endpoint == "https://huggingface.co")
        #expect(DownloadSource.mirror.endpoint == "https://hf-mirror.com")
    }

    @Test func picksWhicheverRespondsFirst() async {
        let picked = await DownloadSource.choose(
            probe: { source in source == .mirror ? .responded(millis: 120) : .responded(millis: 900) },
            forced: nil)
        #expect(picked == .mirror)
    }

    @Test func picksOfficialWhenItWinsAbroad() async {
        let picked = await DownloadSource.choose(
            probe: { source in source == .official ? .responded(millis: 80) : .responded(millis: 400) },
            forced: nil)
        #expect(picked == .official)
    }

    /// 一个不通：用通的那个，不要因为「主源优先」而失败。
    @Test func fallsBackWhenOneIsUnreachable() async {
        let picked = await DownloadSource.choose(
            probe: { source in source == .official ? .unreachable : .responded(millis: 700) },
            forced: nil)
        #expect(picked == .mirror)
    }

    /// 都不通：返回 nil，让调用方去说「两个源都连不上」并给手动导入入口，
    /// 而不是硬选一个然后卡在下载里。
    @Test func returnsNilWhenBothUnreachable() async {
        let picked = await DownloadSource.choose(probe: { _ in .unreachable }, forced: nil)
        #expect(picked == nil)
    }

    /// 用户在设置里强制指定时，不再探测——探测只是「不用问用户」的手段，
    /// 用户真的表达了偏好就该照办。
    @Test func forcedChoiceSkipsProbing() async {
        var probed = false
        let picked = await DownloadSource.choose(
            probe: { _ in probed = true; return .unreachable },
            forced: .official)
        #expect(picked == .official)
        #expect(!probed)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**

```swift
import Foundation

/// 模型下载源。
enum DownloadSource: String, CaseIterable, Equatable, Sendable {
    case official
    case mirror

    var endpoint: String {
        switch self {
        case .official: "https://huggingface.co"
        case .mirror: "https://hf-mirror.com"
        }
    }

    /// 给用户看的名字（面板「高级」区的下载源开关用）。
    var displayName: String {
        switch self {
        case .official: "官方源"
        case .mirror: "国内镜像"
        }
    }

    enum ProbeResult: Equatable, Sendable {
        case responded(millis: Int)
        case unreachable
    }

    /// 并发探测两个源，谁先响应用谁。
    ///
    /// **为什么不是「主源优先、失败再切」**：用户现在在国内，官方源基本不通,
    /// 「先试官方」等于每次都先白等一个超时；而 9 月到西班牙后官方更快，
    /// 写死镜像又反过来吃亏。并发探测让同一套代码两边都最优，且**不必问
    /// 用户身处何地**。
    ///
    /// 两个都不通时返回 nil：调用方要去说「两个源都连不上」并给手动导入入口,
    /// 硬选一个只会卡在下载里。
    static func choose(
        probe: @Sendable (DownloadSource) async -> ProbeResult,
        forced: DownloadSource?
    ) async -> DownloadSource? {
        if let forced { return forced }

        async let officialResult = probe(.official)
        async let mirrorResult = probe(.mirror)
        let results: [(DownloadSource, ProbeResult)] = [
            (.official, await officialResult), (.mirror, await mirrorResult),
        ]

        let reachable = results.compactMap { source, result -> (DownloadSource, Int)? in
            guard case .responded(let millis) = result else { return nil }
            return (source, millis)
        }
        return reachable.min { $0.1 < $1.1 }?.0
    }
}
```

（注：`choose` 用 `async let` 让两个探测真并发；真实探测实现在 Task 5 注入。）

- [ ] **Step 4: 跑测试确认通过** → 逐条 ✓（6 条）。

- [ ] **Step 5: 变异验证**

1. `min` 改 `max` → `picksWhicheverRespondsFirst`、`picksOfficialWhenItWinsAbroad` 红。
2. 删掉 `if let forced` 短路 → `forcedChoiceSkipsProbing` 红。
3. 两个都不通时改成返回 `.official` → `returnsNilWhenBothUnreachable` 红。
4. `mirror.endpoint` 改成官方地址 → `endpointsAreStable` 红。
5. `async let` 改成顺序 `await`（先官方后镜像）→ **预计不红**（结果相同，只是不再并发）。如实记录：并发性本身在单测里证明不了，靠代码审查与真机耗时。

- [ ] **Step 6: Commit** — `feat: 下载源并发探测——国内镜像与官方源谁快用谁，不问用户`

---

### Task 4: 向导状态机

**Files:**
- Create: `Sources/vInput/Onboarding/OnboardingState.swift`
- Test: `Tests/vInputTests/OnboardingStateTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import Foundation
import Testing
@testable import vInput

/// 向导的步骤推进与状态恢复。
@MainActor
struct OnboardingStateTests {
    private func makeDefaults() -> UserDefaults {
        let name = "onboarding-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// 全新用户：从欢迎页开始。
    @Test func freshInstallStartsAtWelcome() {
        let state = OnboardingState(defaults: makeDefaults())
        #expect(!state.isComplete)
        #expect(state.step == .welcome)
    }

    /// 已授权的步骤自动跳过——重装或已经手动开过权限的人，
    /// 不该被再问一遍。
    @Test func skipsAlreadySatisfiedPermissionSteps() {
        #expect(
            OnboardingState.next(after: .welcome, microphone: true, accessibility: true)
                == .downloadModel)
        #expect(
            OnboardingState.next(after: .welcome, microphone: false, accessibility: true)
                == .microphone)
        #expect(
            OnboardingState.next(after: .microphone, microphone: true, accessibility: false)
                == .accessibility)
    }

    /// 走完最后一步才算完成。
    @Test func completesOnlyAfterTestDictation() {
        #expect(OnboardingState.next(after: .downloadModel, microphone: true, accessibility: true)
            == .testDictation)
        #expect(OnboardingState.next(after: .testDictation, microphone: true, accessibility: true)
            == nil)
    }

    /// 中途退出可续：记住走到哪了，下次从那儿开始，不从头再来。
    @Test func resumesWhereItLeftOff() {
        let defaults = makeDefaults()
        let first = OnboardingState(defaults: defaults)
        first.advance(to: .downloadModel)

        let second = OnboardingState(defaults: defaults)
        #expect(second.step == .downloadModel)
        #expect(!second.isComplete)
    }

    /// 完成后不再弹——这是「首次」向导。
    @Test func doesNotReappearOnceComplete() {
        let defaults = makeDefaults()
        let first = OnboardingState(defaults: defaults)
        first.markComplete()

        #expect(OnboardingState(defaults: defaults).isComplete)
        #expect(!OnboardingState.shouldPresent(isComplete: true))
        #expect(OnboardingState.shouldPresent(isComplete: false))
    }

    /// **权限被事后撤销不重开向导。** 撤销权限时用户正在别处（系统设置里），
    /// 这时弹一个抢焦点的窗口是打断；面板的状态行已经会说「需要麦克风权限」。
    @Test func revokedPermissionDoesNotRelaunchWizard() {
        #expect(!OnboardingState.shouldPresent(isComplete: true))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**

```swift
import Foundation
import Observation

/// 首次启动向导的步骤与进度。
///
/// 步骤推进做成 `nonisolated static` 纯函数，实例只管落盘与恢复——
/// 向导窗口在测试进程里跑不起来，能榨出来的逻辑必须榨出来。
@MainActor
@Observable
final class OnboardingState {
    enum Step: String, Equatable, CaseIterable {
        case welcome
        case microphone
        case accessibility
        case downloadModel
        case testDictation
    }

    static let stepKey = "onboarding.step"
    static let completeKey = "onboarding.complete"

    private let defaults: UserDefaults
    private(set) var step: Step
    private(set) var isComplete: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isComplete = defaults.bool(forKey: Self.completeKey)
        self.step = Step(rawValue: defaults.string(forKey: Self.stepKey) ?? "") ?? .welcome
    }

    func advance(to step: Step) {
        self.step = step
        defaults.set(step.rawValue, forKey: Self.stepKey)
    }

    func markComplete() {
        isComplete = true
        defaults.set(true, forKey: Self.completeKey)
    }

    /// 下一步是哪一步。**已满足的权限步骤直接跳过**——重装的人、或者
    /// 早就手动开过权限的人，不该被再问一遍。返回 nil 表示走完了。
    nonisolated static func next(
        after step: Step, microphone: Bool, accessibility: Bool
    ) -> Step? {
        switch step {
        case .welcome:
            if !microphone { return .microphone }
            if !accessibility { return .accessibility }
            return .downloadModel
        case .microphone:
            if !accessibility { return .accessibility }
            return .downloadModel
        case .accessibility:
            return .downloadModel
        case .downloadModel:
            return .testDictation
        case .testDictation:
            return nil
        }
    }

    /// 要不要弹向导。
    ///
    /// **完成过就永远不再弹**，哪怕权限后来被撤销：撤销的那一刻用户正在
    /// 系统设置里，弹一个抢焦点的窗口是打断；面板的状态行已经会说
    /// 「需要麦克风权限」，那条路更轻。
    nonisolated static func shouldPresent(isComplete: Bool) -> Bool {
        !isComplete
    }
}
```

- [ ] **Step 4: 跑测试确认通过** → 逐条 ✓（6 条）。

- [ ] **Step 5: 变异验证**

1. `next(after: .welcome, ...)` 里删掉麦克风那条判断 → `skipsAlreadySatisfiedPermissionSteps` 红。
2. `advance` 删掉 `defaults.set` → `resumesWhereItLeftOff` 红。
3. `shouldPresent` 改成恒 true → `doesNotReappearOnceComplete` 红。
4. `next(after: .testDictation, ...)` 改成返回 `.welcome` → `completesOnlyAfterTestDictation` 红。
5. `Step` 加一个临时 case → `next` 的 switch **编译错误**（穷尽性护栏），删掉。

- [ ] **Step 6: Commit** — `feat: 向导状态机——已授权的步骤跳过、中途退出可续、完成后不再弹`

---

### Task 5: 模型下载包装

**Files:**
- Create: `Sources/vInput/Onboarding/ModelDownloader.swift`
- Test: `Tests/vInputTests/ModelDownloaderTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import Foundation
import Testing
@testable import vInput

@MainActor
struct ModelDownloaderTests {
    @Test func progressBecomesHumanReadable() {
        #expect(ModelDownloader.percentText(0.0) == "0%")
        #expect(ModelDownloader.percentText(0.5) == "50%")
        #expect(ModelDownloader.percentText(1.0) == "100%")
        // 越界不许显示成 -3% 或 137%
        #expect(ModelDownloader.percentText(-0.2) == "0%")
        #expect(ModelDownloader.percentText(1.5) == "100%")
    }

    /// 下载哪个模型是定死的：用户 2026-08-21 定「只用 turbo」。
    @Test func downloadsTurboOnly() {
        #expect(ModelDownloader.variant == "openai_whisper-large-v3-v20240930_turbo")
    }

    /// 已经在本地就不下——重装的人不该再等 1.5GB。
    @Test func skipsWhenModelAlreadyPresent() async {
        let fake = FakeDownloadBackend()
        let outcome = await ModelDownloader.run(
            root: "/models", alreadyPresent: { _ in true }, backend: fake, source: .official)
        #expect(outcome == .alreadyPresent)
        #expect(fake.calls.isEmpty)
    }

    @Test func reportsSourceUsedOnSuccess() async {
        let fake = FakeDownloadBackend()
        let outcome = await ModelDownloader.run(
            root: "/models", alreadyPresent: { _ in false }, backend: fake, source: .mirror)
        #expect(outcome == .downloaded(source: .mirror))
        #expect(fake.calls == ["https://hf-mirror.com"])
    }

    /// 失败要带上是哪个源失败的——出问题时第一时间能分清是模型坏了
    /// 还是源坏了。
    @Test func failureCarriesTheSource() async {
        let fake = FakeDownloadBackend()
        fake.shouldFail = true
        let outcome = await ModelDownloader.run(
            root: "/models", alreadyPresent: { _ in false }, backend: fake, source: .mirror)
        #expect(outcome == .failed(source: .mirror))
    }
}

@MainActor
private final class FakeDownloadBackend: ModelDownloadBackend {
    var calls: [String] = []
    var shouldFail = false
    func download(
        variant: String, into root: String, endpoint: String,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        calls.append(endpoint)
        onProgress(0.5)
        if shouldFail { throw ModelDownloadError.transportFailed }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

- [ ] **Step 3: 实现**

```swift
import Foundation

enum ModelDownloadError: Error, Equatable { case transportFailed }

/// 真正下载的能力。抽协议是为了能测——真下载要联网、要 1.5GB。
@MainActor
protocol ModelDownloadBackend {
    func download(
        variant: String, into root: String, endpoint: String,
        onProgress: @escaping (Double) -> Void
    ) async throws
}

/// 转写模型的获取。
///
/// 底下是 `WhisperKit.download(variant:downloadBase:from:token:endpoint:progressCallback:)`
/// ——**公开 API，不用改 `vendor/`**，而且它同时给了 `endpoint`（可传镜像）
/// 与 `progressCallback`（进度条不用自己造）。这一条是本批「只保主链」
/// 那个范围决定的技术基础。
enum ModelDownloader {
    /// **只下 turbo。** 用户 2026-08-21：「目前我用下来觉得 Turbo 模型就够用」。
    /// 因此向导里没有模型选择这一步。
    static let variant = "openai_whisper-large-v3-v20240930_turbo"

    enum Outcome: Equatable {
        case alreadyPresent
        case downloaded(source: DownloadSource)
        /// 带上是哪个源失败的：出问题时要能分清模型坏了还是源坏了。
        case failed(source: DownloadSource)
    }

    nonisolated static func percentText(_ fraction: Double) -> String {
        let clamped = min(1, max(0, fraction))
        return "\(Int((clamped * 100).rounded()))%"
    }

    @MainActor
    static func run(
        root: String,
        alreadyPresent: (String) -> Bool,
        backend: ModelDownloadBackend,
        source: DownloadSource,
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async -> Outcome {
        let folder = (root as NSString).appendingPathComponent(variant)
        if alreadyPresent(folder) { return .alreadyPresent }
        do {
            try await backend.download(
                variant: variant, into: root, endpoint: source.endpoint, onProgress: onProgress)
            AppLogger.shared.log("模型下载完成：\(variant)，源=\(source.displayName)")
            return .downloaded(source: source)
        } catch {
            AppLogger.shared.log("模型下载失败：源=\(source.displayName) 错误=\(error)")
            return .failed(source: source)
        }
    }
}
```

生产实现（同文件，标注只有真机能验证）：

```swift
/// 生产实现：转发给 WhisperKit。**这一层在测试进程里跑不到**
/// （真联网、1.5GB），逻辑因此全部留在上面的 `run` 里。
@MainActor
struct WhisperKitDownloadBackend: ModelDownloadBackend {
    func download(
        variant: String, into root: String, endpoint: String,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        _ = try await WhisperKit.download(
            variant: variant,
            downloadBase: URL(fileURLWithPath: root).deletingLastPathComponent(),
            from: "argmaxinc/whisperkit-coreml",
            token: nil,
            endpoint: endpoint,
            progressCallback: { progress in
                Task { @MainActor in onProgress(progress.fractionCompleted) }
            })
    }
}
```

实现时核对 `WhisperKit.download` 的真实签名与 `downloadBase` 的语义（它是**下载根**，而 `root` 是模型父目录，别搞反），并与 `WhisperKitTranscriber.defaultDownloadBase()` 对齐——两处对不上就会「下完还说找不到」。

- [ ] **Step 4: 跑测试确认通过** → 逐条 ✓（5 条）。

- [ ] **Step 5: 变异验证**

1. `percentText` 去掉钳位 → 该用例红。
2. `run` 里删掉 `alreadyPresent` 短路 → `skipsWhenModelAlreadyPresent` 红。
3. `failed(source:)` 改成不带源的 `failed` → 编译错误 + `failureCarriesTheSource` 红。
4. `variant` 改成 base → `downloadsTurboOnly` 红。
5. `WhisperKitDownloadBackend` 里 endpoint 写死官方（忽略参数）→ **预计不红**（生产实现测不到）。如实记录，列进 Task 8 真机项。

- [ ] **Step 6: Commit** — `feat: 模型下载包装——只下 turbo，带源与进度，失败说清是哪个源`

---

### Task 6: 向导窗口与视图

**Files:**
- Create: `Sources/vInput/Onboarding/OnboardingWindow.swift`
- Create: `Sources/vInput/Onboarding/OnboardingView.swift`
- Modify: `Sources/vInput/App/vInputApp.swift`（注意大写 I）、`Sources/vInput/App/AppModel.swift`

视图与窗口无可测逻辑（逻辑已在 Task 4/5），本任务用**源码扫描**钉接线，观感留 Task 8。

- [ ] **Step 1: 窗口控制器**

照抄 `BenchRecordingWindowController` 的结构（`.titled` 窗口、`isReleasedWhenClosed = false`、`delegate`、`finishClose`、`bringToFront`）。三处必须保留其理由注释：`isReleasedWhenClosed = false`（ARC 下由控制器持有，默认 true 会过度释放）、`close()` 后补一次 `finishClose`（未上屏窗口不保证发 `windowWillClose`）、`bringToFront` 里的 `activate`（LSUIElement 不激活的话窗口躲在别人后面且不收键盘）。

**与录制窗不同的一处**：向导窗口**不锁浅色外观**（录制窗那条是用户对白底黑字的明确要求，不适用这里），跟随系统。

- [ ] **Step 2: 五步视图**

`OnboardingView`，按 `OnboardingState.Step` 分支渲染。视觉沿用 M9 第一批的 `VITheme` 与 `TypeScale`，保持一套语言。

- **欢迎**：一句话说清这个应用做什么、接下来要做几步。
- **麦克风**：按钮调 `Permissions.requestMicrophone()`（系统弹窗），授权后自动前进。
- **辅助功能**：说明「无法用弹窗授予，需要你去系统设置里打开」+「打开系统设置」按钮（`Permissions.openAccessibilitySettings()`）+ **轮询检测，开好了自动前进**（每 0.5 秒查一次 `accessibilityTrusted()`；窗口关闭或离开该步时停掉计时器）。
- **下载模型**：进度条 + `ModelDownloader.percentText`。**下载在进入向导时就已在后台开始**（见 Step 3），到这一步通常已完成或接近完成。失败时显示是哪个源失败的，并给「我已经有模型文件」的手动导入入口（复用现有的目录选择面板 + `ModelCatalog.validate(folder:)`）。
- **试说一句**：一个文本框 + 提示「按住 ⌥D 说一句话」。注入到**向导窗口自己的文本框**，不碰别的应用。成功后 `markComplete()` 并关窗。

- [ ] **Step 3: 接线**

`AppDelegate.applicationDidFinishLaunching` 里：构造 `OnboardingState`，`shouldPresent(isComplete:)` 为真时拉起窗口，**并立即在后台启动模型下载**（与权限步骤并行——1.5GB 的等待被权限授权吃掉，而不是干等）。

- [ ] **Step 4: 源码扫描守卫**

在 `Tests/vInputTests/OnboardingWiringTests.swift` 里钉 4 条（先算 Bool 再断言，失败信息写清后果）：
1. `AppDelegate` 里调了 `OnboardingState.shouldPresent(` —— 不调的话向导永远不弹，而**这正是本批的全部意义**。
2. 下载在拉起窗口时就开始（钉那处调用的存在）—— 少了它用户要在「下载模型」这一步干等 1.5GB。
3. 辅助功能那一步有轮询检测 —— 少了它用户开完权限却不知道向导认没认。
4. 「试说一句」注入到窗口自己的文本框（钉不走 `TypingSink` 那条路）—— 走错的话会注进用户上一个应用里。

每条做变异验证（删掉对应代码行 → 该条红）。

- [ ] **Step 5: 验证**

`./scripts/test.sh` 与基线同绿（加上新增条数）；`./scripts/build-app.sh` 成功。**不要 killall/open。**

- [ ] **Step 6: Commit** — `feat: 首次启动向导——五步，下载与授权并行，可中断可续`

---

### Task 7: 面板「高级」区与卸载入口

**Files:**
- Modify: `Sources/vInput/UI/MenuPanelView.swift`
- Modify: `Sources/vInput/App/AppModel.swift`
- Test: 扩 `Tests/vInputTests/MenuPanelViewWiringTests.swift`

- [ ] **Step 1: 加一行折叠区**

`SettingRow` 枚举加 `.advanced`（手风琴天然容纳，无需改结构）。区内四项：

1. **储存位置**：显示 `ModelCatalog.resolveRoot(...)` 的结果 + 「在访达中显示」（`NSWorkspace.selectFile`）。
2. **下载源**：自动 / 强制官方 / 强制镜像（写进 `UserDefaults`，Task 3 的 `forced` 参数读它）。
3. **校正模型目录**（从现有位置移进来，属进阶项）。
4. **卸载 vInput 的数据…**（红色文字，区内最后一项）。

- [ ] **Step 2: 卸载动作接线**

点击 → 扫盘算体积（`UninstallPlan.totalBytes`）→ `NSAlert` 用 `UninstallPlan.confirmation(sizeText:)` 的文案 →**取消是默认按钮**（与 `presentCloudBackendConfirmation` 同一条道理：一路回车不该把数据删了）→ 确认后 `UninstallPlan.execute(items:using:)`，生产实现真删文件、清 `UserDefaults`、删 Keychain 条目、`NSApp.terminate`。

- [ ] **Step 3: 守卫测试 + 变异验证**

钉三条：卸载走 `UninstallPlan.confirmation(`（不许在视图里另拼文案）；取消是默认按钮；卸载项在 `.advanced` 区内（不许出现在主区，误点代价太大）。每条变异验证。

- [ ] **Step 4: 验证 + Commit** — `feat: 面板「高级」区——储存位置、下载源、卸载`

---

### Task 8: 收尾——QA 代理与干净环境真机验收

- [ ] **Step 1: 全量**

```bash
./scripts/test.sh && ./scripts/build-app.sh
```

- [ ] **Step 2: 派专门 QA 代理**（按 `final-qa-agent-before-handoff` 惯例）

任务书要点：不复述测试结果；查**跨任务接缝**——① `ModelCatalog.resolveRoot` 与 `WhisperKitTranscriber.defaultDownloadBase()` 是否真的指向同一个地方（对不上就「下完还说找不到」）；② 向导完成后面板的状态行与向导的判断是否会说两套话；③ 卸载删掉的目录是否覆盖了本批新写入的所有位置（含向导状态）；④ 下载源的 `forced` 设置从面板写、被 Task 3 读，两处 key 是否一致；⑤ 审计所有源码扫描测试的锚点是否仍然有效（上一批抓到过两条扫了一个不再包含被测内容的文件、从此永远绿）。**QA 自己重新挑变异点，不许照抄实施者的变异表。** 报出的问题修完再进 Step 3。

- [ ] **Step 3: 请用户真机验收**

**必须在没有 `vendor/models` 的干净环境里做**——否则开发期回退路径会掩盖掉「分发版找不到模型」这个本批要修的核心缺口。最简做法：

```bash
mv vendor/models vendor/models.bak     # 验收前
# ……验收……
mv vendor/models.bak vendor/models     # 验收后立刻改回
```

再删掉向导完成标记（`defaults delete com.vinput.app onboarding.complete`）与已下载的模型，然后 `./scripts/build-app.sh && killall vInput; open dist/vInput.app`。

验收清单（按风险排序，标注可用日志判定的）：

1. 向导是否自动弹出；欢迎 → 麦克风 → 辅助功能逐步是否顺畅。
2. **辅助功能开好后向导是否自动前进**（不自动的话用户会卡死在这一步）。
3. 模型下载：进度是否在动、用的是哪个源（📋 **日志判**：`模型下载完成：… 源=…`）。
4. 「试说一句」是否注入到向导自己的文本框（不是别的应用）。
5. 向导中途关掉窗口 → 重启应用是否从上次那一步继续。
6. 完成后重启应用，向导**不应再弹**。
7. 面板「高级」区：储存位置显示是否正确、「在访达中显示」是否打开对的目录。
8. **卸载**（放最后，会清掉一切）：体积数字是否合理、确认框的默认按钮是不是「取消」、删完是否退出；重启后是否回到全新状态（向导重新弹）。

- [x] **Step 3b: 顺带修一条既有的 flaky 测试**（Task 1 发现；**已于 Task 3 期间提前修掉**，因为它每跑几次就绊一次、开始干扰正常验证。判据从秒表改成语义：断言「`correct` 返回时那份 2 秒的工作还没跑完」，零计时依赖。变异验证：把超时调到比工作还长 → 精确变红。全量连跑 3 次绿。）

`Tests/vInputTests/CorrectionPipelineTests.swift` 的
`timeoutReturnsEvenIfWorkIgnoresCancellation`：它用真实墙钟量一次异步调用，
断言 `elapsed < .milliseconds(800)`，而被测超时是 200ms。配套的假 corrector
故意忙等 2 秒（`while Date() < deadline {}`，不检查取消，模拟不可取消的 MLX
同步推理）——**那个忙等会和计时任务抢协作线程池的调度槽**，系统一忙就可能
让计时任务饿过 800ms，虽然逻辑上超时在 200ms 就正确触发了。实测过一次
1.2s 失败，单独重跑即绿。

修法三选一（实施时判断哪个最小）：把预算改成相对于 `timeout` 而不是写死的
常数；把它与同文件里其他忙等测试隔开串行跑；或者把墙钟断言换成顺序/信号
断言。**不要简单地把 800ms 调大**——那只是把抖动的阈值挪远，没解决忙等
抢调度这个成因。

- [ ] **Step 4: 更新 Roadmap + 收尾提交**

`docs/Roadmap.md` 的 M9 ② 改为已完成并写验收记录（含未验证项，如实标注）。

---

## Self-review 已做的三项检查

1. **规格覆盖**：定稿 ①→Task 1，②→Task 4/5/6，③→Task 3，④→Task 2/7，⑤（不做独立设置窗口）→Task 7 落进面板；「不做什么」清单没有任务与之冲突。
2. **无占位**：每个代码步都有完整代码；Task 6/7 是视图与接线，标注了「照抄哪个先例」与「钉哪几条」，不是占位。
3. **类型一致性**：`ModelCatalog.resolveRoot/applicationSupportRoot`（T1）↔ T5 的 `root` 与 T7 的显示；`DownloadSource`（T3）↔ `ModelDownloader.run(source:)`（T5）↔ 面板的 `forced` 设置（T7）；`UninstallPlan.Item/Uninstalling`（T2）↔ 面板接线（T7）；`OnboardingState.Step`（T4）↔ 视图分支（T6）。两处待实施时核实：`WhisperKit.download` 的真实签名与 `downloadBase` 语义、`AppModel.permissionStatus` 的刷新时机。
