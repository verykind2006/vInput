import Foundation

/// 串起「求建议 → 解析 → 过闸 → 应用」，并保证任何失败都退回原文。
///
/// **校正是锦上添花，绝不允许它的失败影响主路径。** 与预览引擎在 M2
/// 的处理方式一致：出错只记日志，不上报为会话错误，因为用户已经说出的
/// 内容必须原样落到光标处（规则二·永不丢字）。
struct CorrectionPipeline: Sendable {
    private let corrector: Corrector
    private let timeout: Duration
    /// 「上一次推理还没落地」的闸门，见 `InFlightGate`。
    ///
    /// **本类型是 struct，但闸门必须跨拷贝共享**，所以它是 actor（引用语义）。
    /// 流水线会被拷来拷去（挂到 `DictationSession` 上、按值传参），若把
    /// `busy` 直接做成 struct 的存储属性，每份拷贝各记各的，闸门形同虚设。
    ///
    /// 反过来，`AppModel.makeCorrectionPipeline()` 每次都 new 一个新流水线，
    /// 于是也换一个新闸门——这是对的：那时 `MLXCorrector` 与它的
    /// `ModelContainer` 也是新的，旧推理占的是旧容器的串行队列，不该拦住
    /// 新容器上的第一次校正。而 `applyCorrectionPreference()` 只在启动、
    /// 开关校正、换校正模型时调用（读过 `AppModel`，不是每次会话），
    /// 一次会话内乃至连续多次会话之间，流水线实例都是稳定的。
    private let inFlight = InFlightGate()

    init(corrector: Corrector, timeout: Duration = .seconds(3)) {
        self.corrector = corrector
        self.timeout = timeout
    }

    /// 后台预热模型。开启校正时调用，绝不在注入路径上等它。
    ///
    /// 与 M2 对 Whisper 的做法一致（见 `AppModel.warmUpAndAttachPreview`）：
    /// 一次性的加载成本挪到用户开口之前付掉。
    func warmUp() async {
        do {
            try await corrector.prepare()
            AppLogger.shared.log("校正模型预热完成")
        } catch {
            AppLogger.shared.log("校正模型预热失败：\(error)")
        }
    }

    /// 返回校正后的文本。任何环节失败都返回入参原文，本函数不抛错。
    func correct(_ text: String) async -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }

        // **模型未就绪就立刻退回原文，一秒都不等。** 加载 2 GB 模型要几十秒，
        // 让用户对着光标干等是不可接受的（规则二·永不丢字）。
        //
        // 顺手在后台补一次加载：预热没跑到或跑失败时，下一句就能用上校正。
        // 重复触发不会重复加载，`OneShotLoader` 会合并到同一次。
        guard await corrector.isReady else {
            AppLogger.shared.log("校正跳过：模型尚未就绪，已在后台加载")
            warmUpInBackground()
            return text
        }

        // **上一次推理还没落地，这次就直接不校正。**
        //
        // 超时只是「不等它」，那次推理仍会在后台跑完，而 `ModelContainer.perform`
        // 是串行的。若照旧发起，新推理只能排在废任务后面——每超时一次队列就长
        // 一节，GPU 持续满载，校正从此永不可能成功（实测：超时 300ms、单次推理
        // 1s、连说 5 句，5 次全超时，5 次推理全白烧）。默认 4B 模型单次 0.7 秒
        // 摸不到 3 秒预算，但菜单里明摆着请用户换 7B/8B，换了就必然踩上。
        //
        // 跳过的代价是零：反正超时也是返回原文，跳过还省下一次白烧的推理。
        // 下面的 `guard` 与紧随其后的推理任务之间没有挂起点，闸门不会漏。
        guard await inFlight.tryBegin() else {
            AppLogger.shared.log("校正跳过：上一次推理尚未落地")
            return text
        }

        let edits: [CorrectionEdit]
        do {
            // **只有推理进这个超时窗口，加载不进。** 3 秒对一次推理是合理
            // 上限，对加载 2 GB 模型毫无道理——两者曾共用一个预算，结果是
            // 加载每次都被超时掐断（或反过来把注入拖住几十秒），校正从不生效。
            edits = try await editsWithTimeout(for: text)
        } catch {
            AppLogger.shared.log("校正跳过：\(error)")
            return text
        }

        guard !edits.isEmpty else { return text }

        let outcome = CorrectionGate.apply(edits, to: text)
        logOutcome(outcome)
        return outcome.text
    }

    /// 记录采纳与拦下的替换，供判断闸门松紧。
    ///
    /// 只记替换对，不记全文——日志默认不含转写内容（见设计文档「隐私」）。
    private func logOutcome(_ outcome: CorrectionGate.Outcome) {
        guard !outcome.applied.isEmpty || !outcome.rejected.isEmpty else { return }
        let describe: ([CorrectionEdit]) -> String = { edits in
            edits.map { "\($0.original)→\($0.replacement)" }.joined(separator: " ")
        }
        AppLogger.shared.log(
            "校正 采纳=[\(describe(outcome.applied))] 拦下=[\(describe(outcome.rejected))]"
        )
    }

    /// 在后台发起一次预热，不等结果。
    private func warmUpInBackground() {
        // detached：这次 `correct` 马上就要返回了，加载必须活得比它久，
        // 不能作为它的结构化子任务被一并取消。
        Task.detached(priority: .utility) { await self.warmUp() }
    }

    /// 发起一次推理并给它加超时。超时后抛 `CorrectorError.timedOut`。
    ///
    /// **推理不必响应取消。** 这是本实现与结构化并发的关键区别：
    /// `withThrowingTaskGroup` 与 `async let` 都会在作用域结束前等待全部子任务，
    /// 因此只要工作不响应取消，超时就形同虚设。真实的 MLX 同步推理循环恰恰
    /// 不响应取消（`Evaluate.swift:597-646` 全程无取消检查，读过源码确认）。
    ///
    /// 改成两个非结构化 `Task` 竞速：谁先送达结果谁作数，落后者**不等**。
    /// 代价是超时后那次推理仍会在后台跑完，白烧一段 GPU；但注入路径上一秒都
    /// 不多等，这是更重要的一端。
    ///
    /// **超时后刻意不取消推理任务。** 取消它一分钱都省不下：真正烧 GPU 的
    /// 生产方是 `ChatSession.stream()` 内部的非结构化 Task，不受我们取消的
    /// 影响，照样把 `ModelContainer` 的串行队列占到跑完。取消只会让消费侧
    /// 提前抛错返回——那反而毁掉了我们唯一能观测到「推理真的落地了」的信号，
    /// 闸门会在 GPU 还忙着的时候提前开，堆积照旧。让它自然读完流，
    /// 任务结束的那一刻就是队列空出来的那一刻。
    private func editsWithTimeout(for text: String) async throws -> [CorrectionEdit] {
        let box = ResultBox<[CorrectionEdit]>()
        let corrector = self.corrector
        let gate = self.inFlight

        Task {
            let result: Result<[CorrectionEdit], Error>
            do { result = .success(try await corrector.edits(for: text)) }
            catch { result = .failure(error) }
            // 开闸必须在推理真正返回之后，且无论成败都要开——
            // 否则一次引擎报错就把校正永久关死。
            await gate.finish()
            await box.deliver(result)
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            await box.deliver(.failure(CorrectorError.timedOut))
        }

        // 计时器要收掉：推理先到时它还挂在那儿睡着，白占一个任务。
        defer { timer.cancel() }

        return try await box.first().get()
    }
}

/// 「同一时刻只放一次推理进去」的闸门。
///
/// 与 `CorrectionGate`（判断单条替换安不安全）没有关系，这里挡的是并发。
///
/// 为什么闸门归流水线管、而不是塞进 `MLXCorrector`：校正器**观测不到**自己
/// 那次被放弃的推理什么时候落地。超时后消费侧一旦退出，actor 上的标志就被
/// 清掉了，而真正占着串行队列的生产方还在跑。流水线持有推理任务本身，
/// 任务结束才是队列真正空出来的时刻，只有它拿得到这个信号。
private actor InFlightGate {
    private var busy = false

    /// 无推理在途时占住闸门并返回 true；已有在途则返回 false，调用方应跳过本次。
    ///
    /// 判断与置位之间没有 `await`，因此不存在两个调用同时通过的空隙——
    /// 这正是 `guard container == nil` 那类写法栽过的坑（见 `OneShotLoader`）。
    func tryBegin() -> Bool {
        guard !busy else { return false }
        busy = true
        return true
    }

    /// 推理落地，放行下一次。
    func finish() { busy = false }
}

/// 只保留第一个送达的结果，之后的一律丢弃。
///
/// 存在的理由：超时与推理是两个非结构化任务的竞速，谁先到谁作数，
/// 而调用方**不等**落后者——这正是 TaskGroup 做不到的事。
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
