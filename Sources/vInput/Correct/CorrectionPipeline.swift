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
    /// 用 `TaskGroup` 而非 `Task.detached` + 定时器：组内任一子任务返回后
    /// `cancelAll()` 会取消另一个，推理任务不会在后台继续烧 CPU。
    ///
    /// **传进来的工作必须是响应取消的。** 任务组在重新抛出超时错误前会
    /// 等所有子任务收尾，塞一段不理会取消的工作进来（例如模型加载），
    /// 超时就形同虚设，`correct` 会一直等到它跑完。MLX 的推理循环逐 token
    /// 检查 `Task.isCancelled`，符合要求；加载不符合，所以留在窗口之外。
    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw CorrectorError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CorrectorError.timedOut
            }
            return first
        }
    }
}
