import Foundation

/// 串起「求建议 → 解析 → 过闸 → 应用」，并保证任何失败都退回原文。
///
/// **校正是锦上添花，绝不允许它的失败影响主路径。** 与预览引擎在 M2
/// 的处理方式一致：出错只记日志，不上报为会话错误，因为用户已经说出的
/// 内容必须原样落到光标处（规则二·永不丢字）。
struct CorrectionPipeline: Sendable {
    private let corrector: Corrector
    private let timeout: Duration

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

        let edits: [CorrectionEdit]
        do {
            // **只有推理进这个超时窗口，加载不进。** 3 秒对一次推理是合理
            // 上限，对加载 2 GB 模型毫无道理——两者曾共用一个预算，结果是
            // 加载每次都被超时掐断（或反过来把注入拖住几十秒），校正从不生效。
            edits = try await withTimeout(timeout) {
                try await corrector.edits(for: text)
            }
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
