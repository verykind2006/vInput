import Foundation
import Testing

@testable import vInput

/// 云端开关在菜单上的样子。
///
/// # 这套用例要挡的是什么
///
/// 菜单文案的测试最容易做成「构造一个字符串、断言它非空」——那是本仓库
/// 头号缺陷类型（「看着在检查什么，其实什么都没检查」）的又一个形态。
/// 所以这里的每一条都落在**可判读的具体内容**上，而不是「有字」：
///
/// 1. **真值表是手写的**（`cells`），不是从生产函数算出来的。每一格的期望
///    状态是按产品语义一格一格写下来的，生产端怎么实现都不影响它。
/// 2. **表的输入端接的是真正决定行为的那个判断**
///    （`AppModel.translationAttachment`），不是照抄一份判断逻辑。于是
///    「菜单说开、实际走本机」这类脱节会在这里红——变异实测见文件末尾。
/// 3. **标题逐字钉死**。四格四句话，把任意两格的文案对调都会红；
///    只断言「四句不一样」的话，对调是抓不到的。
/// 4. **出站与否的那句话，与真实字节对照**：见
///    `CloudEgressTests.menuClaimMatchesObservedEgress`，那条拿记录型
///    `URLSession` 当场数请求，菜单说会发出的那一格必须正好是真发了的那格。
///
/// # 变异表（2026-08-19 实测，`./scripts/test.sh --filter` 上面这几个类型名，
/// 数的是**逐条结果行**不是汇总行）
///
/// | 变异 | 结果 |
/// |---|---|
/// | `translationBackendStatus` 不看挂载结论，直接照抄 `usesCloudBackend` | 1 条红：`statusTable` |
/// | 把 `.cloudIdleBecauseChinese` 与 `.cloudActive` 的标题对调 | 1 条红：`menuTitlesArePinned` |
/// | `.cloudIdleBecauseChinese` 的说明行删掉「一个字节都不会离开本机」 | 1 条红：`quietStatesSayTheyAreQuiet` |
/// | `syncTranslationMirrors` 不再喂挂载结论（写死 `.detach`） | 1 条红：`statusComesFromTheAttachmentDecision` |
/// | `toggleCloudBackend` 去掉确认直接开 | 1 条红：`enablingRequiresConfirmation` |
/// | 菜单里加一句 `TranslationKey.read` | 1 条红：`menuNeverReadsKeychain` |
/// | 协调器改成每次 `apply()` 都读 Keychain | 1 条红：`keychainIsReadOnlyWhenCloudActuallyRuns` |
/// | `translationAttachment` 里语言判断与后端判断对调 | **6 条红**：`statusTable`、`menuClaimMatchesObservedEgress`、`keychainIsReadOnlyWhenCloudActuallyRuns`，以及既有的 3 条（`chineseWithCloudStillDetaches` 等） |
///
/// **第一行要单独说一句**：那次变异下 `menuClaimMatchesObservedEgress`
/// **没红**。原因是中文那一格从不去读 Keychain，`cloudKeyPresent` 停在
/// false，变异体于是算出 `.cloudMissingKey`——那也是一格「不出站」，与观测
/// 到的 0 条请求恰好对得上。抓住它的是**手写的那张真值表**。
/// 写在这里不是自谦：观测型的那条只在「状态声称出站」时才有话说，
/// 两条一起断言才不漏。
@Suite("云端开关的菜单状态")
struct CloudBackendMenuTests {
    private static let correctionDirectory = URL(fileURLWithPath: "/models/correct")

    /// 真值表的一格。**期望值是手写的。**
    private struct Cell {
        let target: TranslationTarget
        let cloud: Bool
        let hasKey: Bool
        /// nil ＝ 连校正模型目录都没有（`translationAttachment` 会给
        /// `.unconfigured`）。
        let directory: URL?
        let expected: AppModel.TranslationBackendStatus
        let why: String

        /// 走一遍生产的两步：先算挂载结论，再由结论推菜单状态。
        /// **这正是 `AppModel.syncTranslationMirrors` 的接法**，
        /// 不是另写一条等价路径。
        var status: AppModel.TranslationBackendStatus {
            let attachment = AppModel.translationAttachment(
                target: target,
                usesCloudBackend: cloud,
                translationModelDirectory: nil,
                correctionModelDirectory: directory,
                // 这张表测的是「挂载结论 → 菜单状态」的映射，目录是不是真存在
                // 与它无关；`directory: nil` 那两格已经覆盖了 `.unconfigured`。
                isUsableModelDirectory: { _ in true }
            )
            return AppModel.translationBackendStatus(
                attachment: attachment,
                usesCloudBackend: cloud,
                hasAPIKey: hasKey
            )
        }
    }

    private static let cells: [Cell] = [
        Cell(
            target: .chinese, cloud: false, hasKey: true, directory: correctionDirectory,
            expected: .local,
            why: "云端关：翻译（这里根本不翻译）在本机"),
        Cell(
            target: .chinese, cloud: true, hasKey: true, directory: correctionDirectory,
            expected: .cloudIdleBecauseChinese,
            why: "开关开着，但输出中文＝不翻译，一个字节都不出站——这一格最容易被显示成「正在往外发」"),
        Cell(
            target: .chinese, cloud: true, hasKey: false, directory: correctionDirectory,
            expected: .cloudIdleBecauseChinese,
            why: "输出是中文时，有没有 key 都无关紧要，菜单不该去提 key"),
        Cell(
            target: .english, cloud: false, hasKey: true, directory: correctionDirectory,
            expected: .local,
            why: "外语 + 云端关：本地 MLX，零出站"),
        Cell(
            target: .english, cloud: false, hasKey: true, directory: nil,
            expected: .local,
            why: "外语 + 云端关 + 连模型目录都没有：仍然是本机的事，缺目录由「输出语言」那一行的后缀说"),
        Cell(
            target: .english, cloud: true, hasKey: true, directory: correctionDirectory,
            expected: .cloudActive,
            why: "唯一真的会出站的一格"),
        Cell(
            target: .english, cloud: true, hasKey: false, directory: correctionDirectory,
            expected: .cloudMissingKey,
            why: "开了云端却没配 key：每次听写退回中文原文，用户必须看得见"),
        Cell(
            target: .english, cloud: true, hasKey: true, directory: nil,
            expected: .cloudActive,
            why: "云端不需要本地权重，缺目录不影响它"),
    ]

    /// 那张表，逐格钉死。
    @Test("菜单状态的真值表")
    func statusTable() {
        for cell in Self.cells {
            #expect(
                cell.status == cell.expected,
                """
                \(cell.target.rawValue) × 云端\(cell.cloud ? "开" : "关") × \
                key\(cell.hasKey ? "有" : "无") × 目录\(cell.directory == nil ? "无" : "有")
                期望 \(cell.expected)，实际 \(cell.status)
                这一格的意义：\(cell.why)
                """
            )
        }
    }

    /// 六种外语一视同仁——没有哪一种会因为「实测过 / 没实测过」而走别的分支。
    @Test("每种外语在云端开着时的状态都一样")
    func everyForeignLanguageBehavesTheSame() {
        for target in TranslationTarget.allCases where target.requiresTranslation {
            let withKey = Cell(
                target: target, cloud: true, hasKey: true,
                directory: Self.correctionDirectory, expected: .cloudActive, why: "")
            let withoutKey = Cell(
                target: target, cloud: true, hasKey: false,
                directory: Self.correctionDirectory, expected: .cloudMissingKey, why: "")
            #expect(withKey.status == .cloudActive, "\(target.rawValue) 有 key 时不是 cloudActive")
            #expect(
                withoutKey.status == .cloudMissingKey, "\(target.rawValue) 缺 key 时不是 cloudMissingKey")
        }
    }

    /// **只有一格会出站。** 这条是「不许把开关状态当成出站状态」的总断言。
    @Test("四格里只有「云端开 + 外语 + 有 key」那格会出站")
    func onlyOneStatusSendsAnything() {
        #expect(AppModel.TranslationBackendStatus.local.sendsTextOffDevice == false)
        #expect(AppModel.TranslationBackendStatus.cloudIdleBecauseChinese.sendsTextOffDevice == false)
        // 缺 key 时 GeminiTranslator 在发请求之前就抛，一个字节都不出站
        // （`CloudEgressTests.missingKeyIsLoudAndDoesNotFallBackToLocal` 观测过）。
        #expect(AppModel.TranslationBackendStatus.cloudMissingKey.sendsTextOffDevice == false)
        #expect(AppModel.TranslationBackendStatus.cloudActive.sendsTextOffDevice)
    }

    // MARK: - 文案

    /// 四句标题**逐字钉死**。
    ///
    /// 只断言「四句两两不同」的话，把两格的文案对调是抓不到的，而对调恰恰
    /// 是最坏的那种错——用户看到的是另一种状态的说明。
    @Test("四种状态各有各的标题，逐字钉死")
    func menuTitlesArePinned() {
        #expect(
            AppModel.translationBackendMenuTitle(.local)
                == "翻译后端：本机（文字不出这台电脑）")
        #expect(
            AppModel.translationBackendMenuTitle(.cloudIdleBecauseChinese)
                == "翻译后端：云端 Google（当前输出中文，未出站）")
        #expect(
            AppModel.translationBackendMenuTitle(.cloudMissingKey)
                == "翻译后端：云端 Google（缺 API key，未生效）")
        #expect(
            AppModel.translationBackendMenuTitle(.cloudActive)
                == "翻译后端：云端 Google（每句话都会发出）")
    }

    /// 开关那一项：开启要把后果写在按钮上，关闭不必。
    @Test("开启的按钮文案自带后果，关闭的不吓人")
    func toggleLabelCarriesTheConsequence() {
        let toOpen = AppModel.translationBackendToggleLabel(.local)
        #expect(toOpen.contains("Google"), "开启那一项没说会发给谁：\(toOpen)")
        #expect(toOpen.contains("每句话"), "开启那一项没说范围有多大：\(toOpen)")
        #expect(toOpen.hasSuffix("…"), "点它会先弹确认框，按 macOS 惯例要有省略号：\(toOpen)")

        // 已经开着的三格，按钮都是「关掉」，且不带省略号（关掉不弹框）。
        for status in [
            AppModel.TranslationBackendStatus.cloudIdleBecauseChinese, .cloudMissingKey, .cloudActive,
        ] {
            let label = AppModel.translationBackendToggleLabel(status)
            #expect(label.contains("关闭云端翻译"), "\(status) 的按钮不是关掉：\(label)")
            #expect(!label.hasSuffix("…"), "关掉是一步到位的，不该有省略号：\(label)")
        }
    }

    /// **三种「不出站」的状态各自要把「现在不出站」说出来。**
    ///
    /// 这是用户会误解的地方：开关开着不等于正在往外发。只印一个「开」的话，
    /// 用户会以为自己说的话正在发给 Google（而事实是中文那格零出站）；
    /// 缺 key 那格更糟——用户会以为翻译在工作。
    @Test("不出站的三格都把「现在不会出站」说出来")
    func quietStatesSayTheyAreQuiet() {
        let local = AppModel.translationBackendDetailLines(status: .local, target: .chinese)
            .joined(separator: "\n")
        #expect(local.contains("不出这台电脑"), "本机那格没说清文字不出站：\(local)")
        #expect(local.contains("译成什么") && local.contains("谁来译"), "没说清两个开关是两件事：\(local)")

        let idle = AppModel.translationBackendDetailLines(
            status: .cloudIdleBecauseChinese, target: .chinese
        ).joined(separator: "\n")
        #expect(
            idle.contains("一个字节都不会离开本机"),
            "云端开着但输出中文的那格没说清此刻零出站，用户会以为正在往外发：\(idle)")
        #expect(idle.contains("换成外语"), "没说清什么时候才会开始出站：\(idle)")

        let missing = AppModel.translationBackendDetailLines(
            status: .cloudMissingKey, target: .english
        ).joined(separator: "\n")
        #expect(missing.contains("退回中文原文"), "缺 key 那格没说清每次听写会发生什么：\(missing)")
        #expect(missing.contains("不会发出任何请求"), "缺 key 那格没说清仍然零出站：\(missing)")
        // 要能照着做，不必去翻文档——与挂载时那条日志同一个取向。
        #expect(missing.contains("security add-generic-password"), "缺 key 那格没给存 key 的命令：\(missing)")
        #expect(missing.contains(TranslationKey.geminiService), "存 key 的命令里服务名不对：\(missing)")
    }

    /// **会出站的那一格要把话说完**，而且这句话只出现在这一格。
    ///
    /// 「现在每说一句话」是现在时的断言，不是「将来会怎样」——另外三格里
    /// 一次都不许出现（`cloudIdleBecauseChinese` 那格提到「换成外语之后
    /// 才会发到 Google」是将来时，不是这一句）。
    @Test("会出站的那格说清发生什么，且这句话只在这一格出现")
    func activeStateSpellsOutTheEgress() {
        let active = AppModel.translationBackendDetailLines(status: .cloudActive, target: .spanish)
            .joined(separator: "\n")
        #expect(active.contains("现在每说一句话"), "没说清是每一句而不是偶尔：\(active)")
        #expect(active.contains("Google 的服务器"), "没说清发给谁：\(active)")
        #expect(active.contains("报价"), "没提用户明确说过的那类机密内容：\(active)")
        #expect(active.contains("切回中文"), "没给用户一条立刻停止出站的路：\(active)")
        #expect(active.contains("转写与校正始终在本机"), "没说清哪些层不受影响，用户会以为整条链都上云了：\(active)")
        #expect(active.contains(TranslationTarget.spanish.displayName), "没说清现在译成哪种语言：\(active)")

        for status in [
            AppModel.TranslationBackendStatus.local, .cloudIdleBecauseChinese, .cloudMissingKey,
        ] {
            let text = AppModel.translationBackendDetailLines(status: status, target: .english)
                .joined(separator: "\n")
            #expect(
                !text.contains("现在每说一句话"),
                "\(status) 这一格不出站，却写着正在往外发：\(text)")
        }
    }

    /// 四格的说明行两两不同。防的是「文案退化成同一句」。
    @Test("四格的说明行两两不同")
    func detailLinesAreDistinct() {
        let texts = [
            AppModel.TranslationBackendStatus.local, .cloudIdleBecauseChinese, .cloudMissingKey,
            .cloudActive,
        ].map {
            AppModel.translationBackendDetailLines(status: $0, target: .english).joined(separator: "\n")
        }
        #expect(Set(texts).count == texts.count)
    }

    /// 确认框的文案：**三件事缺一不可。**
    ///
    /// 发生什么（每句话发到 Google）、什么时候不发生（输出中文时零出站）、
    /// 什么不受影响（转写与校正始终在本机）。少任何一件，用户都会做出错的
    /// 判断——尤其是第二件：不说的话，用户会以为开了就再也停不下来。
    @Test("开启云端的确认框把三件事都说清了")
    func confirmationSpellsOutTheDeal() {
        let copy = AppModel.cloudBackendConfirmation
        let all = copy.title + "\n" + copy.message

        #expect(all.contains("Google"), "没说发给谁：\(all)")
        #expect(all.contains("每一句话") || all.contains("每句话"), "没说是每一句：\(all)")
        #expect(all.contains("报价"), "没提用户明确说过的那类机密内容：\(all)")
        #expect(all.contains("不会有任何文字离开本机"), "没说清输出中文时零出站：\(all)")
        #expect(all.contains("转写与校正始终在本机"), "没说清哪些层不受影响：\(all)")
        #expect(all.contains("随时可以在同一处关掉"), "没说清怎么反悔：\(all)")

        // 按钮文案要能单独读懂：一个写着「好」的按钮什么都没告诉用户。
        #expect(copy.confirmButton.contains("开启云端翻译"))
        #expect(copy.cancelButton == "取消")
        #expect(copy.confirmButton != copy.cancelButton)
    }
}

/// 云端开关的接线，用**扫源码**钉住——与 `AppModelWiringTests` 同一个取向。
///
/// 扫源码只能证明「那行代码在 / 不在」，证明不了语义；语义由上面那套用例与
/// `CloudEgressTests` 负责。这里守的是三件在别处测不到的事：菜单不许自己拼
/// 文案、菜单不许读 Keychain、开启不许跳过确认。
@Suite("云端开关的接线")
struct CloudBackendWiringTests {
    private static func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // vInputTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // 仓库根
        return try String(
            contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 菜单文案必须来自那三个纯函数。
    ///
    /// 在视图里拼字符串的话，上面整套用例一条都不会红，而用户看到的是另一
    /// 套文案——`AppModel` 在测试进程里起不来（init 就要真快捷键、真 CGEvent
    /// tap），视图里的那份没有任何东西守得住。
    @Test("菜单标题与说明行都走纯函数，不在视图里拼")
    func menuUsesPureFunctions() throws {
        // **先算成 Bool 再断言**，不要把整份源码交给 `#expect`：那样一旦红了，
        // 失败输出里会原样打出整个文件，连那条 ✘ 行都被埋掉——变异验证时
        // 「数不到红行」和「真的没红」就分不开了（第 8 条的同款）。
        let view = try Self.source("Sources/vInput/App/vInputApp.swift")
        let usesTitle = view.contains("AppModel.translationBackendMenuTitle(")
        let usesDetail = view.contains("AppModel.translationBackendDetailLines(")
        let usesToggle = view.contains("AppModel.translationBackendToggleLabel(")
        #expect(usesTitle, "翻译后端子菜单的标题不是从纯函数来的")
        #expect(usesDetail, "翻译后端子菜单的说明行不是从纯函数来的")
        #expect(usesToggle, "开关那一项的文案不是从纯函数来的")
    }

    /// **菜单不许读 Keychain。**
    ///
    /// `TranslationKey.read` 读的是登录 Keychain。用
    /// `security add-generic-password` 存进去的条目，ACL 里没有本 app，
    /// 头一次读会弹系统授权对话框——而菜单是用户每天点很多次的东西。
    /// 状态改从协调器的镜像来（`cloudKeyPresent`，一次 `apply()` 至多读一次，
    /// 且只在真要走云端时读）。
    ///
    /// 读整份文件做 `contains` 而不是逐行 grep：跨行写法行式匹配看不见——
    /// 本仓库一天栽过三次这个坑。
    @Test("菜单与 AppModel 都不直接读 Keychain")
    func menuNeverReadsKeychain() throws {
        for path in ["Sources/vInput/App/vInputApp.swift", "Sources/vInput/App/AppModel.swift"] {
            let readsKeychain = try Self.source(path).contains("TranslationKey.read")
            #expect(
                !readsKeychain,
                """
                \(path) 里直接读了 Keychain。菜单每打开一次就可能弹一次系统
                授权框，而这个状态本来就有镜像可读
                （TranslationAttachmentCoordinator.cloudKeyPresent）。
                """
            )
        }
    }

    /// **开启云端必须先弹确认，且确认在写偏好之前。**
    ///
    /// 顺序反了的话，用户点了取消，云端也已经开着了。
    @Test("开启云端前先弹确认，确认排在写偏好之前")
    func enablingRequiresConfirmation() throws {
        let source = try Self.source("Sources/vInput/App/AppModel.swift")
        guard let start = source.range(of: "func toggleCloudBackend()") else {
            Issue.record("找不到 toggleCloudBackend，这个测试的锚点失效了")
            return
        }
        // 函数体只有二十来行，取一段足够长的窗口即可。
        let body = String(source[start.lowerBound...].prefix(1200))
        let confirm = try #require(
            body.range(of: "confirmCloudBackend?()"),
            "toggleCloudBackend 里没有确认这一步——开启云端成了一次普通的开关切换")
        let write = try #require(
            body.range(of: "usesCloudBackend = true"),
            "toggleCloudBackend 里找不到写偏好那一句，锚点失效了")
        #expect(
            confirm.lowerBound < write.lowerBound,
            "确认排在写偏好之后：用户点了取消，云端却已经开着了")
    }

    /// 菜单状态由**协调器算出来的挂载结论**推出，不是抄偏好里的布尔值。
    ///
    /// 抄布尔值的话，「云端开 + 输出中文」这一格会显示成正在出站，而真实
    /// 行为是零出站——菜单就在骗人，而 `CloudBackendMenuTests` 那张真值表
    /// 也守不住它（那套跑的是纯函数，跑不到 `AppModel` 的接线）。
    @Test("菜单状态从挂载结论推出，不是抄偏好")
    func statusComesFromTheAttachmentDecision() throws {
        let composed = try Self.source("Sources/vInput/App/AppModel.swift")
            .contains("attachment: translationCoordinator.attachment")
        #expect(
            composed,
            """
            syncTranslationMirrors 没把协调器的挂载结论喂给 translationBackendStatus。
            菜单说的话必须与决定行为的那个判断同源。
            """
        )
    }
}
