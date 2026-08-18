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

    private func attachment(
        target: TranslationTarget,
        cloud: Bool = false,
        translationDirectory: URL? = nil,
        correctionDirectory: URL? = nil
    ) -> AppModel.TranslationAttachment {
        AppModel.translationAttachment(
            target: target,
            usesCloudBackend: cloud,
            translationModelDirectory: translationDirectory,
            correctionModelDirectory: correctionDirectory
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
    /// `translationAttachment` 里那两个判断对调，本条立刻变成
    /// `.cloudNotImplemented`。
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
                    == .cloudNotImplemented,
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

    /// | 外语 | 云端开 | 云端（本轮未实现） | 有出站 |
    @Test("外语 + 云端开：走云端分支")
    func foreignCloudRoutesToCloud() {
        #expect(
            attachment(target: .spanish, cloud: true, translationDirectory: translationDir)
                == .cloudNotImplemented
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

    /// 缺目录的判断**排在云端之后**：选了云端时本地目录压根不相关。
    @Test("选了云端时不因为缺本地目录而报未配置")
    func cloudDoesNotNeedLocalDirectory() {
        #expect(attachment(target: .english, cloud: true) == .cloudNotImplemented)
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
    /// **实测过的正好是这三种，数值逐个钉死。**
    ///
    /// 这条是「不许编数」的守卫：M8 第 0 步只跑了英/西/德三种，谁把葡/法/意
    /// 随手标成 `.measured(...)` 都会在这里红。数值本身也钉死——把 0.89 改成
    /// 0.95 让德语看起来好一点，同样红。
    ///
    /// 数据来源：`Bench/reports/m8-step0/`（已 gitignore，报告在开发机上）。
    @Test("只有英西德三种有实测数据，数值逐个钉死")
    func onlyThreeAreMeasured() {
        var measured: [String: Double] = [:]
        for target in TranslationTarget.allCases {
            if case .measured(let retention) = target.quality {
                measured[target.rawValue] = retention
            }
        }
        #expect(measured == ["en": 1.00, "es": 0.92, "de": 0.89])
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
