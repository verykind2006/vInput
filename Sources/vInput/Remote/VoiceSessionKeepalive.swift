import Foundation

/// 在长时间录音期间周期性续期 ATVV 会话。
///
/// RC003 按住语音键约 60 秒后固件会主动结束会话。ATVV 的 `MIC_EXTEND`
/// （`0x0E`）用于续期，但需要有人周期性发送。
///
/// **该行为未经上游真机验收**——上游文档记录「RC003 是否能因此录过 60 秒
/// 仍需真机验收」，状态挂在「等待人工验收」。本项目有硬件，M3 验收时首次确认。
///
/// 把判断与真实计时器分开，是为了不用等真实时间就能测——等 60 秒的测试
/// 没人会跑第二次。
@MainActor
final class VoiceSessionKeepalive {
    /// 续期间隔。10 秒在 60 秒的固件切断前留出 6 次机会，
    /// 单次写入失败不至于让整个保活失效。
    static let interval: TimeInterval = 10
    /// 单次会话的上限。沿用上游的试验安全值，**不是固件限制**。
    static let maxDuration: TimeInterval = 180

    /// 该发送 `MIC_EXTEND` 了。
    var onExtend: (() -> Void)?
    /// 达到上限，该主动结束会话了。
    var onTimeout: (() -> Void)?

    private var startedAt: Date?
    private var extendCount = 0
    private var timer: Timer?

    func start(now: Date = Date()) {
        startedAt = now
        extendCount = 0

        timer?.invalidate()
        // 每秒查一次即可——判断基于绝对时刻，不依赖 tick 的精确性。
        // 主线程繁忙导致漏拍时，下一次 tick 会把跳过的间隔补齐。
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick(now: Date())
            }
        }
    }

    func stop() {
        startedAt = nil
        timer?.invalidate()
        timer = nil
    }

    /// 生产环境由计时器每秒调用；测试直接调用并传入构造的时刻。
    func tick(now: Date) {
        guard let startedAt else { return }
        let elapsed = now.timeIntervalSince(startedAt)

        if elapsed >= Self.maxDuration {
            stop()
            onTimeout?()
            return
        }

        let due = Int(elapsed / Self.interval)
        while extendCount < due {
            extendCount += 1
            onExtend?()
        }
    }
}
