import Foundation
import Testing

@testable import vInput

@Suite("输出语言偏好")
struct TranslationPreferenceTests {
    /// 每条用例一个独立 suite：`UserDefaults.standard` 是进程级共享的，
    /// 用它会让并行跑的用例互相污染，而症状是「单跑绿、全量偶尔红」。
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "vinput.translation.tests.\(UUID().uuidString)")!
    }

    /// **默认中文＝不翻译。** 翻译要额外加载一个 2 GB 级模型并给每句话多加
    /// 几秒推理，用户没主动选之前不该承担这些成本。
    @Test("默认是中文，即不翻译")
    func defaultsToChinese() {
        let preference = TranslationPreference(defaults: makeDefaults())
        #expect(preference.outputLanguage == .chinese)
        // 顺带把「中文就是不翻译」这条语义钉住：默认值换成任何
        // requiresTranslation == true 的语言，本行都会红。
        #expect(preference.outputLanguage.requiresTranslation == false)
    }

    @Test("设置后能读回")
    func roundTrips() {
        let preference = TranslationPreference(defaults: makeDefaults())
        preference.outputLanguage = .spanish
        #expect(preference.outputLanguage == .spanish)
    }

    /// 存稳定字符串而不是枚举序号——加一种语言不该把用户已保存的设置挪到
    /// 别的语言上。存序号的话在中间插一格就全错位。
    @Test("存的是稳定标识符")
    func storesStableIdentifier() {
        let defaults = makeDefaults()
        let preference = TranslationPreference(defaults: defaults)
        preference.outputLanguage = .german
        #expect(defaults.string(forKey: "translation.outputLanguage") == "de")
    }

    /// 存了个不认识的值（应用降级回旧版本、或用户手改 plist）时退回中文。
    ///
    /// **退回中文而不是崩掉、也不是退回上一次的外语**：中文是唯一不会把
    /// 用户没要的语言注进输入框的取值。
    @Test("无法识别的值退回中文")
    func fallsBackOnUnknownValue() {
        let defaults = makeDefaults()
        defaults.set("klingon", forKey: "translation.outputLanguage")
        #expect(TranslationPreference(defaults: defaults).outputLanguage == .chinese)
    }

    /// 云端默认关。**这条的理由和校正默认关不同**：那边是成本，这边是出站。
    /// 本工具把文字直接注进用户即将发出的窗口，默认值必须是「什么都不出去」。
    @Test("云端后端默认关闭")
    func cloudDefaultsOff() {
        #expect(TranslationPreference(defaults: makeDefaults()).usesCloudBackend == false)
    }

    /// 两个开关落在**两个不同的键**上，互不影响。
    ///
    /// 这不是吹毛求疵：用户 2026-08-19 专门强调「要不要翻译」与「要不要用
    /// 云端」是两个正交的开关。若哪天有人把它们并成一个键（比如
    /// `translation.mode = "cloud-spanish"`），本条会红。
    @Test("两个开关互不干扰")
    func switchesAreIndependent() {
        let defaults = makeDefaults()
        let preference = TranslationPreference(defaults: defaults)

        preference.usesCloudBackend = true
        #expect(preference.outputLanguage == .chinese, "开云端不该顺手改了输出语言")

        preference.outputLanguage = .spanish
        #expect(preference.usesCloudBackend, "改语言不该顺手关了云端")

        preference.usesCloudBackend = false
        #expect(preference.outputLanguage == .spanish, "关云端不该顺手改了输出语言")
    }

    /// 模型目录默认为 nil——**今天没有任何入口会去设它**。
    ///
    /// 这条不是在测「nil 就是 nil」，它是 `AppModel.translationAttachment`
    /// 那套退回逻辑的前提：默认 nil 意味着「照着没配就 return 写」会让
    /// 用户选完西班牙文什么都不发生。这条红了说明前提变了，退回逻辑要重看。
    @Test("模型目录默认未指定")
    func modelDirectoryDefaultsToNil() {
        #expect(TranslationPreference(defaults: makeDefaults()).modelDirectory == nil)
    }
}

/// 翻译层「该挂什么」的判断。
///
/// 之所以能测，是因为判断被抽成了 `AppModel` 上的 `nonisolated static`
/// 纯函数——`AppModel` 本身在测试进程里起不来（init 就要真快捷键、真
/// CGEvent tap）。要守的恰恰是**四种组合都不能错**的那张表。
@Suite("翻译层挂载判断")
struct TranslationAttachmentTests {
    private let translationDir = URL(fileURLWithPath: "/models/translate")
    private let correctionDir = URL(fileURLWithPath: "/models/correct")

    /// - Parameter directoryIsUsable: 目录校验的判据。**默认放行**，因为下面
    ///   那几条路由用例给的是 `/models/…` 这种不存在的假路径——它们要测的是
    ///   「四种组合各挂什么」，不是文件系统。真判据（
    ///   `CorrectionModelCatalog.validate`）由
    ///   `TranslationAttachmentCoordinator` 提供，且它确实会被用上这件事由
    ///   `TranslationAttachmentCoordinatorTests` 里那条拿**真临时目录**跑的
    ///   用例守着。生产函数本身**不给**这个参数默认值，见它的注释。
    private func attachment(
        target: TranslationTarget,
        cloud: Bool = false,
        translationDirectory: URL? = nil,
        correctionDirectory: URL? = nil,
        directoryIsUsable: @escaping (URL) -> Bool = { _ in true }
    ) -> AppModel.TranslationAttachment {
        AppModel.translationAttachment(
            target: target,
            usesCloudBackend: cloud,
            translationModelDirectory: translationDirectory,
            correctionModelDirectory: correctionDirectory,
            isUsableModelDirectory: directoryIsUsable
        )
    }

    // MARK: - 那张 2×2 表，逐格钉死

    /// | 中文 | 云端关 | 翻译层完全不参与 | 零出站 |
    @Test("中文 + 云端关：摘掉")
    func chineseLocalDetaches() {
        #expect(attachment(target: .chinese, correctionDirectory: correctionDir) == .detach)
    }

    /// | 中文 | **云端开** | **同上——一个字节都不出站** |
    ///
    /// **这一格是整张表里最容易漏的。** 用户可能为某次需要打开过云端、之后
    /// 忘了关；只要输出语言是中文，就不该有任何东西出站，也不该弹任何与
    /// 云端有关的提示。
    ///
    /// 它同时是「先判语言、后判后端」这条顺序的**唯一机械守卫**：把
    /// `translationAttachment` 里那两个判断对调，本条立刻变成 `.cloud`
    /// ——2026-08-19（Task 13）实测确认这条仍然有牙口，云端真正落地之后
    /// 它守的东西从「返回值不同」变成了「真会发出一条请求」。
    /// **期望值不变，仍是 `.detach`**：对调之后不许去迁就它。
    @Test("中文 + 云端开：仍然摘掉，云端开关一个字节都不该出站")
    func chineseWithCloudStillDetaches() {
        #expect(
            attachment(target: .chinese, cloud: true, correctionDirectory: correctionDir)
                == .detach
        )
        // 六种外语一格不漏地反过来验一次：语言是外语时云端开关**必须**被读到。
        // 只测中文那一格的话，「顺序对调」在外语侧不会被发现。
        for target in TranslationTarget.allCases where target.requiresTranslation {
            #expect(
                attachment(target: target, cloud: true, correctionDirectory: correctionDir)
                    == .cloud,
                "\(target.rawValue) 开了云端却走进了本地分支"
            )
        }
    }

    /// | 外语 | 云端关 | 本地 MLXTranslator | 零出站 |
    @Test("外语 + 云端关：挂本地")
    func foreignLocalAttaches() {
        #expect(
            attachment(target: .spanish, translationDirectory: translationDir)
                == .local(directory: translationDir)
        )
    }

    /// | 外语 | 云端开 | 云端 `GeminiTranslator` | 有出站 |
    @Test("外语 + 云端开：走云端分支")
    func foreignCloudRoutesToCloud() {
        #expect(
            attachment(target: .spanish, cloud: true, translationDirectory: translationDir)
                == .cloud
        )
    }

    // MARK: - 模型目录：退回校正层，且绝不静默

    /// **翻译没配自己的目录时退回校正层的。**
    ///
    /// 依据是 M8 第 0 步实测：翻译后端定成 `qwen3-4b-instruct-2507-4bit`，
    /// 正是校正层在用的同一个模型。这也是 `ModelContainerRegistry` 能省下
    /// 一份 2 GB 权重的前提——同一个目录 → 同一个键 → 同一份权重。
    ///
    /// 把退回逻辑删掉（回到「没配就 return」）时本条会红。
    @Test("翻译目录没配时退回校正层的目录")
    func fallsBackToCorrectionDirectory() {
        #expect(
            attachment(target: .english, correctionDirectory: correctionDir)
                == .local(directory: correctionDir)
        )
    }

    /// 两个都配了时**翻译自己的优先**——将来用户可能给翻译单独指一个模型。
    @Test("翻译目录优先于校正目录")
    func translationDirectoryWins() {
        #expect(
            attachment(
                target: .english,
                translationDirectory: translationDir,
                correctionDirectory: correctionDir
            ) == .local(directory: translationDir)
        )
    }

    /// **两个都没配时必须是 `.unconfigured`，不能是 `.detach`。**
    ///
    /// 这条是本任务修掉的那个 bug 的守卫。返回 `.detach` 的话，用户在菜单里
    /// 选完「西班牙文」什么都不会发生、也没有任何提示，而菜单上还写着
    /// 「输出语言：西班牙文」——正是本仓库反复栽的那类「静默不工作」
    /// （M6 ③ 修掉的同一形态）。
    ///
    /// **两种取值在调用方那边是天差地别**：`.detach` 什么都不说，
    /// `.unconfigured` 要记日志、要点亮菜单后缀、要弹 HUD。
    @Test("两个目录都没配时不许静默")
    func unconfiguredIsNotSilent() {
        for target in TranslationTarget.allCases where target.requiresTranslation {
            #expect(
                attachment(target: target) == .unconfigured,
                "\(target.rawValue) 缺目录时被静默摘掉了"
            )
        }
        // 中文不受影响：它压根不该被当成「缺配置」。
        #expect(attachment(target: .chinese) == .detach)
    }

    /// **配过但已失效的目录，与没配是同一件事。**
    ///
    /// 借了校正层的目录就得借它的校验：
    /// `CorrectionActivation.revalidateAtLaunch()` 遇到失效目录时只把校正
    /// 开关落回「关」、**不清 `modelDirectory`**，翻译层照旧拿得到那条死路径。
    /// 挂上去的表现是每次听写 HUD 都说「翻译模型还在加载」，而
    /// `OneShotLoader` 失败不缓存、预热只跑一次，那个加载永远不会完成。
    @Test("目录失效时不许挂本地，落回缺目录那一格")
    func unusableDirectoryIsUnconfigured() {
        #expect(
            attachment(
                target: .spanish,
                correctionDirectory: correctionDir,
                directoryIsUsable: { _ in false }
            ) == .unconfigured
        )
        // 翻译自己的目录也一样，**不会悄悄改选校正层那个**：
        // 「我指了 A 却在用 B」比「A 坏了，告诉我」更难排查。
        #expect(
            attachment(
                target: .spanish,
                translationDirectory: translationDir,
                correctionDirectory: correctionDir,
                directoryIsUsable: { $0 != self.translationDir }
            ) == .unconfigured
        )
    }

    /// **云端那一格不碰本地目录，一次都不该去校验。**
    ///
    /// 云端不需要本地权重。拿本地目录的死活去拦一条根本不读它的路径是纯
    /// 误杀，而校验要碰文件系统——每次 `apply()` 白付一次目录遍历。
    /// 中文那一格同理：它连翻译都不做。
    @Test("云端与中文这两格不去校验本地目录")
    func cloudAndChineseSkipDirectoryValidation() {
        var validated: [URL] = []
        let spy: (URL) -> Bool = { validated.append($0); return true }

        #expect(
            attachment(
                target: .spanish, cloud: true,
                correctionDirectory: correctionDir, directoryIsUsable: spy
            ) == .cloud
        )
        #expect(
            attachment(
                target: .chinese, correctionDirectory: correctionDir, directoryIsUsable: spy
            ) == .detach
        )
        #expect(validated.isEmpty, "去校验了本地目录：\(validated)")
    }

    /// 缺目录的判断**排在云端之后**：选了云端时本地目录压根不相关。
    @Test("选了云端时不因为缺本地目录而报未配置")
    func cloudDoesNotNeedLocalDirectory() {
        #expect(attachment(target: .english, cloud: true) == .cloud)
    }

    // MARK: - 菜单标题

    /// 缺目录时标题带后缀。不带的话它恰好在骗人——用户看到
    /// 「输出语言：西班牙文」，得到的却是中文。
    @Test("缺模型目录时菜单标题带后缀")
    func menuTitleFlagsMissingModel() {
        let normal = AppModel.outputLanguageMenuTitle(target: .spanish, modelMissing: false)
        let missing = AppModel.outputLanguageMenuTitle(target: .spanish, modelMissing: true)
        #expect(normal == "输出语言：西班牙文")
        #expect(missing != normal, "缺目录时标题必须和正常时不同")
        #expect(missing.hasPrefix(normal), "后缀式提示，不要重排标题")
        #expect(missing.contains("模型"), "要说清缺的是什么")
    }

    @Test("每种语言的标题都带自己的显示名")
    func menuTitleNamesEveryLanguage() {
        for target in TranslationTarget.allCases {
            #expect(
                AppModel.outputLanguageMenuTitle(target: target, modelMissing: false)
                    .contains(target.displayName),
                "\(target.rawValue) 的标题里没有它的显示名"
            )
        }
    }
}

/// 菜单项上的质量提示。
///
/// 用户 2026-08-19 的决定是「六种全上，但要标出差异」，理由是让用户自己
/// 判断什么场合用哪种。
@Suite("目标语言的实测质量")
struct TranslationQualityTests {
    /// **六种全部测过，数值逐个钉死。**
    ///
    /// 2026-08-19 六语对照（26 条 × 6 种 = 156 次推理，零失败）。
    /// 取的是**忽略大小写**那一版——理由见 `TranslationQuality` 的注释：
    /// 逐字判据会把德语名词大写记成术语丢失，于是菜单上的等级是反的。
    ///
    /// 这条同时是「不许编数」的守卫：把任何一个值改掉都会红。
    /// 它此前钉的是「只有英西德三种有数据」，而那一版里德语写的 0.89
    /// 来自只跑了 10 条的小样本——全量跑完是 0.84（逐字）/ 1.00（忽略大小写），
    /// **小样本乐观与判据选错两个问题同时暴露**。
    @Test("六种语言的实测值逐个钉死")
    func allSixAreMeasured() {
        var measured: [String: Double] = [:]
        for target in TranslationTarget.allCases {
            if case .measured(let retention) = target.quality {
                measured[target.rawValue] = retention
            }
        }
        #expect(
            measured == [
                "en": 1.00, "de": 1.00, "it": 1.00,
                "fr": 0.98, "pt": 0.96, "es": 0.94,
            ]
        )
    }

    /// **一个术语约值 0.02，所以这些数读不出排名。**
    ///
    /// 26 条里只有 9 条含技术术语、合计约 50 个。这条钉的是「全部在 0.94
    /// 以上」——那是这批数据真正读得出来的唯一一句话。谁把某一格改到明显
    /// 更低而没有新的实测支撑，它就会红。
    @Test("六种都在可用区间内")
    func allSixAreUsable() {
        for target in TranslationTarget.allCases where target.requiresTranslation {
            guard case .measured(let retention) = target.quality else {
                Issue.record("\(target.rawValue) 还没有实测数据")
                continue
            }
            #expect(retention >= 0.94, "\(target.rawValue) 掉出了可用区间")
        }
    }

    /// 中文单独一格：它是「不翻译」，谈不上质量。
    @Test("中文是 notApplicable，不是 unmeasured")
    func chineseIsNotApplicable() {
        #expect(TranslationTarget.chinese.quality == .notApplicable)
        // 反过来钉住：任何需要翻译的语言都不该是 notApplicable。
        for target in TranslationTarget.allCases where target.requiresTranslation {
            #expect(
                target.quality != .notApplicable,
                "\(target.rawValue) 要翻译，却被标成「无所谓质量」"
            )
        }
    }

    /// **加一种语言却忘了定级，会被机械地抓到。**
    ///
    /// 两道：`TranslationTarget.quality` 是穷尽 switch（加一格编译不过），
    /// 而「随手标成 `.unmeasured` 蒙过编译器」由本条拦——每种语言都必须在
    /// 菜单文案里露出自己的质量档位，`unmeasured` 那档写着「未实测」，
    /// 用户看得见，加语言的人也就赖不掉。
    @Test("每种语言的菜单文案都说清了自己的档位")
    func menuLabelStatesQuality() {
        for target in TranslationTarget.allCases {
            let label = target.menuLabel
            #expect(label.contains(target.displayName), "\(target.rawValue) 文案里没有语言名")
            switch target.quality {
            case .notApplicable:
                #expect(label.contains("不翻译"), "中文那格要说清选它等于关掉翻译")
            case .measured(let retention):
                #expect(
                    label.contains(String(format: "%.2f", retention)),
                    "\(target.rawValue) 文案里没有实测值"
                )
            case .unmeasured:
                #expect(label.contains("未实测"), "\(target.rawValue) 没标出「未实测」")
            }
        }
    }

    /// 六种语言的文案两两不同。
    ///
    /// 防的是「文案退化成同一句」：把 `menuLabel` 写成 `displayName` 就红。
    @Test("七种文案两两不同")
    func menuLabelsAreDistinct() {
        let labels = TranslationTarget.allCases.map(\.menuLabel)
        #expect(Set(labels).count == labels.count)
    }

    /// **实测值不许高于 1.0。** 术语保留是个比例，超过 1 只能是打错。
    @Test("实测值落在合理区间")
    func measuredValuesAreRatios() {
        for target in TranslationTarget.allCases {
            if case .measured(let retention) = target.quality {
                #expect(retention > 0 && retention <= 1.0, "\(target.rawValue) 的实测值不是比例")
            }
        }
    }
}

/// 菜单上「翻译在用哪个模型」那一行。
///
/// 用户 2026-08-19 提的：他看不出翻译用的是哪个大模型。这一行是唯一的
/// 答案，**它说错就等于骗人**。
@Suite("翻译模型的菜单文案")
struct TranslationModelMenuLineTests {
    /// **「跟随校正」这四个字不能省。**
    ///
    /// 不写的话，用户换校正模型时翻译也跟着变，而他完全无从预料——
    /// 两个菜单看起来是两件事。把这四个字删掉，本条会红。
    @Test("借用校正目录时要说清是跟随来的")
    func inheritedSaysSo() {
        let line = AppModel.translationModelMenuLine(
            name: "qwen3-4b-instruct-2507-4bit", inherited: true)
        #expect(line.contains("qwen3-4b-instruct-2507-4bit"))
        #expect(line.contains("跟随校正"), "没说清这个目录是从校正那儿借的")
    }

    /// 单独指定过就不能再说「跟随」——那时换校正模型翻译不会变。
    @Test("单独指定时不说跟随")
    func explicitDoesNotClaimInheritance() {
        let line = AppModel.translationModelMenuLine(
            name: "qwen2.5-7b-instruct-4bit", inherited: false)
        #expect(line.contains("qwen2.5-7b-instruct-4bit"))
        #expect(!line.contains("跟随"), "明明是单独指定的，却说成跟随校正")
    }

    /// 两种状态的文案必须不同。
    ///
    /// 防的是「把 inherited 参数收下但不用」——那样两条断言各自看着都过，
    /// 而菜单永远显示同一句话。本仓库栽过八次这类空断言。
    @Test("两种状态的文案不一样")
    func twoStatesDiffer() {
        let same = "qwen3-4b-instruct-2507-4bit"
        #expect(
            AppModel.translationModelMenuLine(name: same, inherited: true)
                != AppModel.translationModelMenuLine(name: same, inherited: false)
        )
    }

    /// 没有可用目录时要给出**去哪儿配**，不能只说「未指定」。
    ///
    /// 这是 M6 ③ 那条教训的延伸：只说「没有」而不说「怎么办」，
    /// 用户看到的仍然只是「没变化」。
    @Test("没有目录时说清去哪儿配")
    func missingTellsWhereToConfigure() {
        let line = AppModel.translationModelMenuLine(name: nil, inherited: true)
        #expect(line.contains("校正"), "没告诉用户可以在校正菜单里指定")
        // 没有目录时不该冒出一个模型名。
        #expect(!line.contains("qwen"))
    }
}

/// 菜单上的模型名从哪儿来。
@Suite("翻译模型的镜像")
struct TranslationModelMirrorTests {
    private let explicit = URL(fileURLWithPath: "/models/translate")
    private let inheritedDir = URL(fileURLWithPath: "/models/correct")

    /// **从挂载结论取，不从偏好取。**
    ///
    /// 用户指定过一个目录、但它已失效、实际退回了校正层的那个——
    /// 读偏好的话菜单显示前者而跑的是后者。这条钉的就是这个差别：
    /// 偏好里写着 `/models/translate`，挂载结论却是 `/models/correct`，
    /// 菜单必须说后者。
    @Test("显示的是实际挂上的目录，不是偏好里写的")
    func showsWhatActuallyAttached() {
        let mirror = AppModel.translationModelMirror(
            attachment: .local(directory: inheritedDir), explicitDirectory: explicit)
        #expect(mirror.name == "correct", "显示的是偏好里的目录，而不是真正挂上的")
    }

    /// 没单独指定时算「跟随」。
    @Test("偏好为空时算跟随校正")
    func nilPreferenceMeansInherited() {
        let mirror = AppModel.translationModelMirror(
            attachment: .local(directory: inheritedDir), explicitDirectory: nil)
        #expect(mirror.name == "correct")
        #expect(mirror.inherited)
    }

    /// 单独指定过就不算跟随。
    @Test("偏好非空时不算跟随")
    func explicitPreferenceIsNotInherited() {
        let mirror = AppModel.translationModelMirror(
            attachment: .local(directory: explicit), explicitDirectory: explicit)
        #expect(mirror.name == "translate")
        #expect(!mirror.inherited)
    }

    /// 没挂本机模型的三种结论都不该冒出模型名。
    ///
    /// **`.cloud` 那一格尤其要紧**：走云端时本机模型不参与任何事，
    /// 菜单上摆一个模型名会让人以为云端也在用它。
    @Test("没挂本机模型时不显示模型名")
    func nonLocalAttachmentsHaveNoName() {
        for attachment: AppModel.TranslationAttachment in [.detach, .cloud, .unconfigured] {
            #expect(
                AppModel.translationModelMirror(
                    attachment: attachment, explicitDirectory: explicit).name == nil,
                "\(attachment) 也显示了模型名"
            )
        }
    }
}
