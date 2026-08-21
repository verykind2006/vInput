# M8 验收清单（多语种输出 / 翻译）

- 日期：2026-08-19
- 分支：`m8-implementation` → `fix-event-tap-lifetime`（2026-08-19 合并进 main）
- 自动化：**990 tests / 128 suites 全绿**（M8 开工时 762；合并前 QA 之后补的守卫 +9）
- 默认后端：`qwen3-4b-instruct-2507-4bit`（**与校正层同一个模型，共用同一份权重**）

说中文 → 转写 → 校正 → **翻译** → 注入。译砸了退回中文原文并在 HUD 说明。
菜单栏两个**正交**的开关：「输出语言」决定**译成什么**，「翻译后端」决定**谁来译**。

---

## 一、六条验收标准逐条对照

| # | 标准 | 结果 | 证据 |
|---|---|---|---|
| 1 | 菜单栏能切换输出语言，状态跨启动保留 | ✅ 自动化 | `TranslationPreferenceTests`：存的是稳定字符串（`"de"`）不是枚举序号；不认识的值退回中文。菜单标题由 `AppModel.outputLanguageMenuTitle` 纯函数算出并被钉死 |
| 2 | 选定拉丁字母语种后，说中文出该语言文字 | ✅ 端到端 | `TranslationE2ETests` 拿真模型跑通 5 条；`DictationTranslationTests` 验会话真的注入译文 |
| 3 | 闸门拦下时注入中文原文、HUD 有标注、日志记明原因 | ✅ 自动化 | `TranslationPipelineTests` 八条失败路径全部收敛为「中文原文 + 标注」；`TranslationAnnotationTests` 验每种标注都写得到 HUD |
| 4 | 云端默认不加载；显式开启且未配 key 时 HUD 明确提示 | ✅ 自动化 | `TranslationPreferenceTests.cloudDefaultsOff`；`missingKeyIsLoudAndDoesNotFallBackToLocal`（**不静默退回本地**） |
| 5 | 基准集能跑出翻译那几格，一条命令无人值守 | ✅ | `./scripts/bench-run.sh <模型> en`。不带语言参数时输出与从前**逐字一致**（去掉时间/SHA/耗时三行后 md5 相同，均 93 行） |
| 6 | 会话多出 `.translating`，且校正在翻译之前 | ✅ 自动化 | 见下面「同音错字不被固化」 |
| 7 | 闸门按 `usesLatinScript` 分流，不是 `requiresTranslation` | ⚠️ **部分** | 见下面「一个抓不到的守卫」 |

### 标准 6 的证据不是一个数组

计划原本要求断言一个静态数组 `allCasesInPipelineOrder` 的元素顺序。**那是自证的**——数组是手写的，`process()` 里两段代码对调它一个字都不用改。

改成两条真行为证据：

1. `CallOrderLog` 让假校正器与假翻译器各记被调时刻，断言 `["correct", "translate"]`；
2. **更硬的一条**：翻译器收到的必须是**校正之后**的中文。素材是同音错字 `"今天下午上限。"` → 校正成 `"今天下午上线。"`，断言 `translator.receivedTexts == ["今天下午上线。"]`。顺序对调时它收到的就是那个错字，也就是这条规则要防的事本身。

### 标准 7：一个抓不到的守卫，明确记账

闸门里 `guard target.usesLatinScript` 是为「将来加日语」设的——日文用汉字，「残留汉字」这条判据会把正常的日语译文全部拦下。

**但今天 `usesLatinScript` 与 `requiresTranslation` 在全部 7 个 case 上取值相同**，闸门里换哪个都**没有任何用例能区分**。这是数学事实，不是测试没写好。

处理：写了一条**明说自己今天恒真**的绊线用例，并用变异 M11（模拟给某语种填 `usesLatinScript = false`）证明它不空——语种分家那天它会红并指回闸门。**没有假装抓到了。**

---

## 二、第 0 步的对照数据（决定了后面全部参数）

156 次推理 × 六种语言 + 数字语料 + 提示词变体 + Whisper 对照，原始报告在 `Bench/reports/m8-step0/`（已 gitignore）。

### 4B 赢了 7B，不是小赢

| 模型 | 语言 | 残留汉字 | 术语保留 | 长度比 均/最小/最大 | 耗时 均/**最长** |
|---|---|---|---|---|---|
| **4B** | en (26) | **0** | 1.00 | 2.75 / 1.20 / 4.47 | 1.7 / **2.9** |
| 7B | en (26) | 28 个 / 4 条 | 1.00 | 2.83 / 1.31 / 4.04 | 3.3 / **8.0** |
| **4B** | es (26) | **0** | 0.92 | 3.08 / 1.43 / 6.16 | 2.2 / **4.3** |
| 7B | es (26) | 19 个 / 3 条 | 0.98 | 3.04 / 1.24 / 5.11 | 3.6 / **6.2** |
| **4B** | de (10) | **0** | 0.89 | 2.95 / 2.35 / 4.35 | 3.1 / **4.9** |
| 7B | de (10) | 10 个 / 1 条 | 12/14 词 | 3.07 / 2.09 / 3.93 | 5.0 / **7.7** |

**62 条样本上 4B 残留汉字 0，7B 是 57 个分布在 8 条上，4B 还快一到三倍。**

7B 砸的时候会译到一半开始自我评论：

> Entregaremos la primera一批保持不变直接翻译为"entregaremos la primera"一批作为保持不变的部分…正确的翻译应为: Entregaremos la primera lote el 18 de agosto…

**所以 7B 不做 fallback**——比不译更糟。

### 数字：虚惊一场，但量具本身坏过

`TranslationMetrics.digitsIn` 原本用 `Character.isNumber`，而 Swift 的 `isNumber` 对「三」「两」「百」「十」「零」**全返回 true**。于是「三个议题」的「三」被当成阿拉伯数字，报告写出「**数字丢失 17/17，丢失率 100%**」——而那 26 条里一个 ASCII 数字都没有。已改为 ASCII `0–9` 判据 + 回归用例。

补了 12 条报价语料（`Bench/translate-digits.json`：金额、百分比、日期、型号单号、中文数字与阿拉伯数字混排）重跑，**16 次报警逐条看过，实际译错 0 个**——全是 `98,000` vs `98.000`、`8 月`→`August`、`下午 3 点`→`a las 15 horas` 这类合法差异。最怕的 `128000`→`12800` 一次都没有。

### Whisper 的 `translate` 路线废弃

| 模型 | initial prompt | 残留汉字 | 退回转写 | 术语保留 |
|---|---|---|---|---|
| **turbo（产品默认）** | 挂 | 679 / 26 条 | **26/26** | 0.75 |
| turbo | 不挂 | 679 / 26 条 | **26/26** | 0.37 |
| large-v3 | **不挂** | **0** | 0/26 | 0.56 |

**turbo 根本不翻译**——52 次全部原样吐回中文。换 large-v3 且摘掉中文 initial prompt 才译得出英文，但意思错得离谱**而指标看不出来**：

> 「权限也需要重新梳理」→ "the whole line needs to be reorganized"
> 「下周三开始灰度」→ "will start to be approved next Wednesday"

零残留汉字、术语保留高、长度比正常，**全是合法英文，意思是错的**。

**订正一条早先的说法**：「Whisper Turbo 中文到英文基本没问题、中文到西语不好」是错的——不是「英文行西语不行」，是**一种都不行**。`WhisperKitTranscriber.task` 参数保留（生产默认 `.transcribe` 不变），将来复验用得上。

### 提示词变体

`--variant chinese-language-name`（`Spanish` → `西班牙文`）在西语/德语上**测不出系统性差异**。所以「英文指令 + 英文语言名」这条从「假设」变成了「测过，没差别」——但也不再是个需要辩护的选择。

---

## 三、三个数各自的依据

| 参数 | 取值 | 依据 |
|---|---|---|
| **默认模型** | `qwen3-4b-instruct-2507-4bit` | 上表。且**与校正层同一个模型** → `ModelContainerRegistry` 共用同一份权重，16 GB 的 MacBook Air 上省一次加载和一份 2 GB 常驻 |
| **超时** | **8 秒** | 4B 实测最长 4.9 秒（de），en/es 26 条最长 2.9 / 4.3 秒。约 1.6 倍余量。**上界也有理由**：`ModelContainer.perform` 串行，跑飞的那次会挡住下一次推理 |
| **长度比阈值** | **1.1** | 实测最小值 **1.2040816**（= 59/49，`tech-hold-02` 英文）。**阈值定 1.2 的余量是 0 个字符**——少吐一个字母就是 58/49 = 1.1837，被误杀。1.1 的余量 0.104（8.6%，约 5 个显著字符），而代价实测为 0 |

---

## 四、闸门改了设计：长度比拦不住半截译文

计划原本指望长度比拦住「译到一半」。**实测不成立。**

| 阈值 | 误杀正常译文 | 拦住「砍一半」 | 拦住「留 70%」 |
|---|---|---|---|
| **1.2** | **0 (0%)** | 22 (26%) | 2 (2%) |
| 1.5 | 2 (2%) | 47 (55%) | 9 (10%) |
| 1.8 | 2 (2%) | 68 (79%) | 26 (30%) |
| 2.0 | 5 (6%) | 81 (94%) | 41 (48%) |

**误杀的恰好是主场景**：技术短句（"你把 useMemo 换成 useCallback…"）一半是原样保留的代码标识符，长度比天然就低（en 1.20 / es 1.43）。

改为：

- **主信号 `TruncationSignal`**（原文有句末标点而译文没有）——306 次推理里只误报 1 次
- **长度比 1.1 降级为辅助**——零误杀、白捡两成多
- **明确接受漏网**：越接近「快译完才被砍」的半截，两条信号都越无力。**不为堵它去抬阈值伤主场景。**

### 为什么会有半截译文（Task 8 实测，写 probe 跑了 8/8 次）

**超时取消对 MLX 推理基本无效。** `Generator.stream()` 的 `AsyncThrowingStream` 外层没设 `onTermination`，消费方挂在 `next()` 上被取消时流直接 `finish()`，`for try await` **正常结束、不抛异常**，`translate` **成功返回半截译文**。

而半截译文往往是**完全合法的目标语言文本**：「我想订三张下周五的机票」译到一半是 "I'd like to book three tickets" —— 残留汉字 0、术语保留 100%。

所以流水线的超时走 `ResultBox` 抢跑（不指望 `Task.cancel()`），且**取消买到的只是「注入路径上不干等」，买不到省算力**——生产方是非结构化 Task，GPU 照跑到 EOS。

---

## 五、两个开关是正交的（用户 2026-08-19 强调）

| 语言 | 云端 | 行为 | 出站 |
|---|---|---|---|
| 中文 | 关 | 翻译层完全不参与 | **零** |
| 中文 | **开** | **同上** | **零** |
| 外语 | 关 | 本地 `MLXTranslator` | **零** |
| 外语 | 开 | `GeminiTranslator` | 有 |

**判断顺序：先判语言，再判后端。** 反了的话「云端开 + 语言选中文」会走进「没配 API key」分支，弹一句与用户意图无关的提示。

**这条顺序有机械守卫**：`TranslationAttachment` 单列 `.cloud` 一格，使得对调两个判断会改变返回值。变异实测（2026-08-19 复跑，990 tests 基线）：对调 → **6 条红 / 8 处断言**，分布在 `TranslationAttachmentCoordinatorTests.swift`（4）、`TranslationPreferenceTests.swift`（1）、`CloudBackendMenuTests.swift`（1）。

### 「云端开着 + 中文 = 零出站」是端到端验过的

`CloudEgressTests.chineseWithCloudSendsNothing`：从偏好 → 协调器 → **真 `DictationSession`** → 注入到 sink，全程用**真的 `GeminiTranslator`**，其 `URLSession` 由 `URLProtocol` 记录器提供。断言请求数 0 **且**云端翻译器构造次数 0。

**正对照**：同一个装置只把语言换成英文 → 真的记到 1 条 POST 到 `generativelanguage.googleapis.com`。

**它证明不了什么**（已写进测试注释）：记录器只看得见经由被注入的那个 session 发出的请求；有人另写一句 `URLSession.shared.data(...)` 它看不见——挡这一手的只有源码扫描，而扫描只证明「那行字不在」。

---

## 六、只能人工验证的部分（**未验**）

**自动化到不了的三件事，都还没人眼看过：**

| | 怎么验 |
|---|---|
| **菜单栏实际观感** | 打开 vInput 菜单，看「输出语言」与「翻译后端」两个子菜单的文案、勾选、质量标注排版对不对 |
| **HUD 标注的实际观感** | 故意让翻译失败（比如把模型目录改错），看 HUD 那行字停留够不够久、看不看得清 |
| **说一句话的真实体感** | 切到英文，说一句中文，看延迟能不能忍、译文对不对 |

**云端那条链路一次都没真实联网跑过**——用户尚未提供 API key。因此 Gemini 的响应结构、端点、`x-goog-api-key` 头名、非 200 的错误体形状，**全部只对着文档写、用假 `URLSession` 验过形状**。`gemini-2.0-flash` 的译文质量与耗时同样**没有任何实测支撑**，代码注释里写明了不许拿本地那三个数替云端说话。

验证云端的两条命令：

```bash
# ① 存 key（-w 后不带值，交互式输入，key 不进 shell 历史、不进仓库）
security add-generic-password -a vInput -s vinput-gemini-api-key -w

# ② 真实联网体检（会把 3 句写死的中文发给 Google）
./scripts/gemini-e2e.sh
```

---

## 七、途中修掉的真问题

1. **模型目录没配就静默不翻译**。计划写「`translation.modelDirectory` 没配就 return」，而那个键默认 nil 且**今天没有任何入口会去设它**——用户选完「西班牙文」什么都不发生，菜单上还写着「输出语言：西班牙文」。改为退回校正层的目录，两个都没配时日志 + 菜单后缀 + HUD 三处说清楚。
2. **一次成功的翻译会抹掉校正标注**。翻译回调排在校正之后，照抄 `notice = annotation?.hudLabel` 的话，译文正常时（标注 nil）会把刚写进去的校正标注清掉——用户看到的是「校正好像没运行」。改为「nil 表示什么都不做」。
3. **`AppModel` 的接线零测试覆盖**。变异实测：把「挂流水线到会话」整句删掉，899 tests 全绿。抽出 `TranslationAttachmentCoordinator` 后同一变异**7 条红 / 9 处断言**（2026-08-19 合并前 QA 之后在 990 tests 基线上复跑；此前写的「4 条」是云端那套用例加进来之前量的，数字变大是覆盖变厚）。（`AppModelWiringTests` 扫源码钉住 `AppModel` 不许绕过它。）
4. **门控脚本的护栏自己是空的**。「跑了 0 条算失败」第一版数的是汇总行，而 suite 被 `.enabled(if:)` 跳过时 Swift Testing 照样打 `Test run with 5 tests ... passed`，跳过的用例计进那个数。改成数逐条结果行。
5. **`digitsIn` 把中文数字当阿拉伯数字**，见第二节。

### 合并前 QA（2026-08-19）找出来、这一轮修掉的四条

6. **配好校正模型目录之后，翻译层要重启才生效。** `correction.modelDirectory`
   是翻译层今天唯一的模型来源，而写它的两条入口（`enableCorrection` /
   `selectCorrectionModel`）**都不通知翻译协调器**；idle 那道兜底也不接
   （`sessionDidBecomeIdle` 第一行 `guard isPending`，而上次 `apply()` 是成功
   返回的）。用户的遭遇是：应用亲口说「请在「校正」菜单里指定本地模型目录」，
   他照做了，**然后什么都没发生**。第二个后果是换模型时翻译层继续持有旧目录的
   `MLXTranslator`，`ModelContainerRegistry` 省下的那份 2 GB 又被吃回去。
   两条入口各补一句 `applyTranslationPreference()`（**排在
   `applyCorrectionPreference()` 之后**，理由同 `bootstrap`），
   `AppModelWiringTests` 扫源码钉住这一句与这个顺序。
7. **校正模型目录失效时翻译层照挂，HUD 永远说「翻译模型还在加载」。**
   翻译借了校正层的**目录**，没借它的**校验**。
   `CorrectionActivation.revalidateAtLaunch()` 判掉失效目录时只关开关、
   **不清目录**，于是 `.local` 挂着一条死路径：菜单不带「（缺模型目录）」后缀，
   而 `OneShotLoader` 失败不缓存、`detachedWarmUp` 用 `try?` 吞异常且只跑一次，
   每次听写都撞 `guard await translator.isReady`。**用户会等一个永远不会完成的
   加载**，而那行字在这里是错的：不是「慢」，是「没有」。改法是在挂 `.local`
   **之前**用 `CorrectionModelCatalog.validate`（校正层开启时用的同一个判据，
   不另写一套）校一次，不过就落 `.unconfigured`——那一格已有现成的三处告知。
   校验以闭包传进 `translationAttachment`，**那个纯函数仍然不碰文件系统**。
8. **生产转写默认 `.transcribe` 没有任何守卫。** 把
   `WhisperKitTranscriber.init` 里那个默认值改成 `.translate`，981 tests 一条
   不红——而真接错了，每句中文都变成**语义错误**的英文（见第二节那两个例子），
   全部现有指标都看不出来。补了两条断言：默认值是 `.transcribe`、显式传参真的
   被记住（少了后一条，把 `task` 写死成常量也全绿）。
9. **六个门控脚本里三个没有「跑了 0 条算失败」护栏**（`e2e.sh` /
   `translate-sweep.sh` / `whisper-translate.sh`）。补护栏时又量出**第二层
   假绿灯**：`swift test --filter X` 选的是**整个源文件**，于是与门控套件同处
   一个文件的普通用例会把「逐条结果行」的计数顶上去——实测
   `--filter WhisperTranslateSweepTests` 在门控关着时逐条结果行 3 行、退出码 0，
   **只数结果行的护栏在这里是绿的**。判据因此改成两条：逐条结果行 > 0
   **且一条 skipped 都没有**。同一个洞让 `bench-run.sh` 不带语言码那条默认路径
   此前**一条护栏都没有**（护栏只长在带翻译的 xcodebuild 分支上），一并补上。

---

## 八、这一轮的方法论：变异验证成了硬要求

M5 到 M8 栽过**八次**同一类错误，形态各不相同，本质都是「**看着在检查什么，其实什么都没检查**」：

1. M5：基准集术语被逐字抄进生产 prompt → 术语命中率测的是「这个词在不在 prompt 里」，79% 的「提升」是自己喂给自己的
2. M6：`halfWidthPunctuationInChinese` 与转换器共用同一函数且跑在转换之后 → 恒等，永远返回 0
3. M7：把电量字节当固定签名——「13/13 帧相同」是真的，但全来自同一次 40 秒抓包
4. M8：`usesLatinScript` 写成 `requiresTranslation` 的别名 → 循环断言恒真
5. M8：`Set(ids).count == ids.count`——rawValue 重复是**编译错误**，断言永不可能失败
6. M8：`differsOnlyByLanguage` 在「语言名整个写丢」时恒真（替换成了空操作）
7. M8：`asksToPreserveTermsAndNumbers` 钉 `technical`/`number` 两个关键词——把两条规则语义**整个反过来**只留关键词，24 个用例全绿
8. M8：门控脚本的护栏自己是空的（第 7 节第 4 条）

**其中 4–8 全是被变异验证抓到的，读代码时看着都很正常。**

三条固定下来的做法：

- **每条判据都要故意改坏一次、跑一遍、确认对应用例真的红了、再改回来。**
- **变异有三种形态**：断言失败、编译错误、**不收敛的挂起**。只 grep `"Expectation failed"` 会漏后两种。
- **抓不到就明说抓不到**（标准 7 就是），不写一个自证的断言假装守住了。

---

## 九、未竟事项

| | |
|---|---|
| **云端真实联网** | 用户尚未提供 API key，见第六节 |
| **`correctionApplyPending` 零覆盖** | 既有欠账，翻译那一半已被协调器覆盖，校正那一半没有 |
| **葡/法/意没有实测数据** | 菜单上标的是「未实测」，不是「大概和西语差不多」 |
| **`.chinese` 传进 `TranslationPrompt` 的实际行为** | 会生成 "Translate … into Chinese." 这句废话。流水线在调模型之前就分流了，所以到不了，但没测过模型真拿到会返回什么 |
| **两条标注同时出现时的呈现** | 当前是「后写的赢」，已用测试刻意钉住。真要两行显示时那条会先红 |
| **长文本的预算** | 2026-08-19 已修：超时与 token 上限随字数放大（原来 190 字以上必然退回中文）。分档实测见 `Bench/translate-longform.json` |
| **⚠️ 中文大数译错** | 「四十亿」→ "40-billion"，差十倍。现有度量只看 ASCII 数字，看不见这一类。**与报价场景直接相关**，详见 `docs/Roadmap.md` |
| **⚠️ 两处生产代码崩溃** | `RemoteKeySuppressor.handle` 野指针（SIGSEGV）、`SBCDecoder.decodeFrame` 数组越界（SIGTRAP）。**与 M8 无关，08-11 就存在**，已单独记进 Roadmap 并标为优先级最高 |

### ⚠️ M8 削弱了 M4 的串行闸门（有意推迟，未修）

**这一条不是既有欠账，是 M8 自己对一个既有安全机制造成的削弱**，此前只活在
`Correct/CorrectionPipeline.swift:63-80` 那段自己写的「已知，未修」注释里。
合并判断要看得见它，所以搬到这里。

两层共用 `ModelContainer` 之后：

- `InFlightGate`（`CorrectionPipeline.swift:82`）只认得**校正自己**的推理，
  看不见翻译那条；
- `TranslationPipeline` **根本没有闸门**。

再叠上第四节那条实测——**超时取消对 MLX 推理基本无效，GPU 照跑到 EOS**——
一次跑飞的翻译会把后面一两句话的校正和翻译一起挤到超时。用户看到的是连着
两三句「已注入中文原文」，最坏一句话等 16 秒（校正 8 秒 + 翻译 8 秒）。

**后果是降级不是丢字**（规则二不破），所以本轮不修。但它是一次真实的、
被有意推迟的削弱，不该只写在一个源文件的注释里。

### 两处「菜单当场变了，这次不算数」（只记账，不改行为）

录音途中从菜单换输出语言、或切云端开关：**镜像立刻更新**
（`TranslationAttachmentCoordinator.swift` 里那段刻意排在会话 guard 之前，
**这个设计是对的**——菜单标题必须当场就对），但**本次会话仍走旧设置**，
告知只有一条日志。用蓝牙鼠标/遥控器按住说话时，用户的手是够得着菜单的。

同类的第二处：**两条路的响度不一致**。

| 路径 | 缺模型目录时的告知 |
|---|---|
| `selectOutputLanguage` | 菜单后缀 **+ HUD** |
| `toggleCloudBackend`（关掉云端且没有本地模型目录）[^m9] | **只有菜单后缀** |

两处都记在这里而不是修掉：改动会牵动 HUD 的呈现时机，而这一轮的边界是
「只修 QA 找到的问题，不加新功能」。

[^m9]: **函数已于 M9 第一批更名**：`toggleCloudBackend` 被删，切换动作拆成
    `useLocalBackend()` / `useCloudBackend()` 两个幂等方法（理由：菜单换成
    自定义面板后，两项常驻带勾，再点已选中的那项会静默切回本机，而这是
    出站开关）。**这条待办本身仍然成立**，只是现在落在 `useLocalBackend()`
    那条路上——回头修它的人按新名字找。
