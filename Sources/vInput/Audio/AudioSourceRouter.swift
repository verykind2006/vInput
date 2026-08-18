import Foundation

/// 在多个音频源之间路由。
///
/// 自身实现 `AudioSource`，因此 `DictationSession` 完全不知道音频来自
/// 内置麦、蓝牙遥控器还是蓝牙鼠标——会话层一行不改。
///
/// **为什么不让 `DictationSession` 支持换源：** 音频源在会话构造时就接管了
/// `onFrame`，中途替换要处理正在录音、缓冲区归属等边界。M2 给
/// `previewEngine` 加运行时挂载已经付过一次这样的代价。
///
/// 路由器还让音频分叉点收敛到一处：M2 曾在 `AppModel` 里手工包一层
/// `onFrame` 把音频同时喂给预览处理器，两个源之后那段要写两遍。
@MainActor
final class AudioSourceRouter: AudioSource {
    enum Kind: Hashable {
        case microphone
        /// 小米遥控器 RC003（ATVV 协议，ADPCM）。
        case bluetooth
        /// 蓝牙鼠标 iMouse（厂商 GATT，SBC）。
        ///
        /// **第三个源是 M7 加的，路由器本身一行没改**——M3 把「音频从哪来」
        /// 的全部差异吸收在 `AudioSource` 之后，这里只多一个 case。
        case mouse
    }

    var onFrame: (([Float]) -> Void)?
    var onStop: ((Error?) -> Void)?

    private(set) var active: Kind = .microphone
    private var isRunning = false
    private let sources: [Kind: AudioSource]

    init(sources: [Kind: AudioSource]) {
        self.sources = sources

        // 每个源的回调都接上，但只有当前活跃的那个会被转发出去。
        // 这样切换时不必重新绑定，也不会漏掉刚 stop 的源的收尾事件。
        for (kind, source) in sources {
            source.onFrame = { [weak self] samples in
                guard let self, self.active == kind else { return }
                self.onFrame?(samples)
            }
            source.onStop = { [weak self] error in
                guard let self, self.active == kind else { return }
                self.onStop?(error)
            }
        }
    }

    /// 选择本次会话使用的音频源。
    ///
    /// 运行中调用会被忽略——切换正在采集的源会让缓冲区里混进两个源的音频。
    func select(_ kind: Kind) {
        guard !isRunning else { return }
        guard sources[kind] != nil else { return }
        active = kind
    }

    func start() throws {
        guard !isRunning else { return }
        guard let source = sources[active] else {
            throw AudioSourceError.engineFailedToStart("音频源 \(active) 未接入")
        }
        try source.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        sources[active]?.stop()
    }
}
