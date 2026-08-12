# M1 端到端验收清单

自动化测试已覆盖全部可自动化的部分（76 个测试）。剩下的必须真机手测：真实麦克风、真实模型、真实的系统事件注入。**这份清单需要人来执行。**

- 日期：待填
- 机型：Apple M3 / macOS 26.5.2
- 模型：WhisperKit v1.1.0 / `openai_whisper-base` / `language=zh`

---

## 准备

```bash
cd "/Users/vk/Library/CloudStorage/OneDrive-个人/projects/vInput"
./scripts/build-app.sh
open dist/vInput.app
```

预期：菜单栏右上角出现麦克风图标。

## 授予权限

1. 打开「系统设置 → 隐私与安全性 → 辅助功能」，把 `dist/vInput.app` 加进去并勾选
2. **完全退出 vInput 再重新打开**（辅助功能授权需要重启进程才生效）

预期：点开菜单栏图标显示「就绪」。

> 开发期注意：辅助功能授权绑定应用签名。每次重新运行 `build-app.sh` 都会重新 ad-hoc 签名，**可能需要重新授权**。

---

> **快捷键是 `⌥D` = Option + D，不是 Cmd + D。** ⌥ 是 Option 键的符号。
> 首次验收时因这一点误按 Cmd+D，误判为快捷键失效。已确认 Option+D 工作正常。

## 步骤 1：基础中文听写

打开「备忘录」新建一条，点进正文让光标闪烁，按 `⌥D`（Option+D）开始，说一句中文，再按 `⌥D` 结束。

建议说：「今天下午三点开会讨论新版本的发布计划」

首次会弹出麦克风授权，允许它。

- 原话：
- 转写结果：
- 松手到出字耗时：
- 是否出现在光标处：

## 步骤 2：长文本走剪贴板

先复制一段任意文字（用于验证剪贴板恢复）。然后按 `⌥D`，连续说一段**超过 100 字**的话，再按 `⌥D`。

- 文字是整段出现还是逐字蹦出（应为整段）：
- 约 0.6 秒后，剪贴板是否恢复成你先前复制的内容：

## 步骤 3：目标应用校验（规则三）

按 `⌥D` 开始说话，说到一半用 `⌘Tab` 切到另一个应用，再按 `⌥D` 结束。

- 文字是否**没有**被注入到新应用（应为「没有」）：
- 菜单栏是否显示出错信息：

## 步骤 4：中英混输基线

在 Cursor 或任意编辑器里，说：「帮我把 useEffect 里的 dependency array 改一下」

- 转写结果：
- 英文术语识别质量：

> 已知：Task 2 的 spike 用同类语句测出 `base` 模型会把「函数」听成「寒暑」、「依赖数组」听成「依赖树足」，且**输出为繁体字**。这一步是确认真机表现是否与 spike 一致。

## 步骤 5：错误路径抽查

- 不授予辅助功能权限时按 `⌥D`，菜单栏是否提示「需要辅助功能权限」并打开系统设置：
- 极短的一声（不到 0.3 秒）是否被安静忽略而非报错：

---

## 结论

- **M1 验收标准（在备忘录里按快捷键说一句话，文字出现）是否达成：**
- 发现的问题：
- 对 M2–M6 的影响：

---

## 已知的待决问题（不阻塞 M1 验收）

1. ~~**输出繁体字。**~~ **已解决。** 转写层出口用系统内置 ICU 音译器（`CFStringTransform` + `"Hant-Hans"`）统一转简体，零依赖零延迟。已是简体的文本、英文标识符、数字标点均不受影响。见 `Sources/vInput/Transcribe/ChineseScript.swift`。验收时请确认步骤 1 与步骤 4 的输出确为简体。
2. **`base` 模型技术中文不可用。** 转写只花 0.75 秒处理 5 秒音频，性能预算充裕，应评估换 `large-v3-turbo`：
   ```bash
   ./scripts/fetch-model.sh openai_whisper-large-v3-v20240930_turbo
   ```
   然后改 `Sources/vInput/App/AppModel.swift` 里 `resolvedModelFolder()` 的目录名与 `modelName`。
3. **`Package.swift` 用的是本地路径依赖**（`vendor/WhisperKit`），因执行期网络持续丢包。网络好转后应改回版本化远程依赖：
   ```swift
   .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.0")
   ```
4. **模型路径解析是开发期布局**：`AppModel.resolvedModelFolder()` 假设 `.app` 位于 `<repo>/dist/` 下、模型位于 `<repo>/vendor/models/`。正式分发需改为应用支持目录，属 M6 范围。
