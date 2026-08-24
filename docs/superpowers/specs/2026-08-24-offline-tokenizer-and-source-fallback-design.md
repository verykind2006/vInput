# 离线 tokenizer 与下载自动换源（2026-08-24）

M9 第二批在太太机器（用户名 sara）上的第一次真实验收（2026-08-23）留下的
两条待修。日志在仓库 `debug/vInput.log`（含她的用户名路径，不进版本库）。

## 那天到底发生了什么（日志核过的）

| 时刻 | 事 |
|---|---|
| 19:35:27 | 启动，零模型；向导探测两个源，**双双 2.5 秒超时** |
| 19:36:22 | 第四步重试：官方源 HEAD 仓库页 **2.2 秒回了**，选中官方源 |
| 19:37:27 | 下载在 `…/TextDecoderContextPrefill.mlmodelc/analytics/coremldata.bin` 上 **60 秒超时**（这是个几十字节的小文件） |
| 19:39:56、19:40:00 | 两次重试都是双双不通 |
| 19:40:35 → 19:41:38 | 官方源又「探测通过」（1.5 秒），下载 61 秒后超时 |
| 19:53:44 → 19:54:47 | 同上，第三次，在 `AudioEncoder.mlmodelc/model.mil` 上超时 |
| 19:59:53 | 「我已经有模型文件」导入 `~/Documents/openai_whisper-large-v3-v20240930_turbo`（用户从开发机拷的，**没带 tokenizer**） |
| 20:02:11 | `prepare()` 为 tokenizer 去连官方源，**2 分 18 秒**后 `Download failed: The request timed out.`；期间界面只有「正在加载模型…首次可能需要一两分钟」 |

三个事实：

1. **仓库页通 ≠ 下载路径通。** 三次「探测通过」全部紧跟着下载超时，
   而超时的文件里有几十字节的。探的是 `<endpoint>/argmaxinc/whisperkit-coreml`
   （HTML 页），下载走的是 `…/resolve/main/<variant>/<file>`（另一条路，
   多半另一组主机）。探测量错了东西。
2. ~~**在她的网络下 hf-mirror 一次都没响应过。**~~
   **2026-08-24 实施后订正：这条错了。** 6 轮探测里镜像只有 3 轮有失败行
   （19:35:30 / 19:39:58 / 19:40:03），另外 3 轮它没失败、只是比官方源慢。
   判据与完整推理记在 `docs/Roadmap.md`「M9 ② 第一次真实验收」。
   本设计不受影响（换源本来就是为「探得通但下不下来」设计的），但**真机
   预期变了**：自动换源那晚会真的换过去并再下一次，不是「无源可换」。
   表里那几个「X 秒回了」也是**整轮**耗时（= 较慢那个源的），不是官方源
   自己的数字。
3. **模型齐了也说不了话。** 缺一份 2.8 MB 的 tokenizer，用户看到的是两分钟
   「加载中」然后一句看不懂的英文。最后靠人工把 `tokenizer.json` +
   `tokenizer_config.json` 塞进模型目录才用起来。

## ① tokenizer 随 app 分发；缺了就**立刻**说清楚

### 决定：把 `openai/whisper-large-v3` 的 tokenizer 打进 app 包，启动加载前种进 WhisperKit 第一个查的目录

M9 第二批曾否决「打包 tokenizer」（见 `HuggingFaceEndpoint` 的类型注释），
理由是它只治一个变体、一个调用点，真正的风险是「去了另一台主机」。
**那条理由仍然成立，但 08-23 证明它不是全部**：主机修对了，主机本身不通
时照样挂两分钟。两条要一起做——`HF_ENDPOINT` 那条保留，本条补上「根本
不需要联网」的那一半。

- **打包什么**：`Sources/vInput/Resources/Tokenizers/openai/whisper-large-v3/`
  下三个文件（`config.json` 1.3 KB、`tokenizer_config.json` 283 KB、
  `tokenizer.json` 2.4 MB），来自开发机 2026-08-14 从官方源下到的那份
  （`~/Library/Application Support/vInput/huggingface/models/openai/whisper-large-v3/`）。
  **只打这一个仓库**：它同时覆盖 turbo 与 large-v3——向导只下 turbo，
  用户手里拷来拷去的也是这两个；base 那 140 MB 的变体没有人在分发场景
  里用。多打七八个变体要再加 20 MB，换不到任何真实用户。
- **怎么进包**：`Package.swift` 的 `resources: [.copy("Resources/Tokenizers")]`，
  运行时 `Bundle.module`。`build-app.sh` 已经会把 `Products/*.bundle` 整个拷进
  `Contents/Resources/`；**再加一道检查**：包里没有 `tokenizer.json` 就构建
  失败——`Bundle.module` 找不到资源包时是 `fatalError`，不能等用户来发现。
- **种到哪**：`<downloadBase>/models/openai/whisper-large-v3/`，即
  `ModelUtilities.loadTokenizer` **第一个**查的位置（hub 目录）。不种进用户
  的模型目录——那可能在 `~/Documents`（TCC 保护）或只读盘上，往用户自己的
  目录里写东西也不是我们该做的。种入是幂等的：目标已有 `tokenizer.json`
  就不动（用户手动放的、或上次种的，都算）。
- **什么时候种**：`WhisperKitTranscriber.prepare()` 造 `WhisperKit` 之前。
  抽成 `BundledTokenizer.seed(repo:from:into:fileManager:)`（纯文件操作，测得到），生产入口
  `seedIfNeeded(downloadBase:)` 只负责找 `Bundle.module` 和记日志。
- **验收口径**：`HF_ENDPOINT` 指向死地址、`downloadBase` 干净、模型目录只有
  三个 `.mlmodelc`，`prepare()` 必须过。这一条测试进程跑不到（要真模型），
  列进真机清单；能测的是「种完之后 WhisperKit 会查的那个路径上有文件」。

### 没打包的变体：加载前先算「要不要联网」，要联网就先探一下，不通立刻失败

针对 base 等不在包里的变体，以及将来 WhisperKit 换 tokenizer 仓库名的情形：

- `TokenizerPreflight.repo(configJSON:)`：读模型目录的 `config.json`，按
  `vocab_size` + `d_model` 推出 WhisperKit 会去要的仓库名（与
  `ModelUtilities.detectVariant` 同一张表：51866 → large-v3；51865 按
  `d_model` 384/512/768/1024/1280 分 tiny/base/small/medium/large-v2；
  51864 为英文变体）。推不出来就**不做预检**，交给 WhisperKit——宁可慢，
  不可错拦。
- `TokenizerPreflight.isLocal(repo:downloadBase:modelFolder:)`：照抄 WhisperKit
  的四个搜索位置查 `tokenizer.json`。
- 不在本地：读进程 `HF_ENDPOINT`（HubApi 认的就是它）映射回 `DownloadSource`，
  用 `EndpointProbe.probe` 探 2.5 秒。通就放行（日志「tokenizer 不在本地，
  将从 X 下载」）；不通就抛
  `TranscribeError.engineFailed("缺少 tokenizer（openai/whisper-base），而官方源连不上。把 tokenizer.json 和 tokenizer_config.json 放进模型目录后再试。")`
  ——**2.5 秒而不是 2 分 18 秒**，且说了该做什么。
- 向导第五步：模型加载失败时显示那句话，而不是永远的「语音模型还在准备，
  稍等一下…」。接线是 `Wiring.modelLoadFailure: () -> String?`，读
  （**实施后订正**：最终读的是 `AppModel` 上一个独立的存储属性
  `modelLoadFailure`，**不是** `phase` 的 `.error`——启动预热失败那条路
  根本不写 `phase`，照本段原文接会整条丢失。原文如下：）
  `AppModel.phase` 的 `.error`。

## ② 探测量真实下载路径；下载失败自动换另一个源

- **探测 URL 改为** `<endpoint>/argmaxinc/whisperkit-coreml/resolve/main/<variant>/config.json`
  ——下载真正会走的那条路，HEAD、不拉正文。判通的标准不变（任何 HTTP
  响应都算通，只有传输层没回来才算死）。
- `DownloadSource.choose(probe:forced:demoted:)` 加一个「本次会话里下载
  失败过的源」集合：可达的源里**先挑没失败过的**；都失败过就仍按最快的
  挑（用户点了重试，就该再试）。`forced` 仍然最高。
- 向导 `startModelDownload()`：选中源 A 下载失败、且用户没强制源时——
  1. 把 A 记进 `failedSources`；
  2. **只探另一个源 B**（2.5 秒封顶）：通 → 记源（`recordResolvedSource(B)`，
     仍在下载之前）→ 下载；不通 → 失败文案说明「从 A 下载失败，B 也连不上」；
  3. B 也失败 → 记进 `failedSources`，文案「官方源和国内镜像都试过了」。
  自动换源只做**一轮**：A 失败换 B，B 失败就停，不来回打转。
  日志：`下载失败后尝试换源：A → B` / `B 也不通，不再自动换源`。
  （**实施后订正**：实际文案是 `向导：从A下载失败，尝试换源 → B` /
  `向导：B也不通，不再自动换源`。真机 grep 按这个串。）
- 用户强制了源就不换：那是他的明确意愿；文案照旧点名。

## 不做的

- 不改 WhisperKit 的下载超时（在 `vendor/`，不动）。
- 不把「失败过的源」持久化：下次启动网络可能完全不同。
- 不给向导加「选源」界面：面板「高级」区已经有。

## 测试要求

每条新测试都要按 [[mutation-testing-is-mandatory]] 变异一次并交回变异表。
特别要守的两处「接上了没有」：`prepare()` 里种入那一行、`startModelDownload`
里换源那一段——它们各自只有一行调用，删掉之后没有任何编译错误。
