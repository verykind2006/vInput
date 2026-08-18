import Foundation

/// 把蓝牙鼠标的事件翻译成会话动作。
///
/// 与 `RemoteCoordinator` 同一个位置、同一个理由：只接收语义化事件而不直接
/// 持有蓝牙桥，这段映射才能单元测试——真实的桥需要外设，而**真机验证要靠
/// 用户按鼠标上的键**，实现方跑不了。由 `AppModel` 把桥的 delegate 回调
/// 翻译成这些调用。
///
/// 与遥控器那边的三处不同，都是设备决定的：
///
/// 1. **鼠标没有取消键。** 抓包里只有语音键与另外两个功能键，没有一个
///    对应「取消」。取消仍走 Esc（`CancelHotkeyController`）。
/// 2. **音频是 SBC 码流不是 PCM**，所以 `handleAudio` 收 `Data` 而不是
///    `[Int16]`，解码在 `MouseAudioSource`。
/// 3. **会话可能被时长上限主动结束**（`0x31` 没有配对的结束码，见
///    `MouseVoiceSession`）。这条路径与「语音键松开」走同一个出口，
///    因为对上层来说都是「录完了，去转写」。
@MainActor
final class MouseCoordinator {
    /// 语音键按下，请求开始会话。
    var onStartSession: (() -> Void)?
    /// 语音键松开（或撞到时长上限），请求结束会话并转写。
    var onFinishSession: (() -> Void)?

    let source: MouseAudioSource

    /// 本次语音是否仍在进行。
    ///
    /// 用于过滤三类事件：重复的开始、未开始时的停止、以及断连之后才到达的
    /// 停止。理由与 `RemoteCoordinator.isVoiceActive` 相同。
    private var isVoiceActive = false

    init(source: MouseAudioSource) {
        self.source = source
    }

    var isActive: Bool { isVoiceActive }

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

    /// 这次开始被上层拒了（模型加载中 / 基准集录制中 / 另一个源正在录）。
    ///
    /// **必须清状态，但一个回调都不能发。** 不清的话协调器会一直认为
    /// 「录着」：随后真正的结束码被它自己的 guard 吃掉，下一次按键又因
    /// 「重复的开始」被忽略——语音键从此失灵。
    ///
    /// 而走 `handleVoiceStop()` 去清同样不行：那会触发 `onFinishSession`，
    /// 进而 `endSuppressing()` ——**此刻按键抑制很可能正属于另一台设备的
    /// 会话**（三个音频源之后这是真实场景：鼠标正录着，用户按了遥控器的
    /// 语音键被拒，遥控器的收尾会把鼠标那次的抑制关掉）。
    func abandonSession() {
        isVoiceActive = false
    }

    func handleAudio(_ packet: Data) {
        source.deliver(packet)
    }

    func handleDisconnected() {
        isVoiceActive = false
        source.reportDisconnected()
    }
}
