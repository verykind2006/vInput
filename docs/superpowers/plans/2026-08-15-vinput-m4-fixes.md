# M4 验收修订 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修掉独立 QA 在 M4 上发现的两个阻塞项与三个重要项，使「同一句话开关校正能看出差别」这一验收标准真正可验证。

**Architecture:** 五处独立修复，互不依赖：推理改用可取消的流式 API、偏好变更延迟补挂、解析器容忍模型的装饰性输出、拒绝无上下文的单字替换、端到端补一条能证伪的对照断言。

**Tech Stack:** Swift 6 / Swift Testing / MLX Swift（`MLXLLM` + `MLXLMCommon` 2.29.1）

---

## 背景：给不熟悉本仓库的工程师

vInput 是一款 macOS 后台语音输入应用：按快捷键或小米蓝牙遥控器语音键说话 →
本地 Whisper 转写 → 文字注入当前光标处。M4 在转写与注入之间加了一层本地 LLM，
修正 Whisper 听错的字词（真机案例：说「小米遥控器」，Whisper 输出「小米耀空气」）。

M4 的代码已全部写完（11 个提交，360 个测试通过），但独立 QA 发现它**实际上很可能
完全不生效**。本计划修的就是那些问题。

**必须用 `./scripts/test.sh` 跑测试，不能用 `swift test`。** 本机是纯 Command Line
Tools 环境，缺少 Swift Testing 的框架搜索路径，`swift test` 会报
`no such module 'Testing'`。

**代码注释一律中文**，解释「为什么」而非「是什么」。

### 三条铁律

1. 规则一：场景风格由前台应用决定（M5 的事，本计划不碰）
2. **规则二·永不丢字**：任何失败路径都不得让用户已经说出的内容消失或被篡改
3. 规则三：注入前校验目标应用未变

### 已验证的事实（不要重新推导，也不要假设它们会变）

- `ChatSession.respond(to:)` 走同步版 `MLXLMCommon.generate(input:context:iterator:didGenerate:)`
  （`Evaluate.swift:597-646`），该循环**没有任何取消检查**
- `ChatSession.streamResponse(to:) -> AsyncThrowingStream<String, Error>` 走的是
  `MLXLMCommon.generate(input:cache:parameters:context:)` 的 AsyncStream 重载，
  它在 `Evaluate.swift:809` 有 `if Task.isCancelled { break }`
- 但 `stream()` 内部是 `AsyncThrowingStream { continuation in Task { ... } }`
  ——**非结构化 `Task`，没有 `onTermination`**。取消消费方**不会**取消生产方，
  生产方会把推理跑完才释放
- `ModelContainer.perform` 是串行的：被放弃的推理会挡住下一次推理

---

## 文件结构

| 文件 | 本次改动 |
|---|---|
| `Sources/vInput/Correct/MLXCorrector.swift` | 改用流式 API；压低 maxTokens |
| `Sources/vInput/Correct/CorrectionPipeline.swift` | 订正一处与事实相反的注释 |
| `Sources/vInput/Correct/CorrectionEditParser.swift` | 剥离装饰性前后缀 |
| `Sources/vInput/Correct/CorrectionGate.swift` | 拒绝单字替换 |
| `Sources/vInput/Correct/CorrectionPrompt.swift` | 示例不再诱导「输出：」前缀 |
| `Sources/vInput/App/AppModel.swift` | 会话结束后补挂待应用的偏好 |
| `Tests/vInputTests/CorrectionE2ETests.swift` | 补一条能证伪的开/关对照断言 |

---

## Task 1: 推理改用可取消的流式 API（QA 编号 B1）

**Files:**
- Modify: `Sources/vInput/Correct/MLXCorrector.swift`
- Modify: `Sources/vInput/Correct/CorrectionPipeline.swift`（仅订正注释）
- Test: `Tests/vInputTests/CorrectionPipelineTests.swift`（追加）

### 问题

`CorrectionPipeline.withTimeout` 依赖「传进来的工作响应取消」，而 `ChatSession.respond`
走的同步 `generate` 循环一处取消检查都没有。超时能抛错，但 `withThrowingTaskGroup`
在重抛之前要等所有子任务收尾——于是 `correct()` 实际要等推理自然跑完。

**后果**：推理 5–10 秒（换更大的模型更久）期间 HUD 停在「正在校正」，用户以为卡死
而切走应用 → 规则三校验失败 → 文本既不注入也不进剪贴板 → **用户说的话彻底消失**。

### 修法

三条措施，缺一不可：

1. 改用 `streamResponse`，让取消真正能中断消费循环
2. 消费循环里显式检查取消，一旦取消立刻停止累积
3. 把 `maxTokens` 从 256 压到 96——替换清单本就极短，256 是拍脑袋写的。
   生产方不受取消影响会一路跑完，且 `ModelContainer.perform` 串行会让它挡住
   下一次推理，因此让它**本身就短**比指望取消更可靠

- [ ] **Step 1: 写失败的测试**

在 `Tests/vInputTests/CorrectionPipelineTests.swift` 的 `CorrectionPipelineTests`
结构体内追加：

```swift
    /// 超时必须真的中断等待，而不是等工作自然结束。
    ///
    /// 这条测试存在的理由：`withTimeout` 用 TaskGroup 实现，而 TaskGroup 在
    /// 重抛错误前会等所有子任务收尾。若传进去的工作不响应取消，超时就形同
    /// 虚设——`correct` 会一直等到工作跑完。真机上这意味着用户说完话后
    /// 盯着「正在校正」干等十几秒，以为程序卡死。
    ///
    /// 假对象必须用**不响应取消**的忙等，不能用 `Task.sleep`——后者可取消，
    /// 测不出这个问题。
    @Test("工作不响应取消时，超时仍在预算内返回")
    func timeoutReturnsEvenIfWorkIgnoresCancellation() async {
        let pipeline = CorrectionPipeline(
            corrector: UncancellableCorrector(inferenceSeconds: 2.0),
            timeout: .milliseconds(200)
        )
        let start = ContinuousClock.now
        let result = await pipeline.correct("小米耀空气")
        let elapsed = ContinuousClock.now - start

        #expect(result == "小米耀空气")
        #expect(
            elapsed < .milliseconds(800),
            "超时应在预算内返回，实际耗时 \(elapsed)——说明等到了工作自然结束"
        )
    }
```

并在同文件末尾（`CorrectionPipelineTests` 结构体之外）加入替身：

```swift
/// 推理不响应取消的假校正器。
///
/// 用忙等而非 `Task.sleep`：`Task.sleep` 响应取消，而真实的 MLX 同步推理
/// 循环不响应。要测「超时是否真的能中断等待」，替身必须模仿后者。
private final class UncancellableCorrector: Corrector, @unchecked Sendable {
    private let inferenceSeconds: Double

    init(inferenceSeconds: Double) {
        self.inferenceSeconds = inferenceSeconds
    }

    func prepare() async throws {}

    func edits(for text: String) async throws -> [CorrectionEdit] {
        let deadline = Date().addingTimeInterval(inferenceSeconds)
        while Date() < deadline {
            // 刻意不检查 Task.isCancelled——模仿真实 MLX 同步推理循环
        }
        return [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `./scripts/test.sh`
Expected: 「工作不响应取消时，超时仍在预算内返回」失败，实际耗时约 2 秒

**这条失败证明了 QA 的诊断成立。** 若它意外通过，立刻停下报告——说明
`withTimeout` 的行为与我们理解的不同，后续修法的前提就不成立。

- [ ] **Step 3: 让超时不再等待不可取消的工作**

修改 `Sources/vInput/Correct/CorrectionPipeline.swift` 的 `withTimeout`。

**不能用 `withThrowingTaskGroup`，也不能用 `async let`** —— 两者都是结构化并发，
都会在作用域结束前等待全部子任务收尾。而本次修复的全部意义就在于**不等落后者**。
必须用非结构化的 `Task` 做竞速：

```swift
    /// 给一段异步工作加超时。超时后抛 `CorrectorError.timedOut`。
    ///
    /// **传进来的工作不必响应取消。** 这是本实现与结构化并发的关键区别：
    /// `withThrowingTaskGroup` 与 `async let` 都会在作用域结束前等待全部子任务，
    /// 因此只要工作不响应取消，超时就形同虚设。真实的 MLX 同步推理循环恰恰
    /// 不响应取消（`Evaluate.swift:597-646` 全程无取消检查，读过源码确认）。
    ///
    /// 改成两个非结构化 `Task` 竞速：谁先送达结果谁作数，落后者被取消且
    /// **不等它**。代价是超时后那次推理仍会在后台跑完（生产方不受我们的取消
    /// 影响），白烧一段 GPU；但注入路径上一秒都不多等，这是更重要的一端。
    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = ResultBox<T>()

        let work = Task {
            do { await box.deliver(.success(try await operation())) }
            catch { await box.deliver(.failure(error)) }
        }
        let timer = Task {
            try? await Task.sleep(for: duration)
            await box.deliver(.failure(CorrectorError.timedOut))
        }

        defer {
            work.cancel()
            timer.cancel()
        }

        return try await box.first().get()
    }
```

并在同文件加入这个只保留首个结果的小容器：

```swift
/// 只保留第一个送达的结果，之后的一律丢弃。
///
/// 存在的理由：超时与推理是两个非结构化任务的竞速，谁先到谁作数，
/// 而本函数**不等**落后者——这正是 TaskGroup 做不到的事。
private actor ResultBox<T: Sendable> {
    private var settled: Result<T, Error>?
    private var waiters: [CheckedContinuation<Result<T, Error>, Never>] = []

    func deliver(_ result: Result<T, Error>) {
        guard settled == nil else { return }
        settled = result
        for waiter in waiters { waiter.resume(returning: result) }
        waiters.removeAll()
    }

    func first() async -> Result<T, Error> {
        if let settled { return settled }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `./scripts/test.sh`
Expected: 新测试通过（耗时约 200 毫秒而非 2 秒），既有全部测试仍通过

- [ ] **Step 5: 推理改用流式 API**

修改 `Sources/vInput/Correct/MLXCorrector.swift` 的 `edits(for:)`：

把 `parameters.maxTokens = 256` 改为：

```swift
        // 替换清单本就极短——一句话里错三四个词已经很多了。
        // 256 是最初拍脑袋写的；压到 96 是因为生产方不受我们的取消影响
        // （`ChatSession.stream()` 内部是非结构化 Task，没有 onTermination），
        // 超时后它仍会跑完，而 `ModelContainer.perform` 串行会让它挡住下一次
        // 推理。让推理本身就短，比指望取消更可靠。
        parameters.maxTokens = 96
```

把

```swift
        let output: String
        do {
            output = try await session.respond(to: CorrectionPrompt.user(for: text))
        } catch {
            throw CorrectorError.engineFailed(error.localizedDescription)
        }
```

改为

```swift
        // 用流式而非 `respond(to:)`：后者走同步的 generate 循环，全程不检查
        // 取消（`Evaluate.swift:597-646`），我们的超时对它毫无作用。流式版本
        // 走的重载在 `Evaluate.swift:809` 有 `if Task.isCancelled { break }`，
        // 取消能让本循环立刻退出。
        //
        // 注意生产方仍会跑完：`ChatSession.stream()` 内部是非结构化 Task，
        // 取消消费方不会中断它。我们要的只是「注入路径上不干等」。
        var output = ""
        do {
            for try await chunk in session.streamResponse(to: CorrectionPrompt.user(for: text)) {
                try Task.checkCancellation()
                output += chunk
            }
        } catch is CancellationError {
            throw CorrectorError.timedOut
        } catch {
            throw CorrectorError.engineFailed(error.localizedDescription)
        }
```

- [ ] **Step 6: 订正一处与事实相反的注释**

`Sources/vInput/Correct/CorrectionPipeline.swift` 中有一条注释断言
「MLX 推理逐 token 检查 `Task.isCancelled`，符合要求」。**这与事实相反**——
那处检查属于 AsyncStream 重载，而当时用的是同步重载。请找到该注释并改为：

```swift
    /// **传进来的工作不必响应取消。** 本实现不等落后者，超时即返回。
    /// 但工作若不响应取消，它仍会在后台跑完——`MLXCorrector` 因此改用
    /// 流式推理并压低 maxTokens，把这段浪费限制在可接受范围内。
```

- [ ] **Step 7: 验证**

Run: `swift build && ./scripts/test.sh`
Expected: 编译通过，全部测试通过

- [ ] **Step 8: 提交**

```bash
git add Sources/vInput/Correct/MLXCorrector.swift \
        Sources/vInput/Correct/CorrectionPipeline.swift \
        Tests/vInputTests/CorrectionPipelineTests.swift
git commit -m "fix(correct): 超时不再等待不可取消的推理

QA 发现 3 秒超时对真实 MLX 完全不生效：ChatSession.respond 走同步
generate 循环，全程无取消检查，而 withThrowingTaskGroup 在重抛错误前
必须等所有子任务收尾——于是 correct 实际要等推理自然跑完。

后果不止是慢：推理 5-10 秒期间用户以为卡死而切走应用，规则三校验失败
后文本既不注入也不进剪贴板，说过的话彻底消失。

三条措施：改用带取消检查的流式 API；withTimeout 换成非结构化任务竞速，
不等落后者；maxTokens 256 压到 96——生产方不受取消影响且 ModelContainer
串行会挡住下次推理，让它本身就短比指望取消可靠。

测试替身特意用忙等而非 Task.sleep：后者可取消，测不出这个问题。"
```

---

## Task 2: 会话结束后补挂待应用的偏好（QA 编号 B2）

**Files:**
- Modify: `Sources/vInput/App/AppModel.swift`
- Test: `Tests/vInputTests/CorrectionPreferenceTests.swift`（追加）

### 问题

`DictationSession.attachCorrectionPipeline` 在非 idle 时直接 `return`，而 `AppModel`
没有任何「回到 idle 后补挂」的机制。用户在录音中或转写那几秒里点「开启校正」
（说完一句后点菜单极容易撞上），偏好写进了 UserDefaults、菜单立刻显示「校正：开」，
但会话上的 pipeline 仍是 nil——**本次启动内校正永远不生效**，而菜单一直在骗人。

日志里那句「下次录音起生效」是假的。换模型目录同理。

### 修法

`AppModel` 记住「有一次挂载没成功」，在会话状态回到 `.idle` 时补挂。

- [ ] **Step 1: 写失败的测试**

创建 `Tests/vInputTests/CorrectionPendingApplyTests.swift`：

```swift
import Foundation
import Testing

@testable import vInput

@MainActor
@Suite("校正偏好的延迟生效")
struct CorrectionPendingApplyTests {
    /// 会话进行中挂载会被 DictationSession 拒绝（它只在 idle 时接受），
    /// 因此必须有人记住这件事并在回到 idle 后补挂。
    /// 否则用户在录音中打开校正，本次启动内再也不会生效，而菜单显示「开」。
    @Test("非 idle 时挂载失败，回到 idle 后自动补挂")
    func reappliesWhenSessionReturnsToIdle() async throws {
        let source = FakeAudioSource()
        let transcriber = FakeTranscriber()
        transcriber.result = "小米耀空气"
        let sink = SpySink()
        var guardian = TargetAppGuard()
        guardian.frontmostBundleID = { "com.apple.Notes" }

        let session = DictationSession(
            audioSource: source,
            transcriber: transcriber,
            sink: sink,
            targetGuard: guardian
        )

        // 进入 listening，此时挂载应被拒绝
        try await session.start()
        session.attachCorrectionPipeline(
            CorrectionPipeline(corrector: AlwaysFixCorrector())
        )
        source.emit(Array(repeating: 0.1, count: 16_000))
        await session.finish()
        #expect(sink.received == ["小米耀空气"], "本次会话不该被校正")

        // 回到 idle 后补挂，下一次会话应当生效
        session.attachCorrectionPipeline(
            CorrectionPipeline(corrector: AlwaysFixCorrector())
        )
        try await session.start()
        source.emit(Array(repeating: 0.1, count: 16_000))
        await session.finish()
        #expect(sink.received == ["小米耀空气", "小米遥控器"], "补挂后应当生效")
    }
}

/// 固定把「耀空气」改成「遥控器」的假校正器。
private final class AlwaysFixCorrector: Corrector, @unchecked Sendable {
    func prepare() async throws {}
    func edits(for text: String) async throws -> [CorrectionEdit] {
        [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
    }
}
```

- [ ] **Step 2: 跑测试确认它通过**

Run: `./scripts/test.sh`
Expected: **通过**。这条测试验证的是 `DictationSession` 的既有契约
（非 idle 拒绝、idle 接受），它本来就成立。写它是为了把这个契约钉住，
因为下一步 `AppModel` 的补挂逻辑正是建立在它之上的。

- [ ] **Step 3: 在 AppModel 中记录并补挂**

在 `Sources/vInput/App/AppModel.swift` 中：

其一，属性区加入：

```swift
    /// 上一次挂载校正流水线被会话拒绝（当时不在 idle）。
    ///
    /// 用户在录音中或转写那几秒里改设置是很自然的动作，而
    /// `DictationSession` 只在 idle 时接受挂载。不记住这件事的话，
    /// 那次改动就永远丢失了——而菜单已经显示成新状态，等于在骗人。
    private var correctionApplyPending = false
```

其二，把 `applyCorrectionPreference()` 改为记录是否成功：

```swift
    private func applyCorrectionPreference() {
        guard let session else {
            correctionApplyPending = true
            return
        }
        guard session.state == .idle else {
            correctionApplyPending = true
            AppLogger.shared.log("校正设置将在本次会话结束后生效")
            return
        }
        session.attachCorrectionPipeline(makeCorrectionPipeline())
        correctionApplyPending = false
    }
```

其三，在 `session.onStateChange` 的 `.idle` 分支里补挂：

```swift
            case .idle:
                self.phase = .idle
                // 会话结束，把此前被拒绝的挂载补上。
                if self.correctionApplyPending { self.applyCorrectionPreference() }
```

**注意**：`onStateChange` 现有代码形如 `case .idle: self.phase = .idle`，
请按实际代码调整，保持 switch 穷举、不引入 `default`。

- [ ] **Step 4: 验证**

Run: `swift build && ./scripts/test.sh`
Expected: 编译通过，全部测试通过

- [ ] **Step 5: 提交**

```bash
git add Sources/vInput/App/AppModel.swift \
        Tests/vInputTests/CorrectionPendingApplyTests.swift
git commit -m "fix(app): 会话进行中改的校正设置不再永久丢失

DictationSession 只在 idle 时接受挂载，而 AppModel 此前没有补挂机制。
用户说完一句后点菜单开校正（极容易撞上转写那几秒），偏好写进去了、
菜单显示「开」，但会话上的 pipeline 仍是 nil——本次启动内校正永远
不生效，菜单一直在骗人。

改为记录挂载失败并在回到 idle 时补挂。"
```

---

## Task 3: 解析器容忍模型的装饰性输出（QA 编号 I1）

**Files:**
- Modify: `Sources/vInput/Correct/CorrectionEditParser.swift`
- Modify: `Sources/vInput/Correct/CorrectionPrompt.swift`
- Test: `Tests/vInputTests/CorrectionEditParserTests.swift`（追加）

### 问题

QA 实测：`- 耀空气→遥控器`、`1. 耀空气→遥控器`、`输出：耀空气→遥控器`、
`「耀空气」→「遥控器」`、`耀空气→遥控器。` 六种装饰形式**全部解析失败**，
产出的 `original` 变成 `- 耀空气` 之类，既过不了闸门也不在文本中，静默丢弃。

4B 模型输出带项目符号是常态。更糟的是提示词的示例恰好用「输出：」开头，
**等于在诱导模型回显这个前缀**。

QA 判定这是 M4 整体失效风险最高的单点。

### 修法

解析时剥离装饰，同时把提示词的示例改成不诱导前缀。

- [ ] **Step 1: 写失败的测试**

在 `Tests/vInputTests/CorrectionEditParserTests.swift` 的
`CorrectionEditParserTests` 结构体内追加：

```swift
    /// 4B 模型输出带项目符号是常态。装饰一出现就整条丢弃的话，
    /// 用户看到的是「开关校正没差别」，而日志里什么异常都没有。
    @Test("剥离行首的列表符号")
    func stripsListMarkers() {
        let expected = [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
        for line in ["- 耀空气→遥控器", "* 耀空气→遥控器", "• 耀空气→遥控器",
                     "1. 耀空气→遥控器", "2) 耀空气→遥控器"] {
            #expect(CorrectionEditParser.parse(line) == expected, "未能解析：\(line)")
        }
    }

    /// 提示词的示例以「输出：」开头，模型很容易照着回显。
    @Test("剥离行首的标签前缀")
    func stripsLabelPrefix() {
        let expected = [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
        for line in ["输出：耀空气→遥控器", "输出: 耀空气→遥控器"] {
            #expect(CorrectionEditParser.parse(line) == expected, "未能解析：\(line)")
        }
    }

    @Test("剥离包裹的引号与行尾句点")
    func stripsQuotesAndTrailingPunctuation() {
        let expected = [CorrectionEdit(original: "耀空气", replacement: "遥控器")]
        for line in ["「耀空气」→「遥控器」", "\"耀空气\"→\"遥控器\"",
                     "耀空气→遥控器。", "耀空气→遥控器."] {
            #expect(CorrectionEditParser.parse(line) == expected, "未能解析：\(line)")
        }
    }

    /// 剥离不得伤及正文：替换文本内部的标点必须原样保留。
    @Test("不剥离词内部的字符")
    func doesNotStripInteriorCharacters() {
        #expect(
            CorrectionEditParser.parse("三点一四→3.14")
                == [CorrectionEdit(original: "三点一四", replacement: "3.14")]
        )
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `./scripts/test.sh`
Expected: 前三条新测试失败（解析出带装饰的 `original`），第四条通过

- [ ] **Step 3: 实现剥离**

在 `Sources/vInput/Correct/CorrectionEditParser.swift` 的
`enum CorrectionEditParser` 内加入：

```swift
    /// 行首的列表符号与标签前缀。
    ///
    /// 4B 模型输出带项目符号是常态，而提示词里的示例又容易被回显。
    /// 与其要求模型格式精确，不如把这些装饰剥掉——宽容的代价是多认
    /// 几种写法，严格的代价是整次校正静默作废。
    private static let leadingDecorations = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*•·]|\d+[.)]|输出\s*[:：])\s*"#
    )

    /// 剥掉包裹用的引号与行尾句点。
    ///
    /// 只动两端，不动内部：「三点一四→3.14」里的小数点必须留着。
    private static func undecorate(_ token: String) -> String {
        var result = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: Set<Character> = ["「", "」", "『", "』", "\"", "\u{201C}", "\u{201D}", "'"]
        while let first = result.first, quotes.contains(first) { result.removeFirst() }
        while let last = result.last, quotes.contains(last) { result.removeLast() }
        while let last = result.last, last == "。" || last == "." || last == "；" || last == ";" {
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
```

并把 `parseLine(_:)` 改为先剥前缀、再对两侧调用 `undecorate`：

```swift
    private static func parseLine(_ rawLine: String) -> CorrectionEdit? {
        let line = leadingDecorations.stringByReplacingMatches(
            in: rawLine,
            range: NSRange(rawLine.startIndex..., in: rawLine),
            withTemplate: ""
        )

        guard let arrow = arrows.first(where: { line.contains($0) }) else { return nil }

        let parts = line.components(separatedBy: arrow)
        // 多于两段说明一行里有多个箭头，切分点无法确定。整行丢弃：
        // 猜错的代价是改错用户的话，不猜的代价只是少改一处。
        guard parts.count == 2 else { return nil }

        let original = undecorate(parts[0])
        let replacement = undecorate(parts[1])

        guard !original.isEmpty, !replacement.isEmpty, original != replacement else {
            return nil
        }
        return CorrectionEdit(original: original, replacement: replacement)
    }
```

- [ ] **Step 4: 提示词不再诱导前缀**

修改 `Sources/vInput/Correct/CorrectionPrompt.swift`：把示例中的
「输出：」改成不会被误当作输出内容的形式。

```swift
    static let instructions = """
        你是中文语音转写的校对助手。用户给你一段语音识别结果，其中可能有同音字错误。

        规则：
        1. 只输出替换清单，每行一条，格式为 原文→正确文本
        2. 只改同音的错字，绝不改写句子、语序、标点
        3. 英文单词、代码标识符、专有名词一律保持原样，不要翻译成中文
        4. 不要加编号、项目符号、引号或任何解释
        5. 没有发现错误时，只输出：\(noChangeMarker)

        示例一
        输入：小米耀空气很好用
        回答：
        耀空气→遥控器

        示例二
        输入：今天天气不错
        回答：
        \(noChangeMarker)
        """
```

注意规则 2 从「只改同音或近音的错字」改成「只改同音的错字」——闸门只放行
严格同音，提示词却允许近音，等于让模型把算力花在必然被拒的建议上（QA 编号 I5）。
两边说法统一。

对应地，`user(for:)` 也改成与示例一致：

```swift
    static func user(for text: String) -> String {
        "输入：\(text)\n回答："
    }
```

- [ ] **Step 5: 验证**

Run: `swift build && ./scripts/test.sh`
Expected: 编译通过，全部测试通过（含新增四条）

- [ ] **Step 6: 提交**

```bash
git add Sources/vInput/Correct/CorrectionEditParser.swift \
        Sources/vInput/Correct/CorrectionPrompt.swift \
        Tests/vInputTests/CorrectionEditParserTests.swift
git commit -m "fix(correct): 解析器容忍模型的装饰性输出

QA 实测：带项目符号、编号、「输出：」前缀、包裹引号、行尾句点的
六种形式全部解析失败，静默丢弃，用户看到的是「开关校正没差别」。
4B 模型输出带项目符号是常态，而提示词的示例恰好用「输出：」开头,
等于在诱导模型回显这个前缀。

剥离只动两端不动内部——「三点一四→3.14」里的小数点必须留着。

同时把提示词里的「同音或近音」改为「只改同音」：闸门只放行严格同音，
两边说法不一致等于让模型把算力花在必然被拒的建议上。"
```

---

## Task 4: 拒绝单字替换（QA 编号 I4）

**Files:**
- Modify: `Sources/vInput/Correct/CorrectionGate.swift`
- Test: `Tests/vInputTests/CorrectionGateTests.swift`（追加）

### 问题

QA 实测：清单 `[的→得]` 作用于「我的书写得很好，他的笔也不错」
→「**我得书写得很好，他得笔也不错**」。

的/得/地、在/再、他/她 正是中文校对模型最爱改的东西，必然同音、必然放行，
而「同一片段出现多次时全部替换」这条规则对它们是灾难。实现里没有任何长度下限。

### 修法

拒绝 `original` 为单个字符的替换。

**这是一个明确的取舍**：会漏掉真正的单字错误，但避免了改坏一整句里本来正确的字。
「改坏原本正确的内容，比漏改一个错字严重得多」——这是 M4 设计文档写明的原则。

单字替换缺少消歧所需的上下文：模型说「的→得」，我们无从知道句子里哪个「的」
该改。多字片段自带上下文，因此全局替换是安全的。

- [ ] **Step 1: 写失败的测试**

在 `Tests/vInputTests/CorrectionGateTests.swift` 的 `CorrectionGateTests`
结构体内追加：

```swift
    /// 单字替换缺少消歧所需的上下文：模型说「的→得」，我们无从知道
    /// 句子里哪个「的」该改，而全局替换会把本来正确的字一并改坏。
    /// 实测「我的书写得很好，他的笔也不错」会变成「我得书写得很好，他得笔也不错」。
    ///
    /// 取舍很明确：漏掉真正的单字错误，换取不改坏一整句。
    @Test("单字替换一律拦下")
    func rejectsSingleCharacterEdits() {
        for edit in [
            CorrectionEdit(original: "的", replacement: "得"),
            CorrectionEdit(original: "在", replacement: "再"),
            CorrectionEdit(original: "他", replacement: "她"),
        ] {
            #expect(!CorrectionGate.allows(edit), "\(edit.original)→\(edit.replacement) 应被拦下")
        }
    }

    @Test("两字及以上仍然放行")
    func allowsMultiCharacterEdits() {
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "耀空", replacement: "遥控")))
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "耀空气", replacement: "遥控器")))
    }

    @Test("单字替换不会污染整句")
    func singleCharEditLeavesTextIntact() {
        let result = CorrectionGate.apply(
            [CorrectionEdit(original: "的", replacement: "得")],
            to: "我的书写得很好，他的笔也不错"
        )
        #expect(result.text == "我的书写得很好，他的笔也不错")
        #expect(result.applied.isEmpty)
        #expect(result.rejected.count == 1)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `./scripts/test.sh`
Expected: 「单字替换一律拦下」与「单字替换不会污染整句」失败

- [ ] **Step 3: 实现**

修改 `Sources/vInput/Correct/CorrectionGate.swift` 的 `allows(_:)`：

```swift
    /// 短于此长度的原文片段不接受替换。
    ///
    /// 单字替换缺少消歧所需的上下文：模型说「的→得」，我们无从知道句子里
    /// 哪个「的」该改，而 `apply` 会替换全部出现处，把本来正确的字一并改坏
    /// （实测「我的书写得很好」→「我得书写得很好」）。多字片段自带上下文，
    /// 全局替换才是安全的。
    ///
    /// 取舍是明确的：漏掉真正的单字错误，换取不改坏一整句。设计文档的原则是
    /// 「改坏原本正确的内容，比漏改一个错字严重得多」。
    static let minimumOriginalLength = 2

    /// 替换前后读音必须一致，否则不是「改错字」而是「改写」。
    static func allows(_ edit: CorrectionEdit) -> Bool {
        guard edit.original.count >= minimumOriginalLength else { return false }
        return Pinyin.toneless(edit.original) == Pinyin.toneless(edit.replacement)
    }
```

- [ ] **Step 4: 验证**

Run: `./scripts/test.sh`
Expected: 全部测试通过

- [ ] **Step 5: 提交**

```bash
git add Sources/vInput/Correct/CorrectionGate.swift \
        Tests/vInputTests/CorrectionGateTests.swift
git commit -m "fix(correct): 拒绝单字替换

QA 实测：清单 [的→得] 作用于「我的书写得很好，他的笔也不错」会得到
「我得书写得很好，他得笔也不错」。的/得/地、在/再、他/她 正是中文校对
模型最爱改的，必然同音、必然放行，而全部出现处一起替换对它们是灾难。

单字缺少消歧所需的上下文，多字片段自带上下文。取舍明确：漏掉真正的
单字错误，换取不改坏一整句——改坏原本正确的内容比漏改一个错字严重得多。"
```

---

## Task 5: 端到端补一条能证伪的对照断言（QA 编号 I7）

**Files:**
- Modify: `Tests/vInputTests/CorrectionE2ETests.swift`

### 问题

现有三条端到端断言里，`不翻译英文术语`（断言输出仍含 `useEffect`）与
`正确的句子不被改动`（断言输出等于输入）在**管线原样返回**时同样成立。
三条里只有 `修正真机出现过的同音错误` 能证伪。

于是即便解析器全废、或超时让校正从不生效，端到端也是 2/3 绿——而这套断言
是唯一能验收「同一句话开关能看出差别」的东西。

- [ ] **Step 1: 加入对照断言**

在 `Tests/vInputTests/CorrectionE2ETests.swift` 的 `CorrectionE2ETests`
结构体内追加：

```swift
    /// 直接对照：同一句话，有校正器与无校正器两条路，结果必须不同。
    ///
    /// 这条是 M4 验收标准「同一句话开关校正能看出差别」的直接翻译。
    /// 其余几条在「校正压根没跑」时也会通过——例如「不翻译英文术语」
    /// 与「正确的句子不被改动」，管线原样返回时同样成立。只有这一条
    /// 能证伪「校正实际上从未生效」。
    @Test("开与关的结果必须不同")
    func correctionMakesADifference() async throws {
        let corrector = try #require(Self.corrector, "需设置 VINPUT_CORRECTION_MODEL 指向本地模型目录")
        try await corrector.prepare()

        let input = "小米耀空气很好用"

        let withCorrection = await CorrectionPipeline(
            corrector: corrector, timeout: .seconds(120)
        ).correct(input)

        // 无校正器时的行为基准：DictationSession 在 correctionPipeline 为 nil
        // 时直接注入转写原文，这里用原文本身代表那条路径。
        let withoutCorrection = input

        #expect(
            withCorrection != withoutCorrection,
            "开关校正结果相同，说明校正实际未生效。实际输出：\(withCorrection)"
        )
    }

    /// 至少有一条替换真的被闸门放行并应用了。
    ///
    /// 与上一条互补：上一条证明「文本变了」，这一条证明「是校正层改的」，
    /// 排除文本因其他原因发生变化的可能。
    @Test("确有替换被采纳")
    func atLeastOneEditApplied() async throws {
        let corrector = try #require(Self.corrector, "需设置 VINPUT_CORRECTION_MODEL 指向本地模型目录")
        try await corrector.prepare()

        let edits = try await corrector.edits(for: "小米耀空气很好用")
        #expect(!edits.isEmpty, "模型未给出任何替换建议")

        let outcome = CorrectionGate.apply(edits, to: "小米耀空气很好用")
        #expect(
            !outcome.applied.isEmpty,
            "全部建议都被闸门拦下。建议=\(edits) 拦下=\(outcome.rejected)"
        )
    }
```

- [ ] **Step 2: 验证门控仍然生效**

Run: `./scripts/test.sh`
Expected: 「校正端到端」套件被跳过，其余全部通过。总数从 360 增至 362
（Swift Testing 把 skipped 的用例计入总数）

- [ ] **Step 3: 提交**

```bash
git add Tests/vInputTests/CorrectionE2ETests.swift
git commit -m "test(correct): 端到端补一条能证伪的对照断言

原有三条里有两条在「校正压根没跑」时也会通过——「不翻译英文术语」与
「正确的句子不被改动」，管线原样返回时同样成立。于是即便解析器全废
或超时让校正从不生效，端到端仍是 2/3 绿，而这套断言是唯一能验收
「同一句话开关能看出差别」的东西。

新增两条：开与关的结果必须不同（证明文本变了），确有替换被采纳
（证明是校正层改的，排除其他原因）。"
```

---

## 验收

```bash
./scripts/test.sh          # 全部通过
swift build
./scripts/build-app.sh
```

模型下载完成后，用真实模型跑端到端：

```bash
VINPUT_E2E=1 \
VINPUT_CORRECTION_MODEL="$HOME/Library/Application Support/vInput/models/qwen3-4b-instruct-2507-4bit" \
./scripts/test.sh
```

**「开与关的结果必须不同」这条通过，才算 M4 的验收标准达成。** 其余几条即便
全绿也不足以证明——这正是本次修订加它的原因。

---

## 本次不修，记入待办

QA 报告中以下各项经评估不阻塞合并：

1. **闸门可被四类改写绕过**（QA I2）：整句罗马化、全角/半角句号、CJK 旁空格、
   ASCII 大小写。罗马化需要模型主动吐出整句拼音，现实概率低；其余三类属于
   「改了但语义无害」。**但设计文档中「结构上不可能重写句子」的说法应订正为
   「概率上不常见」**——那句话现在是不准确的。
2. **`apply` 对着已改写的中间结果匹配**（QA I3）：与设计文档「必须在转写中
   原样存在」不符。同音传递性使危害有界（结果仍与原文同音），但行为与文档不一致。
3. **每次开关/换目录都新建 `MLXCorrector`**（QA I6）：旧实例的加载无人取消，
   两份模型可能同时驻留。设计文档正鼓励用户换更大的模型试，这条路径是被主动
   推荐的，应当在 M5 或 M6 处理。
4. **没有「本次未校正」的可见反馈**（QA O1）：最常见的情形恰是「模型还在后台
   加载 → 静默注入原文」，用户无从判断是没加载完、没解析出替换、还是被闸门拦了。
   设计文档规则二的表格本就要求 HUD 标注，M4 未实现。
5. **未指定模型目录时会静默尝试从 Hugging Face 下载**（QA O2）：无进度、无报错、
   无 UI，且本机网络下这类拉取会失败（见 `docs/dev-dependencies.md`）。
6. **`parseLine` 用 `.whitespaces` 而非 `.whitespacesAndNewlines`**（QA O4）：
   `\r` 会留在替换文本里。当前碰巧无害（闸门会因拼音不等而拦下），但那是巧合。
   —— 本计划 Task 3 的 `undecorate` 已改用 `.whitespacesAndNewlines`，此项顺带解决。
