# vInput 设计文档

- 日期：2026-08-11
- 状态：已确认，待编写实施计划
- 许可：GPL-3.0-only

## 一、这是什么

vInput 是一款 macOS 后台应用，把语音变成光标处的文字。

音频来自两个源：小米蓝牙遥控器 2 Pro / RC003 的语音键，或 Mac 内置麦克风加全局快捷键。转写由本地 Whisper 完成，可选经本地或云端 LLM 润色，最终注入当前前台应用的输入框。

全程不依赖任何第三方输入法。

## 二、为什么做

参考项目 [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app) 已验证「用小米遥控器给 Mac 做语音输入」这条路走得通，但它把 BLE 音频写进一个自建的虚拟回环声卡（`MiRemoteV 2ch`，从 BlackHole 派生），再由豆包输入法等第三方工具去识别。

这个架构带来三项固有成本：

1. 必须分发和维护一个音频驱动，连带 pkg 安装器、卸载器、驱动签名
2. 识别质量、标点风格、隐私策略全部受制于第三方输入法
3. 「豆包枚举不到虚拟麦克风」这类排障是该项目的主要用户支持负担

vInput 自己做识别，上述三项一次性全部消失。链路从
`BLE → ADPCM 解码 → 虚拟声卡 → CoreAudio → 第三方输入法`
缩短为
`BLE → ADPCM 解码 → 内存 buffer → Whisper`。

一个关键的技术事实支撑了这个简化：ATV Voice 协议协商到 codec `0x02` 时输出 **16 kHz 单声道 Int16 PCM**，这正是 Whisper 的原生输入格式，无需任何重采样。

## 三、范围

### 做

- 两种音频源：蓝牙遥控器、系统麦克风 + 全局快捷键
- 本地 Whisper 转写，含实时预览与终稿两档
- 可插拔润色层：不润色 / 本地 LLM / 云端 API，默认本地
- 按前台应用自动切换润色风格
- 无焦点浮动 HUD，显示录音状态与实时转写
- 文本注入当前输入框，长文本走剪贴板路径

### 不做

- 遥控器普通按键映射（方向、音量、打开应用等）——那是 remote-mic-app 的职责
- 手机伴侣 App
- Windows 版本
- 使用统计页面
- Sparkle 自动更新（v1 走 GitHub Release 手动更新）
- 虚拟音频驱动（本项目的核心简化就是消灭它）
- macOS 输入法（InputMethodKit）——不做，但架构留出接缝

### 目标使用场景

| 场景 | 触发方式 | 典型时长 | 对润色的要求 |
|---|---|---|---|
| 给 AI 写 prompt（Vibe Coding） | 遥控器按住说 | 10–40 秒 | 技术术语与标识符原样保留 |
| 微信 / 聊天消息 | 遥控器按住说 | 3–15 秒 | 保留口语感，不要书面化 |
| 长文 / 文档 / 笔记 | 内置麦 + 快捷键 | 1–10 分钟 | 完整标点、分段、去口水词 |

明确不追求「终端里口述 shell 命令」这一场景，它对逐字符准确度的要求超出本设计的目标。

### 一个硬约束：遥控器录音时长

RC003 按住语音键约 60 秒后固件会主动结束 ATVV 会话。remote-mic-app 的应对是每 10 秒发送 `MIC_EXTEND`（`0x0E`）续租，把上限推到 3 分钟，但其项目文档记录该行为「仍需真机验收」，状态为「等待人工验收」。

叠加人体工学因素（按住一个键说三分钟不成立），本设计的结论是：**长文场景由内置麦承担，不由遥控器承担**。内置麦路径采用切换式触发（按一下开始，再按一下停），无时长限制。

因此内置麦不是遥控器的备胎，而是与之并列的一等输入源。

## 四、架构

### 五层流水线

```
┌─ 音频源层  AudioSource ──────────────────────────┐
│  BluetoothRemoteSource   ← 移植 ATVV + BLE        │  16 kHz
│  SystemMicSource         ← AVAudioEngine + 重采样 │  Int16 mono
└──────────────────────────────────────────────────┘
                    ↓ 音频帧 + 会话开始/结束事件
┌─ 会话层  DictationSession ───────────────────────┐
│  状态机：idle → listening → transcribing          │
│          → polishing → injecting → idle           │
│  持有整段音频缓冲，同时驱动滑窗                     │
└──────────────────────────────────────────────────┘
          ↓ 滑窗 2–3 s                  ↓ 整段音频
┌─ 转写层  Transcriber ────────────────────────────┐
│  实时预览：小模型跑滑窗 → 粗糙文本 → HUD           │
│  终稿    ：大模型跑全量 → 准确文本                 │
└──────────────────────────────────────────────────┘
                    ↓ 原始转写 + 场景上下文
┌─ 润色层  Polisher ───────────────────────────────┐
│  None / Local(MLX) / Cloud(OpenAI 兼容)          │
│  超时 3 s 自动降级为原文                           │
└──────────────────────────────────────────────────┘
                    ↓ 最终文本
┌─ 输出层  TextSink ───────────────────────────────┐
│  TypingSink     ← CGEventKeyboardSetUnicodeString │
│  ClipboardSink  ← 长文本与降级路径                 │
└──────────────────────────────────────────────────┘
```

四个 protocol 是四条接缝：音频从哪来、用什么引擎转写、润不润色、文字怎么送出去，四件事互不知情，可各自替换、各自测试。

### 为什么两种触发共用一条链路

遥控器与内置麦的全部差异被 `AudioSource` 吸收，上面四层不知道音频来源。两个直接后果：

1. 开发期不插遥控器也能调通约 80% 的代码
2. 未来新增音频源（如手机、其他蓝牙设备）只需实现一个 protocol

### 时序：实时预览与终稿的关系

Whisper 是分块推理，不是真流式：需要 2–5 秒窗口才出一块结果，且后续上下文会修正先前结果。LLM 润色则必须等一句话说完才有意义——无法对半句话做语义纠错。

```
说话中 ──────────────────→ 松开 / 再按快捷键
  │                              │
  ├ 滑窗转写（小模型）             ├ 全量重转（大模型）
  │    ↓ 粗糙文本                  ↓
  │  [HUD 实时预览]              LLM 润色 → [最终文本] → 注入
```

**实时预览的作用是让用户知道系统在听、听到了什么，它从不构成最终结果。** 最终文本在会话结束后 0.5–3 秒到达，并整体替换预览。

这个定位决定了模型分档：预览用 `base` 或 `small`（快、糙、够看），终稿用 `large-v3-turbo` 量化版（有完整上下文，中文质量好，Apple Silicon 上约 10–15× 实时速）。没有必要用大模型去追一个注定被丢弃的中间结果。

### HUD

无边框浮动面板（`NSPanel`，`.nonactivatingPanel`），不抢焦点，显示三个阶段：录音中（波形 + 时长）→ 实时粗糙转写 → 润色中。文字注入后淡出。

**因为不抢焦点，HUD 上不能有任何需要点击的控件。** 用户在别的应用里说话，焦点必须始终留在目标输入框上，否则文字无处可注。取消操作只能通过快捷键（Esc）或遥控器按键触发，不能通过鼠标点击 HUD。

## 五、技术选型

### 转写：WhisperKit

选 Argmax 的 WhisperKit 而非 whisper.cpp。WhisperKit 是纯 Swift 包，SPM 直接集成，运行于 Core ML / ANE，自带流式转写与模型下载管理。whisper.cpp 需要 C++ 桥接，在 SwiftUI 工程中构成持续维护负担。

| 用途 | 默认模型 | 滑窗参数 |
|---|---|---|
| 实时预览 | `small` | 窗口 5 秒，步进 2 秒（相邻窗口重叠 3 秒，减少切词） |
| 终稿（全量重转） | `large-v3-turbo` 量化版 | 不适用 |

两档模型均可在设置中更换。低配机器上若预览跟不上，可降至 `base`。

### 本地润色：MLX Swift + Qwen3-4B-Instruct 4bit

默认模型为 Qwen3-4B-Instruct 的 4bit 量化版（约 2.3 GB），模型 ID 可在设置中更换。

MLX 是 Apple 官方的 Swift 绑定，SPM 可集成，直接使用统一内存，用户无需另行安装 Ollama 等外部运行时。用户视角是「首次启动点一下下载」，而非「先去装一个别的软件」。

云端润色实现走 OpenAI 兼容接口，用户自行填入 base URL 与 API Key。

### 模型下载

首次下载总量约 3 GB（Whisper 两档 + LLM）。必须在 onboarding 中明确告知，并支持分步下载：**只下载 Whisper 即可使用（不润色），LLM 可后补**。任一模型缺失时，对应功能降级而非阻塞整个应用。

## 六、三条关键规则

### 规则一：场景风格由前台应用决定

三个内置 profile，匹配规则与各自的 prompt 均可在设置中编辑：

| Profile | 默认匹配 | 润色行为 |
|---|---|---|
| 技术 | Cursor、VS Code、Terminal、iTerm、Claude Code | 英文术语与标识符原样保留不翻译（`useEffect` 不得变成音译）；不加口语化标点；容忍长句 |
| 口语 | 微信、Telegram、Slack、Discord | 保留口语感，短句，克制标点；不将「那我明天再看看吧」改写为书面语 |
| 书面 | 备忘录、Obsidian、Pages、浏览器 | 完整标点、分段、去口水词、书面表达 |

匹配不到任何规则时使用「书面」。

profile 在会话开始时依据前台应用的 bundle ID 确定，并随转写文本一同传入润色层。

### 规则一之补充：输出统一为简体中文

Whisper 的中文训练数据中繁体占比很高，即便在 `DecodingOptions` 中指定 `language: "zh"` 也经常输出繁体。M1 实测输出为「幫我把這個…裏…測試」。

因此转写层出口须统一做一次繁简转换，使用系统内置的 ICU 音译器（`CFStringTransform` + `"Hant-Hans"`），无需第三方依赖或词表文件。已是简体的字符、拉丁字母、数字与标点均原样保留。

该转换**只改字形，不改用词**。同音错字（如「函数」被识别为「寒暑」）属于识别错误，由模型选型或润色层负责，不在此层处理。

面向繁体中文用户时该转换可关闭，因此实现为可配置开关而非硬编码。

### 规则二：永不丢字

任何一层失败，用户说出的内容都必须以某种形式落地。这是整条流水线的最高优先级。

| 失败情形 | 处理 |
|---|---|
| 润色超时（> 3 s）或报错 | 直接注入原始转写，HUD 标注「未润色」 |
| 注入失败（无辅助功能权限 / 应用拒绝） | 写入剪贴板 + 系统通知「文字已复制」 |
| BLE 中途断连 | 已接收的音频照常转写并注入，不丢弃 |
| 转写失败 | HUD 报错，音频保留在内存中，支持一键重试 |
| 模型未下载 | HUD 引导下载，不进入录音状态 |

### 规则三：注入前校验目标应用

会话开始时记录前台应用的 bundle ID。注入前再次读取，**不一致则不注入**，改为写入剪贴板 + 通知。

此规则防范的是最严重的失败模式：用户在 Cursor 中口述内容，中途其他应用抢占焦点，导致内容被注入错误的窗口——可能造成信息泄漏。宁可让用户多按一次 Cmd+V。

补充：文本长度**超过 100 个字符**时，同样绕开逐字符注入，改用剪贴板 + Cmd+V，随后恢复原剪贴板内容（延迟校验以避免竞态）。逐字符注入数百个中文字符在终端与 Electron 应用中几乎必然出错。该阈值可在设置中调整。

## 七、工程结构

```
vInput/
├── Package.swift                      SPM, macOS 14+
└── Sources/vInput/
    ├── App/          vInputApp, AppModel, Permissions
    ├── Audio/        AudioSource(protocol)
    │                 BluetoothRemoteSource, SystemMicSource
    │   └── Vendored/ ATVVProtocol, XiaomiBluetoothBridge      ← GPL 来源
    ├── Session/      DictationSession(状态机), AudioBuffer
    ├── Transcribe/   Transcriber(protocol)
    │                 WhisperKitTranscriber, ModelStore
    ├── Polish/       Polisher(protocol)
    │                 LocalPolisher(MLX), CloudPolisher, NonePolisher, Profile
    ├── Output/       TextSink(protocol)
    │                 TypingSink, ClipboardSink, TargetAppGuard
    │   └── Vendored/ AccessibilityFocusLocator（M6 才引入，见第八节）← GPL 来源
    ├── UI/           HUDPanel, HUDView, MenuBar, Settings/
    └── Support/      Hotkey, Logger
```

移植自 remote-mic-app 的代码全部隔离在 `Vendored/` 目录下并标注来源，使 GPL 溯源清晰，且未来替换某一块时边界明确。

四个 protocol 之外，还有一个免费的副产品：若将来决定做输入法，只需增加一个 `TextSink` 实现，前四层无需改动。

## 八、代码来源与许可

vInput 采用 **GPL-3.0-only**，因为它移植了 remote-mic-app（GPL-3.0-only）的以下代码：

| 来源 | 约行数 | 作用 | 引入时机 |
|---|---|---|---|
| `ATVVProtocol.swift` | 161 | ATV Voice 协议常量、能力协商、IMA ADPCM 解码、帧累积 | M3 |
| `XiaomiBluetoothBridge.swift` | 1048 | CoreBluetooth 状态机：配对、重连、MTU 分片、会话生命周期 | M3 |
| `KeyboardInjector.swift` 中的 Accessibility 焦点定位部分 | 约 400 | 遍历 AX 树寻找可输入元素、候选打分、确认焦点 | M6，可选 |

选择移植而非重写的理由：`XiaomiBluetoothBridge` 是整个项目中唯一必须依靠真机反复调试才能稳定的部分（系统蓝牙栈行为、分片丢包、双设备隔离），重写意味着重踩已被踩过的坑，且这部分对 vInput 的差异化价值最低。

**关于 `KeyboardInjector.swift` 的更正**：该文件不具备文本注入能力（全仓库无 `CGEventKeyboardSetUnicodeString` 或 `UniChar` 的使用）。它是一个*按键动作*注入器，将 `ButtonAction`（音量、播放控制、打开应用、自定义快捷键）转换为 CGEvent 键码，服务于 remote-mic-app 的按键映射功能——而按键映射明确不在 vInput 范围内。

因此 vInput 的文本注入（`TypingSink`）**自行实现**，基于 `CGEventKeyboardSetUnicodeString`，约 150 行，无 GPL 牵连。该文件中确有价值的是其 Accessibility 焦点定位逻辑，但那属于稳固化阶段的可选优化，M1 不需要。

**M1 至 M2 不引入任何移植代码**，届时可自由选择许可；GPL-3.0-only 的约束自 M3 引入 BLE 代码起生效。

README 中须署明派生自 [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app)，并保留其上游 [nijez/open-voice-bridge](https://github.com/nijez/open-voice-bridge) 的溯源信息。

remote-mic-app 的 Logo 与 App Icon 是需单独授权的专有资产，**不得使用**。vInput 需自备品牌资产。

## 九、测试策略

不追求覆盖率数字，只测会真正出错且能自动化的部分。

| 层 | 方式 |
|---|---|
| 纯函数（ADPCM 解码、帧累积、profile 匹配、长文本阈值判定） | 单元测试，已知向量 |
| `DictationSession` 状态机 | **测试重点。** 注入 Fake 的 AudioSource / Transcriber / Polisher，将规则二的五条降级路径逐条覆盖 |
| `TargetAppGuard` | 注入假的前台应用提供者，验证不一致时走剪贴板 |
| WhisperKit / MLX 适配层 | 不测第三方库本身，只测超时、取消、错误映射 |
| 转写质量 | 自录 20–30 条 golden 音频覆盖三个场景，不做断言，用于版本间回归对比 |
| 键盘注入 | 无法自动化，维护真机手测清单 |

## 十、里程碑

每个里程碑结束必须交付可实际使用的功能，不堆叠半成品。

| | 内容 | 验收标准 |
|---|---|---|
| M1 | 骨架 + 内置麦 + 转写 + 注入 | 在备忘录中按快捷键说一句话，文字出现。此时已是可用的听写工具 |
| M2 | HUD + 实时预览 | 说话时能在浮窗看到文字逐渐出现 |
| M3 | 遥控器接入 | 按住遥控器语音键，体验等同 M1 + M2 |
| M4 | 润色层 | 同一句话开关润色能看出明显差别 |
| M5 | 场景风格 | 同一句话在 Cursor 与微信中得到不同结果 |
| M6 | 稳固化 | 五条降级路径、目标应用校验、长文本剪贴板路径、权限引导、设置界面、onboarding |

**M1 完全不需要遥控器。** 这是「内置麦作为一等输入源」这一决定的直接回报：第一天即可验证「本地 Whisper 的中文质量是否够用」这一最大未知数，无需等待 BLE 调通。若 M1 的转写质量不达预期，方向问题在此刻暴露，纠正代价最小。

## 十一、权限

| 权限 | 用途 | 何时申请 |
|---|---|---|
| 麦克风 | 内置麦录音 | 首次使用内置麦触发时 |
| 蓝牙 | 连接遥控器、接收语音 | 首次使用遥控器时 |
| 辅助功能 | 注入文本到前台应用（`CGEvent.post`） | onboarding 中引导 |

**不需要「输入监控」权限。** 全局快捷键使用 Carbon 的 `RegisterEventHotKey`（HIToolbox），该 API 不需要任何隐私授权。只有发送 CGEvent 才需要辅助功能。

开发期注意：辅助功能授权绑定应用签名，**每次重新签名后需重新授权**。

## 十二、隐私

- 音频不落盘，仅存在于会话期间的内存缓冲中
- 默认配置下（本地转写 + 本地润色）无任何数据离开设备
- 启用云端润色时，转写后的**文本**会发送至用户配置的服务端点。此行为须在设置界面明示，且不得为默认值
- 日志不记录转写内容、蓝牙地址与外设标识；如需调试内容级日志，须由用户显式开启
