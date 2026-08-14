import Foundation

/// 「只加载一次」的闸门：把一次性的重加载与每次调用的时间预算隔开。
///
/// 单独抽出来，是因为下面两条性质都不是 `guard value == nil` 能拿到的，
/// 而它们正是 M4 那个「校正永不生效」缺陷的根因：
///
/// 1. **加载不随调用方的取消而中断。** 加载放在非结构化的 `Task.detached`
///    里，调用方被超时取消（或它所在的任务组 `cancelAll`）时，加载照常
///    跑完。否则 2 GB 模型每次加载到一半被掐断，就永远等不到就绪——
///    实测：`Task.sleep` 这类可取消的加载在旧实现下加载次数一直涨、
///    完成次数恒为 0。
/// 2. **并发调用只触发一次加载。** 两次调用之间隔着 `await`，第二个会在
///    第一个挂起时进来，仅凭「值还是 nil」判重会漏，必须记住在途任务。
///
/// 失败不缓存：加载出错后清掉在途任务，下次调用可重试（例如用户把指错的
/// 模型目录改对了，不必重启）。
actor OneShotLoader<Value: Sendable> {
    private let load: @Sendable () async throws -> Value
    private var loaded: Value?
    private var inFlight: Task<Value, Error>?

    init(load: @escaping @Sendable () async throws -> Value) {
        self.load = load
    }

    /// 已加载好的值；仍在加载或从未加载过时为 nil。**本属性绝不等待。**
    var ready: Value? { loaded }

    /// 取值，必要时发起加载并等到它完成。
    func value() async throws -> Value {
        if let loaded { return loaded }

        let task: Task<Value, Error>
        if let inFlight {
            task = inFlight
        } else {
            task = Task.detached(priority: .utility) { [load] in try await load() }
            inFlight = task
        }

        do {
            let value = try await task.value
            loaded = value
            inFlight = nil
            return value
        } catch {
            inFlight = nil
            throw error
        }
    }
}
