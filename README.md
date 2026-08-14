# vInput

macOS 本地语音输入工具。按快捷键或小米蓝牙遥控器的语音键说话，本地 Whisper
转写后把文字注入当前光标处。不依赖任何第三方输入法。

## 特性

- 本地转写，音频不出机器，不落盘
- 说话时在浮窗中实时预览文字
- 支持内置麦克风（全局快捷键 ⌥D）与小米蓝牙遥控器 2 Pro / RC003
- 输出统一为简体中文
- 菜单栏可随时切换 Whisper 模型

## 系统要求

- Apple Silicon Mac，macOS 14 或更高版本
- 使用遥控器时需先在系统蓝牙设置中完成配对

## 权限

| 权限 | 用途 |
|---|---|
| 麦克风 | 内置麦录音 |
| 辅助功能 | 把转写结果注入当前应用 |
| 蓝牙 | 连接遥控器、接收语音 |
| 输入监控 | 识别遥控器的返回键（用作取消） |

未授予「输入监控」时听写照常工作，仅遥控器返回键取消不可用。

## 许可与来源

本项目采用 **GPL-3.0-only**。

蓝牙协议层移植自 [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app)
（GPL-3.0-only），涉及以下文件：

- `Sources/vInput/Audio/Vendored/ATVVProtocol.swift`
- `Sources/vInput/Audio/Vendored/BluetoothLifecycle.swift`
- `Sources/vInput/Audio/Vendored/RemoteDeviceTypes.swift`
- `Sources/vInput/Audio/Vendored/XiaomiBluetoothBridge.swift`

各文件头部记录了相对上游的适配。

remote-mic-app 最初 fork 自 [nijez/open-voice-bridge](https://github.com/nijez/open-voice-bridge)。

remote-mic-app 的 Logo 与 App Icon 是需单独授权的专有品牌资产，本项目**未使用**。

转写使用 [WhisperKit](https://github.com/argmaxinc/WhisperKit)（MIT）。
