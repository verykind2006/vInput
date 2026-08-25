# 输入语言可选 + 翻译全矩阵——实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用户可在面板指定说话语言（中/英/西/德/葡/法/意），转写按该语言解码；翻译目标变为「不翻译 | 译成任一语种」全矩阵（含新增的 X→中文）。

**Architecture:** `TranslationTarget` 提升为全应用共享的 `Language` 枚举；「不翻译」剥离成 `TranslationChoice.off`；管线各中文假设点（ASR prompt、繁→简、拼音校正、数词改写、闸门）全部按 `(输入, 目标)` 二元组分流，无 `default` 的穷尽 switch。设计定稿：`docs/superpowers/specs/2026-08-25-input-language-full-matrix-design.md`。

**Tech Stack:** Swift 6 / SwiftPM / Swift Testing（`#expect`）/ WhisperKit（vendor，只读）/ MLX。

---

## 全局纪律（每个任务都适用）

1. **变异验证是强制的。** 每写一条测试，故意把被测判据改坏、跑一遍、确认对应用例真的红、再改回来。变异被抓的形态有三种：断言失败、**编译错误**、不收敛的挂起——只 grep "Expectation failed" 会漏后两种。抓不到就明说抓不到，写进任务汇报的变异表；不许写自证断言假装守住了。特别怀疑：`contains("关键词")`、`!x.isEmpty`、断言自己刚设的属性、引用常量算期望值（会对变异自适应，钉死代表真实尺度的字面量）。
2. **源码扫描类测试必须防跨行。** 本仓库字符串大量跨行拼接，行式 grep 三次栽过。扫描用 `NSRegularExpression` 整文件匹配（现成范式：`AppModelWiringTests`），且注意 `contains("f()")` 会同时匹配到函数**声明**行——先切区间再找带 `self.` 前缀的调用。
3. **`swift test --filter X` 选的是整个源文件**，被跳过时照样打 "passed"——判「有没有真跑」要数逐条结果行。全量验证一律 `./scripts/test.sh`。
4. `Sources/vInput/App/vInputApp.swift` 的 **I 是大写**——`git add` 写小写会静默漏收。
5. 提交信息结尾带：`Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` 与 Claude-Session 行（沿用本仓惯例）。

---

### Task 1: 机械更名 TranslationTarget → Language

纯更名，零行为变化。单独一个提交，后续任务的 diff 才读得出语义改动。

**Files:**
- Rename: `Sources/vInput/Translate/TranslationTarget.swift` → `Sources/vInput/Translate/Language.swift`
- Rename: `Tests/vInputTests/TranslationTargetTests.swift` → `Tests/vInputTests/LanguageTests.swift`
- Modify: 所有出现 `TranslationTarget` 标识符的源文件与测试（`git grep -l` 找）

- [ ] **Step 1: 确认无冲突后全量替换**

```bash
git grep -l 'TranslationTarget' -- Sources Tests | xargs sed -i '' 's/TranslationTarget/Language/g'
git mv Sources/vInput/Translate/TranslationTarget.swift Sources/vInput/Translate/Language.swift
git mv Tests/vInputTests/TranslationTargetTests.swift Tests/vInputTests/LanguageTests.swift
```

注意：`TranslationAttachTarget`（协调器的 protocol）不含子串 `TranslationTarget`，不会被误伤；`translationTarget`（DictationSession 的小写成员）大小写敏感也不受影响。替换后 `git grep -n 'TranslationTarget'` 应为空。

- [ ] **Step 2: 全量测试**

Run: `./scripts/test.sh` — 期望：与更名前同数目全绿（当前基线 1477 条 / 179 套件）。

- [ ] **Step 3: Commit** `refactor: TranslationTarget 更名 Language——它即将同时充当输入语言`

---

### Task 2: TranslationChoice 与偏好迁移

**Files:**
- Create: `Sources/vInput/Translate/TranslationChoice.swift`
- Modify: `Sources/vInput/Translate/TranslationPreference.swift`（`outputLanguage` 属性替换为 `choice` + 迁移函数）
- Test: `Tests/vInputTests/TranslationChoiceTests.swift`（新）、`Tests/vInputTests/TranslationPreferenceTests.swift`

- [ ] **Step 1: 写失败测试**（新文件 `TranslationChoiceTests.swift`）

```swift
import Foundation
import Testing

@testable import vInput

/// 「不翻译」从「目标=中文」的巧合里剥出来之后的两态语义。
struct TranslationChoiceTests {
    @Test func storageValuesAreStable() {
        // 存储格式一旦发布就不能变，逐个钉死。
        #expect(TranslationChoice.off.storageValue == "off")
        for language in Language.allCases {
            #expect(TranslationChoice.translate(to: language).storageValue == language.rawValue)
        }
    }

    @Test func unknownStorageValueFallsBackToOff() {
        // 认不出的值退回「不翻译」——唯一不会把用户没要的语言注进输入框的取值。
        #expect(TranslationChoice(storageValue: "klingon") == .off)
        #expect(TranslationChoice(storageValue: "off") == .off)
    }

    @Test func effectiveTargetIsNilWhenSameAsInput() {
        // 目标==输入 等同不翻译：不建管线、不烧模型。
        #expect(TranslationChoice.translate(to: .english).effectiveTarget(input: .english) == nil)
        #expect(TranslationChoice.translate(to: .spanish).effectiveTarget(input: .english) == .spanish)
        #expect(TranslationChoice.translate(to: .chinese).effectiveTarget(input: .english) == .chinese)
        #expect(TranslationChoice.off.effectiveTarget(input: .chinese) == nil)
    }

    @Test func legacyZhMigratesToOff() {
        // 老用户存的 "zh" 当时的含义是「不翻译」，不是「译成中文」。
        let defaults = UserDefaults(suiteName: "test.migration.\(UUID())")!
        defaults.set("zh", forKey: "translation.outputLanguage")
        let preference = TranslationPreference(defaults: defaults)
        #expect(preference.migrateLegacyOutputLanguageIfNeeded() == true)
        #expect(preference.choice == .off)
        // 第二次调用不再迁移（新键已写入）。
        #expect(preference.migrateLegacyOutputLanguageIfNeeded() == false)
    }

    @Test func legacyForeignLanguageMigratesToTranslate() {
        let defaults = UserDefaults(suiteName: "test.migration.\(UUID())")!
        defaults.set("es", forKey: "translation.outputLanguage")
        let preference = TranslationPreference(defaults: defaults)
        #expect(preference.migrateLegacyOutputLanguageIfNeeded() == true)
        #expect(preference.choice == .translate(to: .spanish))
    }

    @Test func freshInstallNeedsNoMigrationAndDefaultsToOff() {
        let defaults = UserDefaults(suiteName: "test.migration.\(UUID())")!
        let preference = TranslationPreference(defaults: defaults)
        #expect(preference.migrateLegacyOutputLanguageIfNeeded() == false)
        #expect(preference.choice == .off)
    }
}
```

- [ ] **Step 2: 跑测试确认编译失败**（`TranslationChoice` 不存在）
- [ ] **Step 3: 实现** `TranslationChoice.swift`：

```swift
import Foundation

/// 翻译目标的两态：不翻译，或译成某语种。
///
/// **「不翻译」曾经借用「目标=中文」表示**——那是源恒为中文时代的巧合。
/// 输入语言放开后两个含义劈开：说英文选「不翻译」要出英文，而「译成中文」
/// 成了真实存在的方向。
enum TranslationChoice: Equatable, Sendable {
    case off
    case translate(to: Language)

    /// UserDefaults 里的存储值。"off" 不是任何语言的 rawValue，不会撞。
    var storageValue: String {
        switch self {
        case .off: "off"
        case .translate(let language): language.rawValue
        }
    }

    /// 读到不认识的值时退回「不翻译」——唯一不会把用户没要的语言注进
    /// 输入框的取值（与旧 `outputLanguage` 的退回同一条理由）。
    init(storageValue: String) {
        if let language = Language(rawValue: storageValue) {
            self = .translate(to: language)
        } else {
            self = .off
        }
    }

    /// 给定输入语言后的有效翻译目标；nil = 不翻译。
    /// **目标==输入时也是 nil**：译成自己说的语言是句废话，不建管线。
    func effectiveTarget(input: Language) -> Language? {
        switch self {
        case .off: nil
        case .translate(let language): language == input ? nil : language
        }
    }
}
```

`TranslationPreference` 里：删掉 `outputLanguage` 属性，加：

```swift
private enum Key {
    static let choice = "translation.choice"
    static let legacyOutputLanguage = "translation.outputLanguage"  // 只为迁移保留
    // …其余键不动
}

/// 翻译目标。默认「不翻译」——理由与旧 outputLanguage 默认中文相同：
/// 翻译要多加载一个 2 GB 级模型，用户没主动选之前不该承担。
var choice: TranslationChoice {
    get {
        guard let raw = defaults.string(forKey: Key.choice) else { return .off }
        return TranslationChoice(storageValue: raw)
    }
    nonmutating set { defaults.set(newValue.storageValue, forKey: Key.choice) }
}

/// 一次性迁移旧键。**旧键的 "zh" 含义是「不翻译」**，不能直译成
/// 「译成中文」——否则老用户升级后一开口就被翻译。返回是否真的迁移了
/// （调用方据此记日志）。新键已存在时不动任何东西。
func migrateLegacyOutputLanguageIfNeeded() -> Bool {
    guard defaults.string(forKey: Key.choice) == nil,
        let legacy = defaults.string(forKey: Key.legacyOutputLanguage)
    else { return false }
    let migrated: TranslationChoice =
        legacy == Language.chinese.rawValue
        ? .off
        : TranslationChoice(storageValue: legacy)
    defaults.set(migrated.storageValue, forKey: Key.choice)
    return true
}
```

此时 `TranslationPreferenceTests` 与所有引用 `outputLanguage` 的调用点会编译失败——**本任务先只修 Tests 与 `TranslationPreference` 自身**；`AppModel` / 协调器的调用点属于 Task 7/10，临时改法：本任务把调用点机械替换为 `choice` 的等价读法（`preference.choice.effectiveTarget(input: .chinese) ?? .chinese` 这种**临时**表达式，Task 7 会整个重写），保证每个任务结束全绿。

- [ ] **Step 4: 全量测试** `./scripts/test.sh` 全绿。
- [ ] **Step 5: 变异**（至少）：① 迁移函数里把 `legacy == "zh"` 那支改成也走 `TranslationChoice(storageValue:)`（即 zh→译成中文）——`legacyZhMigratesToOff` 必须红；② `effectiveTarget` 去掉 `language == input` 判断——`effectiveTargetIsNilWhenSameAsInput` 必须红。各自复原并记录。
- [ ] **Step 6: Commit** `feat: 翻译目标两态化（off | 译成某语种）+ 旧 "zh" 偏好迁移`

---

### Task 3: InputLanguagePreference

**Files:**
- Create: `Sources/vInput/Transcribe/InputLanguagePreference.swift`
- Test: `Tests/vInputTests/InputLanguagePreferenceTests.swift`（新）

- [ ] **Step 1: 失败测试**

```swift
import Foundation
import Testing

@testable import vInput

struct InputLanguagePreferenceTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.input-language.\(UUID())")!
    }

    @Test func defaultsToChinese() {
        #expect(InputLanguagePreference(defaults: freshDefaults()).language == .chinese)
    }

    @Test func roundTripsAndSurvivesUnknownValue() {
        let defaults = freshDefaults()
        let preference = InputLanguagePreference(defaults: defaults)
        preference.language = .english
        #expect(InputLanguagePreference(defaults: defaults).language == .english)
        defaults.set("klingon", forKey: "transcription.inputLanguage")
        // 认不出的值退回中文——中文是发布以来的行为基线。
        #expect(preference.language == .chinese)
    }
}
```

- [ ] **Step 2: 跑测试确认编译失败**
- [ ] **Step 3: 实现**（与 `TranslationPreference` 同款注入式 UserDefaults）：

```swift
import Foundation

/// 用户说的是什么语言。转写解码、校正挂载、翻译源语言都读它。
///
/// 键带 `transcription.` 前缀：它属于转写，不属于翻译——云端开关
/// 「只管翻译」那条边界（见 `TranslationPreference`）不该被它搅浑。
struct InputLanguagePreference {
    private enum Key { static let language = "transcription.inputLanguage" }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// 默认中文——发布以来的行为基线，升级不改变任何人的现状。
    /// 读到不认识的值时同样退回中文（应用降级回旧版本、或手改 plist）。
    var language: Language {
        get {
            guard let raw = defaults.string(forKey: Key.language) else { return .chinese }
            return Language(rawValue: raw) ?? .chinese
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.language) }
    }
}
```

- [ ] **Step 4: 全量测试全绿；变异**：默认值改成 `.english`——`defaultsToChinese` 红；复原。
- [ ] **Step 5: Commit** `feat: 输入语言偏好（transcription.inputLanguage，默认中文）`

---

### Task 4: 翻译 prompt 与 Translator 协议带上源语言

**Files:**
- Modify: `Sources/vInput/Translate/TranslationPrompt.swift`、`Translator.swift:51`、`MLXTranslator.swift:90,151`、`GeminiTranslator.swift:121,143`
- Test: `Tests/vInputTests/TranslationPromptTests.swift`、`Tests/vInputTests/FakeTranslator.swift` 及所有实现该协议的测试替身

- [ ] **Step 1: 失败测试**（加进 `TranslationPromptTests.swift`）

```swift
@Test func promptNamesTheSourceLanguage() {
    let prompt = TranslationPrompt.user(for: "hello", from: .english, to: .spanish)
    #expect(prompt.contains("Translate the following English text into Spanish."))
    #expect(!prompt.contains("Chinese text"))
}

@Test func chineseSourceKeepsTheOldWording() {
    // 老路径的措辞一字不变——它是 M8 实测过的那一版。
    let prompt = TranslationPrompt.user(for: "你好", from: .chinese, to: .german)
    #expect(prompt.contains("Translate the following Chinese text into German."))
}
```

- [ ] **Step 2: 确认编译失败**（`from:` 参数不存在）
- [ ] **Step 3: 实现**

`TranslationPrompt.user` 签名与首行：

```swift
static func user(
    for text: String,
    from source: Language,
    to target: Language,
    variant: Variant = .englishLanguageName
) -> String {
    """
    Translate the following \(variant.languageName(for: source)) text into \(variant.languageName(for: target)).
    …（其余三条规则与结构一字不动）
    """
}
```

`Translator` 协议：`func translate(_ text: String, from source: Language, to target: Language) async throws -> String`。`MLXTranslator` / `GeminiTranslator` 的实现与内部 `TranslationPrompt.user` 调用同步加 `from:`；`FakeTranslator` 等测试替身同步改签名。原 `user(for:target:)` 的调用点（两个翻译器）就是全部——`git grep -n 'TranslationPrompt.user'` 确认无遗漏。

注释同步：`TranslationPrompt` 顶部「调用方保证 requiresTranslation」那段改为「调用方保证 source != target」（Task 6 的管线守这条）。既有的 `differsOnlyByLanguage` / `variantsDifferOnlyByLanguageName` 扫描测试按新签名修（语言名替换判据不变，只是现在 source 也是变量——固定 source=.chinese 跑原判据，再加一组固定 target、变 source 的对称判据）。

- [ ] **Step 4: 全量测试全绿；变异**：把 `\(variant.languageName(for: source))` 硬回 `"Chinese"`——`promptNamesTheSourceLanguage` 红；复原。
- [ ] **Step 5: Commit** `feat: 翻译 prompt 与 Translator 协议带上源语言`

---

### Task 5: 闸门矩阵 + 「原文」文案

**Files:**
- Modify: `Sources/vInput/Translate/TranslationGate.swift`（`check` 加源语言 + 目标中文分支 + `TranslationRejection` 加 `noHan` + hudLabel 措辞）、`Sources/vInput/Translate/TranslationPipeline.swift`（`TranslationAnnotation.hudLabel` 六处「中文原文」→「原文」）
- Test: `Tests/vInputTests/TranslationGateTests.swift`、`Tests/vInputTests/TranslationAnnotationTests.swift`

- [ ] **Step 1: 失败测试**（加进 `TranslationGateTests.swift`）

```swift
@Test func chineseTargetRequiresHan() {
    let gate = TranslationGate()
    // 整段没译（模型把英文原样吐回来）必须拦下。
    let verdict = gate.check(
        source: "Please review the fallback logic.",
        translation: "Please review the fallback logic.",
        from: .english, to: .chinese)
    #expect(verdict == .reject(.noHan))
}

@Test func chineseTargetPassesNormalTranslationWithTerms() {
    let gate = TranslationGate()
    // 中文译文合法保留英文术语——不查拉丁残留正是我们自己的规则。
    let verdict = gate.check(
        source: "Please review the fallback logic.",
        translation: "请检查一下 fallback 逻辑。",
        from: .english, to: .chinese)
    #expect(verdict == .pass)
}

@Test func latinToLatinSkipsLengthRatio() {
    let gate = TranslationGate(minimumLengthRatio: 99)  // 极端阈值：只要读了就必拦
    // 英→西的长度比天然在 1.0 附近，1.1 阈值是 zh→拉丁语料标定的，
    // 源非中文时不启用——否则正常译文大面积误杀。
    let verdict = gate.check(
        source: "Book three tickets for Friday.",
        translation: "Reserva tres billetes para el viernes.",
        from: .english, to: .spanish)
    #expect(verdict == .pass)
}

@Test func residualHanStillFiresForLatinTargetRegardlessOfSource() {
    let gate = TranslationGate()
    let verdict = gate.check(
        source: "Confirm the deployment.",
        translation: "Confirma el despliegue 部署.",
        from: .english, to: .spanish)
    #expect(verdict == .reject(.residualHan(count: 2)))
}

@Test func rejectionLabelsSayOriginalNotChinese() {
    // 源不再恒为中文，「已退回中文原文」在英文输入下是错话。
    for rejection: TranslationRejection in [
        .residualHan(count: 1), .chinesePunctuation(count: 1),
        .truncated, .tooShort(ratio: 0.5), .noHan,
    ] {
        #expect(rejection.hudLabel.contains("已退回原文"))
        #expect(!rejection.hudLabel.contains("中文原文"))
    }
}
```

- [ ] **Step 2: 确认编译失败**（`from:` 与 `.noHan` 不存在）
- [ ] **Step 3: 实现**

`TranslationRejection` 加一格并改文案：

```swift
enum TranslationRejection: Equatable, Sendable {
    case residualHan(count: Int)
    case chinesePunctuation(count: Int)
    case truncated
    case tooShort(ratio: Double)
    /// 目标是中文而译文一个汉字都没有——多半整段没译。X→中文方向的
    /// 弱闸门，未实测（设计定稿「不装作验过」一节）。
    case noHan

    var hudLabel: String {
        switch self {
        case .residualHan: "译文里还有中文，已退回原文"
        case .chinesePunctuation: "译文里还有中文标点，已退回原文"
        case .truncated: "译文没说完，已退回原文"
        case .tooShort: "译文太短，已退回原文"
        case .noHan: "译文不像中文，已退回原文"
        }
    }
}
```

`check` 改成：

```swift
func check(
    source: String, translation: String,
    from sourceLanguage: Language, to target: Language
) -> TranslationVerdict {
    // X→中文：判据只有「须含汉字」与截断。不查拉丁残留（中文合法保留
    // 英文术语正是本项目的规则），不查长度比（未标定）。
    if target == .chinese {
        if TranslationMetrics.residualHanCount(translation) == 0 {
            return .reject(.noHan)
        }
        if !TruncationSignal.looksTruncated(source),
            TruncationSignal.looksTruncated(translation)
        {
            return .reject(.truncated)
        }
        return .pass
    }

    guard target.usesLatinScript else { return .pass }

    // 残留汉字/中文标点对**任何**源语言都成立：拉丁译文里不该有它们。
    …（residualHan、chinesePunctuation、truncated 三段原样保留）…

    // 长度比阈值 1.1 是 zh→拉丁 的 86 条语料标定的（见 defaultMinimumLengthRatio
    // 注释）；拉丁→拉丁的自然长度比就在 1.0 附近，沿用会误杀正常译文。
    // 未标定的判据不启用——这是「不装作验过」，不是漏。
    if sourceLanguage == .chinese {
        let ratio = TranslationMetrics.lengthRatio(source: source, translation: translation)
        if ratio < minimumLengthRatio { return .reject(.tooShort(ratio: ratio)) }
    }
    return .pass
}
```

`TranslationAnnotation.hudLabel` 六处「中文原文」→「原文」（modelLoading / timedOut / failed / missingAPIKey / locationNotSupported / missingLocalModel），类型注释里「每一种文案都说了中文原文」那段同步改写。既有 Gate 测试的调用点补 `from: .chinese`（行为不变），`TranslationAnnotationTests` 的样本表跟着 `noHan` 与新措辞更新——那边是穷尽 switch，加格后编译不过正是预期。

- [ ] **Step 4: 全量测试全绿；变异**：① `noHan` 判断改成 `> 0`（反向）——两条中文目标用例都红；② 删掉 `sourceLanguage == .chinese` 守卫——`latinToLatinSkipsLengthRatio` 红；③ 目标中文分支整个删掉（落到 `usesLatinScript` guard 返回 `.pass`）——`chineseTargetRequiresHan` 红。各自复原并记录。
- [ ] **Step 5: Commit** `feat: 闸门按 (源,目标) 分流——X→中文弱闸门、拉丁源跳过长度比、文案改「原文」`

---

### Task 6: TranslationPipeline 固化 (source, target)；DictationSession 简化

**Files:**
- Modify: `Sources/vInput/Translate/TranslationPipeline.swift`、`Sources/vInput/Session/DictationSession.swift:249,326`、`Sources/vInput/App/TranslationAttachmentCoordinator.swift:14`（protocol 签名）
- Test: `Tests/vInputTests/TranslationPipelineTests.swift`、`Tests/vInputTests/DictationTranslationTests.swift`

- [ ] **Step 1: 失败测试**（加进 `TranslationPipelineTests.swift`；`FakeTranslator` 记录收到的参数）

```swift
@Test func numeralRewriteOnlyForChineseSource() async {
    // 英文源不跑中文数词改写——"two thousand" 不是它该碰的东西，
    // 且改写函数对英文文本本应无操作，但「无操作」要靠这条守着，
    // 不靠碰巧。
    let fake = FakeTranslator(result: "ok")
    let pipeline = TranslationPipeline(translator: fake, source: .english, target: .spanish)
    _ = await pipeline.translate("两万三 units")
    #expect(fake.lastReceivedText == "两万三 units")  // 原样送达，未被改写成 23000

    let zhPipeline = TranslationPipeline(translator: fake, source: .chinese, target: .spanish)
    _ = await zhPipeline.translate("两万三个")
    #expect(fake.lastReceivedText?.contains("23000") == true)
}

@Test func sameSourceAndTargetPassesThrough() async {
    // 防御：协调器不该建出这种管线，但建出来也必须是恒等。
    let fake = FakeTranslator(result: "SHOULD NOT BE CALLED")
    let pipeline = TranslationPipeline(translator: fake, source: .english, target: .english)
    let result = await pipeline.translate("hello")
    #expect(result.text == "hello")
    #expect(fake.callCount == 0)
}
```

（`FakeTranslator` 若尚无 `lastReceivedText` / `callCount` 记录，顺手加上；它的 `translate` 签名在 Task 4 已带 `from:`。）

- [ ] **Step 2: 确认编译失败**（`source:` 构造参数不存在）
- [ ] **Step 3: 实现**

`TranslationPipeline`：

```swift
struct TranslationPipeline: Sendable {
    /// 源语言与目标语言在挂载那一刻定死——一次会话内规则不变
    /// （`DictationSession.attachTranslation` 的既有语义），中途换设置
    /// 走协调器重建管线，不改这两个值。
    let source: Language
    let target: Language
    …
    init(
        translator: any Translator,
        source: Language,
        target: Language,
        gate: TranslationGate = TranslationGate(),
        timeout: Duration = TranslationPipeline.defaultTimeout
    ) { … }

    func translate(_ text: String) async -> TranslationResult {
        // 协调器保证 source != target；万一建错，恒等是唯一无害的行为。
        guard target != source else { return TranslationResult(text: text, annotation: nil) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { … }

        // 中文数词改写只属于中文源——判据、实测、语料全是中文的。
        let rewritten = source == .chinese ? ChineseNumerals.rewriteAsDigits(text) : text
        …
        output = try await withTimeout(budget) {
            try await translator.translate(rewritten, from: source, to: target)
        }
        …
        switch gate.check(source: rewritten, translation: output, from: source, to: target) {
        …
    }
}
```

（原 `guard target.requiresTranslation` 删除；其余错误路径一行不动。）

`DictationSession`：删掉 `translationTarget` 成员与 `attachTranslation` 的 `target` 参数：

```swift
func attachTranslation(_ pipeline: TranslationPipeline?) {
    guard state == .idle else { return }
    translationPipeline = pipeline
}
```

注入路径 `:326` 改为：

```swift
if let translationPipeline {
    transition(to: .translating)
    let result = await translationPipeline.translate(finalText)
    textToInject = result.text
    onTranslation?(result.annotation)
}
```

`TranslationAttachTarget` protocol 同步：`func attachTranslation(_ pipeline: TranslationPipeline?)`。协调器 `apply()` 末尾的调用同步去掉 `target:`（协调器其余改动在 Task 7）。`DictationTranslationTests` / 协调器测试按新签名机械修。

- [ ] **Step 4: 全量测试全绿；变异**：① `source == .chinese` 条件删掉（恒改写）——`numeralRewriteOnlyForChineseSource` 红；② `guard target != source` 删掉——`sameSourceAndTargetPassesThrough` 红（fake 被调了）。复原并记录。
- [ ] **Step 5: Commit** `feat: 翻译管线固化 (源,目标) 二元组；会话侧只认「有没有管线」`

---

### Task 7: 挂载判定与协调器改 (输入, choice)

**Files:**
- Modify: `Sources/vInput/App/AppModel.swift:1240`（`translationAttachment`）、`Sources/vInput/App/TranslationAttachmentCoordinator.swift`（`Inputs` 与 `apply()`）
- Test: `Tests/vInputTests/TranslationAttachmentCoordinatorTests.swift`

- [ ] **Step 1: 失败测试**（加进协调器测试；沿用该文件既有的构造工具）

```swift
@Test func sameInputAndTargetDetaches() {
    // 输入=英文、目标=英文：等同不翻译，管线必须摘掉。
    let attachment = AppModel.translationAttachment(
        effectiveTarget: TranslationChoice.translate(to: .english).effectiveTarget(input: .english),
        usesCloudBackend: false,
        translationModelDirectory: nil,
        correctionModelDirectory: URL(fileURLWithPath: "/tmp/model"),
        isUsableModelDirectory: { _ in true })
    #expect(attachment == .detach)
}

@Test func englishToChineseIsARealLocalAttachment() {
    // 新方向 X→中文是真翻译，不再是「不翻译」的别名。
    let attachment = AppModel.translationAttachment(
        effectiveTarget: .chinese,
        usesCloudBackend: false,
        translationModelDirectory: nil,
        correctionModelDirectory: URL(fileURLWithPath: "/tmp/model"),
        isUsableModelDirectory: { _ in true })
    #expect(attachment == .local(directory: URL(fileURLWithPath: "/tmp/model")))
}

@Test func builtPipelineCarriesInputAndTarget() {
    // 「值对了」和「接上了」分开验：协调器建出的管线必须带着当时的
    // (输入, 目标)，而不是默认值。
    …用既有测试工具构造协调器，Inputs 给 input: .english、choice: .translate(to: .spanish)，
    apply() 后断言 coordinator.pipeline?.source == .english && coordinator.pipeline?.target == .spanish…
}
```

- [ ] **Step 2: 确认编译失败**
- [ ] **Step 3: 实现**

`AppModel.translationAttachment` 首参改为 `effectiveTarget: Language?`，首行守卫：

```swift
// 先判「有没有有效目标」。nil = 不翻译（off 或 目标==输入），
// **云端开关在这一行之后才允许被读到**（原「先语言后后端」守卫原样保留）。
guard effectiveTarget != nil else { return .detach }
```

（其余分支一字不动；`chineseWithCloudStillDetaches` 那条测试改成传 `effectiveTarget: nil` + 云端开——期望仍是 `.detach`，语义「off + 云端开 = 零出站」不变。）

协调器 `Inputs`：`target: Language` 替换为两个字段：

```swift
var input: Language
var choice: TranslationChoice
```

`apply()` 开头：

```swift
let current = inputs()
let effectiveTarget = current.choice.effectiveTarget(input: current.input)
// 镜像先行的理由不变（菜单当场就对）。
choice = current.choice
input = current.input
```

（协调器镜像属性 `target: Language` 改为 `choice: TranslationChoice` 与 `input: Language`，`AppModel.syncTranslationMirrors` 跟着改——Task 10。）`.local` / `.cloud` 两支建管线时带上二元组：

```swift
let built = TranslationPipeline(
    translator: makeTranslator(directory),
    source: current.input,
    target: target)   // target = effectiveTarget!，switch 前解包
```

日志行「目标=\(...)」改为「输入=\(current.input.rawValue) 目标=\(target.rawValue)」。`AppModel` 里构造协调器的 `inputs:` 闭包（`AppModel.swift:751` 一带）改为读 `translationPreference.choice` 与 `inputLanguagePreference.language`（`inputLanguagePreference` 字段在本任务先加到 `AppModel` 上：`private let inputLanguagePreference = InputLanguagePreference()`，与两个既有偏好并排；闭包按既有写法捕获结构体本身）。Task 2 留下的临时表达式在此一并清除——`git grep -n 'effectiveTarget(input: .chinese)'` 结果应只剩测试。

- [ ] **Step 4: 全量测试全绿；变异**：① `effectiveTarget` 计算改成无视 input 直接取 choice 的语言——`sameInputAndTargetDetaches` 红；② 建管线时 `source:` 硬写 `.chinese`——`builtPipelineCarriesInputAndTarget` 红。复原并记录。
- [ ] **Step 5: Commit** `feat: 挂载判定改按有效目标（off/同语言=detach）；协调器携带 (输入, choice)`

---

### Task 8: 转写器按输入语言构造

**Files:**
- Modify: `Sources/vInput/Transcribe/WhisperKitTranscriber.swift`（三个成员去 private + 空 prompt 处理）、`Sources/vInput/App/AppModel.swift:525`（`makeTranscriber`）与 `:591`（闭包）
- Test: `Tests/vInputTests/WhisperKitTranscriberTests.swift`

- [ ] **Step 1: 失败测试**

```swift
@Test func transcriberIsBuiltPerInputLanguage() {
    let zh = AppModel.makeTranscriber(
        ModelDescriptor(name: "m", folder: "/tmp/m"), language: .chinese)
    let en = AppModel.makeTranscriber(
        ModelDescriptor(name: "m", folder: "/tmp/m"), language: .english)
    guard let zh = zh as? WhisperKitTranscriber, let en = en as? WhisperKitTranscriber else {
        Issue.record("空目录之外应当构造 WhisperKitTranscriber"); return
    }
    #expect(zh.language == "zh")
    #expect(zh.normalizeToSimplified)
    #expect(zh.promptText == WhisperKitTranscriber.punctuationPrompt)
    #expect(en.language == "en")
    // 繁→简与中文标点 prompt 都是中文专属，英文解码带着它们只有坏处。
    #expect(!en.normalizeToSimplified)
    #expect(en.promptText.isEmpty)
}

@Test func emptyModelFolderStillMeansMissingModel() {
    // 原守卫不因加参数而丢：空目录绝不联网。
    let transcriber = AppModel.makeTranscriber(
        ModelDescriptor(name: "m", folder: ""), language: .english)
    #expect(transcriber is MissingModelTranscriber)
}
```

（`ModelDescriptor` 的构造按仓库实际签名写——实施时先看 `ModelCatalog`。）

- [ ] **Step 2: 确认编译失败**
- [ ] **Step 3: 实现**

`WhisperKitTranscriber`：`private let language` / `private let normalizeToSimplified` / `private let promptText` 去掉 `private`（与 `task` 同一条理由：让「生产构造参数正确」有测试守着）。`:343` 那行加空串守卫：

```swift
// 空 prompt 不编码成空 token 数组——promptTokens 传 [] 与传 nil 在
// WhisperKit 的 prefill 路径上不是一回事，nil 才是「没有条件前缀」。
promptTokens = promptText.isEmpty
    ? nil
    : loaded.tokenizer.map { Self.encodePrompt(promptText, with: $0) }
```

`AppModel.makeTranscriber`：

```swift
nonisolated static func makeTranscriber(_ model: ModelDescriptor, language: Language) -> Transcriber {
    guard !model.folder.isEmpty else { return MissingModelTranscriber() }
    return WhisperKitTranscriber(
        modelName: model.name,
        modelFolder: model.folder,
        language: language.rawValue,   // Language 的 rawValue 就是 Whisper 语言码
        // 繁→简与标点 prompt 都是中文专属。英文等语种裸解码的标点表现
        // 未实测——记录在 Roadmap 未验证清单，不在这里假装有依据。
        normalizeToSimplified: language == .chinese,
        prompt: language == .chinese ? WhisperKitTranscriber.punctuationPrompt : ""
    )
}
```

`:591` 闭包：

```swift
makeTranscriber: { @Sendable model in
    // 每次构造现读偏好：Task 9 的 rebuild() 换语言后重建时拿到的就是新值。
    // UserDefaults.standard 跨线程读是文档保证的。
    AppModel.makeTranscriber(model, language: InputLanguagePreference().language)
}
```

- [ ] **Step 4: 全量测试全绿；变异**：① `normalizeToSimplified:` 硬写 `true`——`transcriberIsBuiltPerInputLanguage` 红；② `language:` 硬写 `"zh"`——同条红；③ prompt 三目反转——同条红。复原并记录。
- [ ] **Step 5: Commit** `feat: 转写器按输入语言构造——语言码、繁→简、标点 prompt 三处分流`

---

### Task 9: SwitchableTranscriber.rebuild()

**Files:**
- Modify: `Sources/vInput/Transcribe/SwitchableTranscriber.swift`
- Test: `Tests/vInputTests/SwitchableTranscriberTests.swift`（若无则新建；先 `ls Tests/vInputTests | grep -i switch` 确认）

- [ ] **Step 1: 失败测试**

```swift
@Test func rebuildReconstructsWithSameDescriptor() async throws {
    // 输入语言是构造参数——换语言不换模型时 switchTo 的同名 guard 直接返回，
    // rebuild 必须无条件重建。
    let built = CountingBox()   // 简单 actor/类，记录构造次数与收到的 descriptor
    let transcriber = SwitchableTranscriber(
        initial: ModelDescriptor(name: "m", folder: "/tmp/m"),
        makeTranscriber: { descriptor in
            Task { await built.record(descriptor) }
            return InstantFakeTranscriber()   // prepare() 立即成功的替身
        })
    try await transcriber.rebuild()
    #expect(await built.count == 2)          // init 一次 + rebuild 一次
    #expect(await built.last?.name == "m")   // 同一个模型
}

@Test func rebuildKeepsOldTranscriberWhenPrepareFails() async {
    // 与 switchTo 同一条保证：先建新的、加载成功才替换。
    …makeTranscriber 第二次返回 prepare() 必抛的替身；rebuild() 抛错后，
    transcribe() 仍走老实例（老替身返回可识别的哨兵文本）…
}
```

- [ ] **Step 2: 确认编译失败**
- [ ] **Step 3: 实现**（加在 `switchTo` 后面）

```swift
/// 用同一个模型描述符重建底层转写器。
///
/// 存在的理由：输入语言是 `makeTranscriber` 的构造期参数，换语言不换
/// 模型时 `switchTo` 的 `next != descriptor` guard 会直接返回、什么都
/// 不发生。语义与 `switchTo` 相同：先建新的、`prepare()` 成功才替换，
/// 失败时旧转写器原样可用。
func rebuild() async throws {
    let candidate = makeTranscriber(descriptor)
    try await candidate.prepare()
    current = candidate
}
```

- [ ] **Step 4: 全量测试全绿；变异**：① `rebuild` 里 `current = candidate` 删掉——第一条红（构造了但没换上，正是「值对了没接上」）；② `try await candidate.prepare()` 挪到赋值之后——第二条红。复原并记录。
- [ ] **Step 5: Commit** `feat: SwitchableTranscriber.rebuild()——同模型换构造参数的重建入口`

---

### Task 10: AppModel 接线

**Files:**
- Modify: `Sources/vInput/App/AppModel.swift`（镜像、`selectInputLanguage`、重建与补做、校正门、迁移调用、`syncTranslationMirrors`、`selectOutputLanguage`→`selectTranslationChoice`、菜单标题纯函数）
- Test: `Tests/vInputTests/AppModelWiringTests.swift`（源码扫描）、`Tests/vInputTests/OnboardingWiringTests.swift`（若扫到相关区间则同步）

`AppModel` 在测试进程起不来（init 要真快捷键/CGEvent tap/麦克风）——接线全靠**源码扫描**守（既有范式就在 `AppModelWiringTests`，用 `NSRegularExpression` 整文件匹配，防跨行）。

- [ ] **Step 1: 失败测试**（加进 `AppModelWiringTests.swift`，沿用该文件读源码的工具函数）

```swift
@Test func inputLanguageChangeRebuildsAndReappliesEverything() throws {
    let source = try appModelSource()
    // selectInputLanguage 必须依次触发：校正重挂（非中文摘除）、翻译重挂
    // （矩阵变了）、转写器重建。切出 selectInputLanguage 函数体后逐一断言，
    // 防「声明匹配」假阳性。
    let body = try functionBody(named: "selectInputLanguage", in: source)
    #expect(body.contains("applyCorrectionPreference()"))
    #expect(body.contains("applyTranslationPreference()"))
    #expect(body.contains("rebuildTranscriberForInputLanguage()"))
}

@Test func idleBranchRepaysPendingInputLanguageRebuild() throws {
    // onStateChange 的 .idle 分支必须补做被推迟的重建——与校正/翻译/模型
    // 换用三条补挂并排。切 .idle case 区间断言。
    let body = try idleCaseBody(inAppModelSource: …)
    #expect(body.contains("inputLanguageRebuildPending") || body.contains("rebuildTranscriberForInputLanguage"))
}

@Test func correctionPipelineIsChineseOnly() throws {
    let body = try functionBody(named: "makeCorrectionPipeline", in: source)
    #expect(body.contains("== .chinese"))
}

@Test func legacyPreferenceMigrationIsWiredAtInit() throws {
    // 迁移函数写了没人调 = 老用户升级即被翻译。
    #expect(source.contains("migrateLegacyOutputLanguageIfNeeded()"))
}
```

（`functionBody(named:)` 若尚不存在，写成「从 `func <name>` 起始花括号做括号配平取函数体」的工具，放测试侧复用。）

另加两条纯函数测试（可直接实例化，不用扫源码）：

```swift
@Test func outputLanguageMenuTitleCoversAllStates() {
    #expect(AppModel.outputLanguageMenuTitle(choice: .off, input: .english, modelMissing: false)
        == "输出语言：不翻译")
    #expect(AppModel.outputLanguageMenuTitle(choice: .translate(to: .spanish), input: .chinese, modelMissing: true)
        == "输出语言：西班牙文（缺模型目录）")
    // 存的目标恰好等于后来改的输入语言：菜单必须明说这等于不翻译。
    #expect(AppModel.outputLanguageMenuTitle(choice: .translate(to: .english), input: .english, modelMissing: false)
        == "输出语言：英文（与输入相同，不翻译）")
}

@Test func correctionUnavailableNoteOnlyForNonChinese() {
    #expect(AppModel.correctionUnavailableNote(input: .chinese) == nil)
    #expect(AppModel.correctionUnavailableNote(input: .english)?.contains("仅中文输入可用") == true)
}
```

- [ ] **Step 2: 确认失败/编译失败**
- [ ] **Step 3: 实现**（逐块）

镜像与偏好（`:59` 一带，与 `outputLanguage` 镜像并排）：

```swift
/// 当前输入语言（用户说的是什么）。UserDefaults 的可观察镜像，理由同 correctionEnabled。
private(set) var inputLanguage: Language = .chinese
/// 翻译目标（两态）。原 outputLanguage 镜像的替任。
private(set) var translationChoice: TranslationChoice = .off
```

（`private let inputLanguagePreference = InputLanguagePreference()` 已在 Task 7 加入。）init 里镜像初始化处补 `inputLanguage = inputLanguagePreference.language`；init 里（构造协调器之前）调迁移：

```swift
if translationPreference.migrateLegacyOutputLanguageIfNeeded() {
    AppLogger.shared.log("翻译目标偏好已从旧格式迁移（旧 \"zh\" = 不翻译）")
}
```

设置入口（替换 `selectOutputLanguage`，`MenuPanelView` 调用点 Task 11 改）：

```swift
/// 切换翻译目标。改动立即生效并跨启动保留。
func selectTranslationChoice(_ choice: TranslationChoice) {
    translationPreference.choice = choice
    applyTranslationPreference()
    if translationModelMissing {
        showHUDNotice(TranslationAnnotation.missingLocalModel.hudLabel)
    }
}

/// 切换输入语言。转写、校正、翻译三层都要跟着动。
func selectInputLanguage(_ language: Language) {
    guard language != inputLanguagePreference.language else { return }
    inputLanguagePreference.language = language
    inputLanguage = language
    AppLogger.shared.log("输入语言设置为：\(language.displayName)")
    // 顺序：先校正（非中文=摘除）、再翻译（矩阵变了）、最后重建转写器。
    // 前两个自带「会话忙时记账补挂」，重建的记账在下面自己管。
    applyCorrectionPreference()
    applyTranslationPreference()
    rebuildTranscriberForInputLanguage()
}

private var inputLanguageRebuildPending = false

/// 输入语言变了就重建转写器（语言是构造参数）。会话忙时记账，
/// 回到 idle 补做——与校正/翻译补挂同一个模式。
private func rebuildTranscriberForInputLanguage() {
    guard let transcriber else {
        inputLanguageRebuildPending = true
        return
    }
    guard canSwitchModel else {
        inputLanguageRebuildPending = true
        AppLogger.shared.log("输入语言本次会话不生效（会话进行中），会话结束后重建转写器")
        return
    }
    inputLanguageRebuildPending = false
    loadingModelName = activeModelName   // 复用「加载中」的界面态与 toggle 闸
    Task { [weak self] in
        do {
            try await transcriber.rebuild()
            await self?.attachPreview()   // 与 selectModel 同一条理由：预览引擎绑的是旧解码器
            AppLogger.shared.log("转写器已按输入语言重建")
        } catch {
            // 失败时旧转写器仍可用（rebuild 的保证），只是语言还是旧的——必须说出来。
            AppLogger.shared.log("按输入语言重建转写器失败，转写仍用旧语言：\(error)")
        }
        self?.loadingModelName = nil
    }
}
```

`onStateChange` 的 `.idle` 分支（`:659` 一带，三条补挂之后）加：

```swift
// 输入语言在录音途中被换过：现在补做转写器重建。
if self.inputLanguageRebuildPending { self.rebuildTranscriberForInputLanguage() }
```

`makeCorrectionPipeline`（`:1000`）首行加：

```swift
// 校正的机制是拼音同音字（`Pinyin.swift`），对拉丁语种无意义——
// 不是「以后补」，是「不适用」。摘除并记日志；菜单侧的置灰见
// correctionUnavailableNote。
guard inputLanguagePreference.language == .chinese else {
    AppLogger.shared.log("校正不适用：输入语言为\(inputLanguagePreference.language.displayName)（拼音机制只对中文有效）")
    return nil
}
```

`syncTranslationMirrors`（`:1461`）：`outputLanguage = translationCoordinator.target` 改为 `translationChoice = translationCoordinator.choice`（协调器镜像在 Task 7 已改名）。菜单标题纯函数（`:1269`）替换为：

```swift
/// 「输出语言：…」一行。存的目标恰好等于输入语言时明说等于不翻译——
/// 那正是「用户先选了英文目标、后来把输入也改成英文」会走到的状态。
nonisolated static func outputLanguageMenuTitle(
    choice: TranslationChoice, input: Language, modelMissing: Bool
) -> String {
    let value: String
    switch choice {
    case .off: value = "不翻译"
    case .translate(let target):
        value = target == input ? "\(target.displayName)（与输入相同，不翻译）" : target.displayName
    }
    let title = "输出语言：\(value)"
    return modelMissing ? "\(title)（缺模型目录）" : title
}

/// 校正菜单的置灰说明；输入=中文时 nil（照常可用）。
nonisolated static func correctionUnavailableNote(input: Language) -> String? {
    guard input != .chinese else { return nil }
    return "校正仅中文输入可用（拼音机制），当前输入语言：\(input.displayName)"
}
```

`translationBackendDetailLines(status:target:)` 的 `target` 参数类型已随 Task 1 变成 `Language`，文案不动。

- [ ] **Step 4: 全量测试全绿；变异**（源码扫描类测试的变异要**确认变异真落了盘**再跑，`sed` 后 `git diff` 看一眼）：① 删掉 `selectInputLanguage` 里 `applyCorrectionPreference()` 一行——接线扫描红；② 删掉 `.idle` 分支那句补做——第二条红；③ `makeCorrectionPipeline` 的语言守卫删掉——第三条红；④ 删掉 init 里迁移调用——第四条红。复原并记录。
- [ ] **Step 5: Commit** `feat: AppModel 接线——输入语言镜像/切换/重建补做、校正中文门、偏好迁移落位`

---

### Task 11: 菜单 UI

**Files:**
- Modify: `Sources/vInput/UI/MenuPanelView.swift`（`:75` SettingKey、`:355` 一带新增行、`:400` 值标签、`:533` 目标区、校正区注一行）、`Sources/vInput/Translate/Language.swift`（`quality`/`menuLabel` 改带输入参数）
- Test: `Tests/vInputTests/LanguageTests.swift`

- [ ] **Step 1: 失败测试**（加进 `LanguageTests.swift`）

```swift
@Test func qualityIsMeasuredOnlyFromChineseInput() {
    // 分级数字是 zh→X 的实测（2026-08-19 六语对照），别的输入语种没测过
    // ——菜单不许虚标。
    #expect(Language.spanish.quality(from: .chinese) == .measured(termRetention: 0.94))
    #expect(Language.spanish.quality(from: .english) == .unmeasured)
    #expect(Language.chinese.quality(from: .english) == .unmeasured)   // X→中文同样未实测
    #expect(Language.english.quality(from: .english) == .notApplicable) // 与输入相同
}

@Test func menuLabelSpellsOutTheThreeStates() {
    #expect(Language.spanish.menuLabel(from: .chinese) == "西班牙文 · 术语保留 0.94")
    #expect(Language.spanish.menuLabel(from: .english) == "西班牙文 · 未实测")
    #expect(Language.english.menuLabel(from: .english) == "英文（与输入相同，不翻译）")
}
```

- [ ] **Step 2: 确认编译失败**
- [ ] **Step 3: 实现**

`Language.swift`：删掉 `var quality` / `var menuLabel`，换成（原实测表格注释整段保留在函数上方）：

```swift
func quality(from input: Language) -> TranslationQuality {
    if self == input { return .notApplicable }
    // 实测表只覆盖 zh→X（2026-08-19 六语对照）。其他输入语种的组合
    // 一律 unmeasured——不许编一个数糊上去。
    guard input == .chinese else { return .unmeasured }
    switch self {
    case .chinese: return .notApplicable   // input==.chinese 时到不了这里，穷尽 switch 需要它
    case .english: return .measured(termRetention: 1.00)
    case .german: return .measured(termRetention: 1.00)
    case .italian: return .measured(termRetention: 1.00)
    case .french: return .measured(termRetention: 0.98)
    case .portuguese: return .measured(termRetention: 0.96)
    case .spanish: return .measured(termRetention: 0.94)
    }
}

func menuLabel(from input: Language) -> String {
    switch quality(from: input) {
    case .notApplicable: "\(displayName)（与输入相同，不翻译）"
    case .measured(let retention): "\(displayName) · 术语保留 \(String(format: "%.2f", retention))"
    case .unmeasured: "\(displayName) · 未实测"
    }
}
```

（`TranslationQuality.notApplicable` 的语义注释从「中文=不翻译」改为「与输入相同=不翻译」。）

`MenuPanelView`：

1. `:75`：`case model, correction, inputLanguage, outputLanguage, backend, advanced, devTools`
2. `:355` 之前插入一行（排在「输出语言」上面——先说「我说什么」再说「出什么」）：

```swift
settingRow(.inputLanguage, title: "输入语言", value: "输入语言：\(model.inputLanguage.displayName)") {
    inputLanguageSection
}
```

```swift
/// 输入语言七档。非中文时下面缀一行后果说明——校正停用、质量未实测，
/// 在用户选的那一刻就说清，不等他事后纳闷。
private var inputLanguageSection: some View {
    Group {
        ForEach(Language.allCases, id: \.rawValue) { language in
            expandedButton(language.displayName, checked: language == model.inputLanguage) {
                model.selectInputLanguage(language)
            }
        }
        if let note = AppModel.correctionUnavailableNote(input: model.inputLanguage) {
            captionRow(note)   // 用该文件既有的说明行样式；没有就按邻近样式起一个
        }
    }
}
```

3. `:400` 值标签与 `:533` 目标区：

```swift
private var outputLanguageValueLabel: String {
    AppModel.outputLanguageMenuTitle(
        choice: model.translationChoice,
        input: model.inputLanguage,
        modelMissing: model.translationModelMissing)
}

private var outputLanguageSection: some View {
    Group {
        expandedButton(
            "不翻译（保持\(model.inputLanguage.displayName)原样）",
            checked: model.translationChoice == .off
        ) { model.selectTranslationChoice(.off) }
        // 与输入相同的语种不列——选它等于不翻译，上面那格已经是它。
        ForEach(Language.allCases.filter { $0 != model.inputLanguage }, id: \.rawValue) { target in
            expandedButton(
                target.menuLabel(from: model.inputLanguage),
                checked: model.translationChoice == .translate(to: target)
            ) { model.selectTranslationChoice(.translate(to: target)) }
        }
    }
}
```

4. 校正区：标题行拼接处按 `AppModel.correctionUnavailableNote(input:)` 非 nil 时把开关按钮换成同文案的置灰行（用该文件既有的禁用样式；实施时看 `correctionSection` 现状再落笔，原则：**非中文输入下不许出现可点的校正开关**）。

- [ ] **Step 4: 构建 + 全量测试**：`./scripts/test.sh` 全绿后 `./scripts/build-app.sh && killall vInput; open dist/vInput.app` 人肉过一遍菜单（新行出现、七档可点、目标区随输入语言变化、非中文时校正置灰）。**变异**：`quality(from:)` 里 `guard input == .chinese` 删掉——`qualityIsMeasuredOnlyFromChineseInput` 红；复原。
- [ ] **Step 5: Commit** `feat: 面板输入语言七档；目标区改「不翻译+六档」；非中文输入校正置灰`

---

### Task 12: 收尾——全量、文档、重打包

**Files:**
- Modify: `docs/Roadmap.md`
- 产物: `dist/vInput.app` 重打

- [ ] **Step 1: 全量** `./scripts/test.sh` 全绿；`git grep -n 'TranslationTarget\|requiresTranslation\|outputLanguage ='` 确认旧概念清干净（`requiresTranslation` 属性此时应已无人引用，从 `Language.swift` 删除）。
- [ ] **Step 2: Roadmap 增「M10 输入语言与全矩阵」一节**，含：
  - 实施记录与两轮变异表（各任务交回的表合并）；
  - **未验证清单**（照抄设计定稿「不装作验过」四条）；
  - **真机清单**：① 输入=英文实说英文出英文；② 英→西一轮（听写→译文注入）；③ 切输入语言不重启生效（含录音途中切、停手后补建）；④ **主路径回归：输入=中文、中英混杂不劣化**；⑤ 英→中一轮（新方向）；⑥ 非中文输入时校正菜单置灰、日志有「校正不适用」。
- [ ] **Step 3: 重打包** `./scripts/build-app.sh`，产物给用户真机验收。
- [ ] **Step 4: Commit** `docs: M10 输入语言批次实施记录、变异表与未验证/真机清单`

---

## Self-review 已做的三处对齐

- 规格「闸门矩阵」表 ↔ Task 5 代码：拉丁目标四条（源=中文）/三条（源=拉丁，长度比停用）、中文目标两条、直通零条，一致。
- 规格「迁移」↔ Task 2：旧 `"zh"`→off、新键独立、认不出退 off，一致。
- 类型与签名跨任务一致性：`TranslationChoice.effectiveTarget(input:)`（T2）被 T7 使用；`Language`（T1）贯穿；`translate(_:from:to:)`（T4）被 T6 使用；`rebuild()`（T9）被 T10 使用；`selectTranslationChoice` / `translationChoice` 镜像（T10）被 T11 使用。
