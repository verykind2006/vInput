# vInput M3 设计：蓝牙遥控器接入

- 日期：2026-08-14
- 状态：已确认，待编写实施计划
- 上位文档：[M1 总体设计](2026-08-11-vinput-design.md)、[M2 HUD 与实时预览](2026-08-13-vinput-m2-hud-design.md)
- 前置里程碑：[M1 验收](../../../Testing/M1-Acceptance.md)、[M2 验收](../../../Testing/M2-Acceptance.md)

## 一、目标

用小米蓝牙遥控器 2 Pro / RC003 的语音键触发听写。

用户原话：

> 按下小米遥控器的语音键，相当于按下了 `⌥D`，开始整个流程；松开语音键，相当于又按了一次 `⌥D`，结束整个流程。

即：**遥控器只是换了个触发方式，下游一个字都不变**——HUD 出现、实时预览、松手转写、注入光标，全部复用 M1/M2 已验收的路径。

## 二、范围

### 做

| # | 内容 |
|---|---|
| 1 | 语音键按下 → `session.start()`，松开 → `session.finish()` |
| 2 | 移植 BLE 协议层：ATVV 协议、IMA ADPCM 解码、CoreBluetooth 状态机 |
| 3 | `AudioSourceRouter`：内置麦与蓝牙共存，会话层不感知 |
| 4 | 返回键 → 取消会话（自写最小 HID 监听） |
| 5 | 菜单栏显示遥控器连接状态 |
| 6 | `MIC_EXTEND` 保活：每 10 秒发一次，累计上限 180 秒 |

### 不做

- 遥控器其他按键的映射（方向、确定、主页、菜单、TV、音量、电源）
- 多遥控器同时连接
- 遥控器的**配对**流程——走 macOS 系统蓝牙设置，本应用只负责连接已配对设备
- 手机伴侣 App、Windows 版

## 三、已核实的硬事实

均通过阅读 `remote-mic-app` 源码确认（2026-08-14），实现时以此为准。

### BLE 侧

ATV Voice 协议（Google 的公开协议）：

```
service   AB5E0001-5A21-4F05-BC7D-AF01F617B664
transmit  AB5E0002-5A21-4F05-BC7D-AF01F617B664
audio     AB5E0003-5A21-4F05-BC7D-AF01F617B664
control   AB5E0004-5A21-4F05-BC7D-AF01F617B664
```

- 音频编码为 **IMA ADPCM**；协商到 codec `0x02` 时为 **16 kHz 单声道**，解码后是 `Int16` PCM
- 16 kHz 正是 `AudioFormat.sampleRate`，**无需重采样**——这是 M1 设计时选定该格式的原因
- `MIC_EXTEND`（`0x0E`）用于延长会话；RC003 按住语音键约 60 秒后固件会主动结束 ATVV 会话

### HID 侧

- 设备匹配：VendorID `0x2717`（小米）、ProductID `0x32B8`
- **返回键的 HID usage 是 `0xF1`**，不是标准 Escape（`0x29`）。因此现有的 Carbon Esc 全局热键接不住它，必须自行监听 HID
- 报文格式：`reportID == 1`；若长度为 7 且首字节等于 reportID 则去掉首字节；其余按小端 `UInt16` 两两读出，非零者即为当前按下的 usage 集合

## 四、移植清单与成本

### 移植（GPL-3.0-only 自此生效）

| 来源文件 | 行数 | 内容 |
|---|---|---|
| `ATVVProtocol.swift` | 161 | 协议常量、能力协商、IMA ADPCM 解码、帧累积、PCM 后处理 |
| `BluetoothLifecycle.swift` | 118 | 设备名匹配、生命周期阶段、会话门控 |
| `XiaomiBluetoothBridge.swift` | 1048 | CoreBluetooth 状态机：配对、重连、MTU 分片、会话生命周期 |

对上游其余代码的依赖仅三处，均轻量：

| 依赖 | 处理 |
|---|---|
| `AppLogger.write`（35 处） | 机械替换为本项目的 `AppLogger.log` |
| `AppSettings.gainDB`（1 处） | 改为构造参数 |
| `ATVVSessionGate`、`BluetoothLifecyclePhase` | 均在 `BluetoothLifecycle.swift` 内，随之一起移植 |

不需要触碰上游的设置系统、按键映射、UI——那些正是本项目不要的部分。

### 自写而非移植：HID 监听

上游的 HID 子系统共 1541 行（`HIDRemoteMonitor` 702 + `RemoteButtons` 645 + 其余），体量集中在按键映射、手势识别、多设备档案上。本项目只需识别一个 usage，报文解析本身仅 17 行。

**因此自写一个最小监听器**（约 180 行），完全归本项目所有，不引入 GPL 牵连，也不背上不需要的抽象。

## 五、架构

### 音频源路由

```
        ⌥D ──────────────┐
                         ↓
  遥控器语音键 ──→ AudioSourceRouter ──→ DictationSession
                    │         │            （不知道音频从哪来）
                    ↓         ↓
            SystemMicSource  BluetoothRemoteSource
```

`AudioSourceRouter` 本身实现 `AudioSource`，因此**会话层一行不改**。路由器在 `start()` 之前被告知本次用哪个源，随后转发该源的帧。

**为什么不让 `DictationSession` 支持换源：** M2 给 `previewEngine` 加运行时挂载时已经付过一次代价——牵出 `attachPreviewEngine`、回调重绑、状态守卫一串东西。音频源比预览引擎更核心，它在构造时就接管了 `onFrame`，中途替换要处理正在录音、缓冲区归属等边界。

路由器还收敛了一处 M2 遗留的别扭：M2 在 `AppModel` 里手工包了一层 `micSource.onFrame`，让音频同时流向会话与预览处理器。两个源之后这段要写两遍。**路由器让音频分叉点只剩一处**——这是 M2「分叉在 `AudioSource` 之后」那个决定的自然延续，也是 M2 预期的红利：蓝牙源接上后，HUD 与实时预览零改动自动可用。

**一次只有一个源活跃。** 遥控器录音期间按 `⌥D` 会被忽略——会话状态机本就挡住非 idle 状态的 `start()`。

### 触发语义

| 触发 | 会话动作 |
|---|---|
| `⌥D` 按下（idle 时） | `start()` |
| `⌥D` 按下（listening 时） | `finish()` |
| **遥控器语音键按下** | `start()` |
| **遥控器语音键松开** | `finish()` |
| `Esc` 或遥控器返回键 | `cancel()` |

`⌥D` 是切换式、语音键是按住式，但落到会话层都是 `start` / `finish`，无需区分。

### 新增组件

| 文件 | 职责 |
|---|---|
| `Audio/AudioSourceRouter.swift` | 在多个音频源之间路由，自身实现 `AudioSource` |
| `Audio/BluetoothRemoteSource.swift` | 实现 `AudioSource`，Int16 → Float 归一化，订阅蓝牙桥的音频流 |
| `Audio/Vendored/ATVVProtocol.swift` | 移植 |
| `Audio/Vendored/BluetoothLifecycle.swift` | 移植 |
| `Audio/Vendored/XiaomiBluetoothBridge.swift` | 移植 |
| `Remote/RemoteHIDListener.swift` | 最小 HID 监听，识别返回键 |
| `Remote/RemoteConnectionState.swift` | 连接状态，供菜单栏展示 |

## 六、错误处理

沿用「规则二·永不丢字」，并针对蓝牙的新失败模式补充：

| 失败 | 处理 |
|---|---|
| 遥控器未连接时按语音键 | 不会发生——未连接就收不到事件 |
| 录音中途蓝牙断连 | **已收到的音频照常转写并注入**。M2 的 `DictationSession` 已为此设计：`onStop(error)` 只在 `.listening` 期间才中止会话，进入转写阶段后到达的错误一律忽略 |
| 极短按压 | 短于 `WhisperKitTranscriber.minimumDuration`（0.3 秒）时转写层抛 `audioTooShort`。**静默忽略，不弹错误**——按一下就松是常见误触 |
| `MIC_EXTEND` 写入失败 | 记日志并继续尝试，不中断会话。连接真正断开时由既有生命周期终止 |
| 超过保活上限 | 上限取 180 秒（沿用上游的试验安全值，非固件限制）。到点后主动结束会话并走正常转写路径，不丢弃已录内容 |
| HID 权限未授予 | 遥控器语音键**照常工作**（走 BLE，只需蓝牙权限）；仅返回键取消不可用，菜单栏提示 |

最后一条是有意的分层：**取消是锦上添花，听写是主路径**。缺少「输入监控」权限不得影响听写。

## 七、权限

| 权限 | 用途 | M1/M2 是否已有 |
|---|---|---|
| 麦克风 | 内置麦录音 | 已有 |
| 辅助功能 | 注入文本 | 已有 |
| **蓝牙** | 连接遥控器、接收语音 | **新增** |
| **输入监控** | 识别遥控器返回键 | **新增** |

M1、M2 特意避开了「输入监控」（全局快捷键走 Carbon `RegisterEventHotKey` 无需授权）。加遥控器取消键必须引入它——这是该功能的附带成本，已向用户说明并确认。

## 八、测试策略

| 层 | 方式 |
|---|---|
| IMA ADPCM 解码 | 纯函数，已知输入输出向量，单元测试 |
| HID 报文解析 | 纯函数，构造报文断言 usage 集合，单元测试 |
| `AudioSourceRouter` | 注入多个 `FakeAudioSource`，验证只转发当前活跃源、切换时正确启停 |
| `BluetoothRemoteSource` 的 Int16 → Float 归一化 | 纯函数，单元测试 |
| 触发语义 | 注入假的触发事件，验证按下→`start`、松开→`finish` |
| CoreBluetooth 状态机 | **不做自动化测试。** 需要真实外设，且这正是移植而非自写的原因——上游已在真机上磨过 |
| 端到端 | 扩充 `PipelineE2ETests`，并新增真机手测清单 |

### 端到端体检的扩充

M2 建立的规矩是「每发现一类问题就往 `PipelineE2ETests` 加一条断言」。M3 的蓝牙路径需要真实外设，无法在无硬件时自动化，因此另立真机手测清单。

但有一段**可以**自动化并应当加入 E2E：把一段已知的 ADPCM 数据解码成 PCM，喂进与麦克风完全相同的转写路径，断言产出非空且不含特殊标记与结尾幻觉。这验证的是「蓝牙解码出来的音频能被现有管线正确消费」，无需外设。

## 九、验收标准

1. 遥控器连接后，菜单栏显示已连接
2. **按住语音键说话，HUD 出现、实时预览逐字显现；松开后文字注入光标处**——与 `⌥D` 的行为完全一致
3. 说到一半按遥控器返回键，会话取消，无任何文字注入
4. 录音中途关闭遥控器，已说的内容仍被转写并注入
5. 按住语音键**超过 60 秒**仍持续录音（验证 `MIC_EXTEND` 保活）
6. 极短按压不产生错误提示
7. `⌥D` 与内置麦的既有路径不受影响

第 5 项是本里程碑相对上游的额外价值：上游文档记录该行为「仍需真机验收」，状态挂在「等待人工验收」。本项目有硬件，可首次真正确认。

## 十、遗留与影响

- **GPL-3.0-only 自 M3 起生效。** README 须署明派生自 [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app)，并保留其上游 [nijez/open-voice-bridge](https://github.com/nijez/open-voice-bridge) 的溯源信息。remote-mic-app 的 Logo 与 App Icon 是需单独授权的专有资产，不得使用。
- M1、M2 的遗留项（本地路径依赖、模型路径为开发期布局、模型选择不持久化）不在 M3 范围内，留待 M6。
