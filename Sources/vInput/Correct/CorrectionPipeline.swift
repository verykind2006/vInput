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

    /// 返回校正后的文本。任何环节失败都返回入参原文，本函数不抛错。
    func correct(_ text: String) async -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }

        let edits: [CorrectionEdit]
        do {
            edits = try await withTimeout(timeout) {
                try await corrector.prepare()
                return try await corrector.edits(for: text)
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

    /// 给一段异步工作加超时。超时后抛 `CorrectorError.timedOut`。
    ///
    /// 用 `TaskGroup` 而非 `Task.detached` + 定时器：组内任一子任务返回后
    /// `cancelAll()` 会取消另一个，推理任务不会在后台继续烧 CPU。
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
