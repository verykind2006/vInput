import Foundation

/// 把遥控器的事件翻译成会话动作。
///
/// 这是本里程碑的核心需求所在——用户原话：
///
/// > 按下语音键，相当于按下了 ⌥D；松开语音键，相当于又按了一次 ⌥D。
///
/// 因此这里的映射极简单：`handleVoiceStart` → 开始会话，
/// `handleVoiceStop` → 结束会话，返回键 → 取消。下游一个字都不变。
///
/// 只接收语义化事件而不直接持有蓝牙桥，是为了让这段映射可以单元测试——
/// 真实的桥需要外设。由 `AppModel` 负责把 delegate 回调翻译成这些调用。
@MainActor
final class RemoteCoordinator {
    /// 语音键按下，请求开始会话。
    var onStartSession: (() -> Void)?
    /// 语音键松开，请求结束会话并转写。
    var onFinishSession: (() -> Void)?
    /// 返回键按下，请求取消会话。
    var onCancelSession: (() -> Void)?

    let source: BluetoothRemoteSource

    /// 本次语音是否仍在进行。
    ///
    /// 用于过滤三类事件：重复的开始、未开始时的停止、以及取消或断连之后
    /// 才到达的停止——用户按了取消再松开语音键，不该再触发一次结束。
    private var isVoiceActive = false

    init(source: BluetoothRemoteSource) {
        self.source = source
    }

    func handleVoiceStart() {
        guard !isVoiceActive else { return }
        isVoiceActive = true
        onStartSession?()
    }

    func handleVoiceStop() {
        guard isVoiceActive else { return }
        isVoiceActive = false
        onFinishSession?()
    }

    func handleCancelPressed() {
        guard isVoiceActive else { return }
        isVoiceActive = false
        onCancelSession?()
    }

    func handleDecoded(_ samples: [Int16]) {
        source.deliver(samples)
    }

    func handleDisconnected() {
        isVoiceActive = false
        source.reportDisconnected()
    }
}
