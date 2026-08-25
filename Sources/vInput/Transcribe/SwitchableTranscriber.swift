import Foundation

/// 可在运行时更换底层模型的转写器。
///
/// 存在的理由：`DictationSession` 持有的 `transcriber` 是 `let`，
/// 而换模型不应该要求重建整个会话（那会丢掉转写失败时保留的音频，
/// 违反规则二）。这一层把「换模型」收敛成一个可测的独立关注点。
///
/// 用 actor 而非 class：切换与转写因此天然串行——切换请求会自动排在
/// 进行中的转写之后，不会把正在 await 的推理换掉。
actor SwitchableTranscriber: Transcriber {
    /// 构造底层转写器。可注入，便于测试时替换掉真实的 WhisperKit。
    private let makeTranscriber: @Sendable (ModelDescriptor) -> Transcriber

    private var current: Transcriber
    private(set) var descriptor: ModelDescriptor

    init(
        initial: ModelDescriptor,
        makeTranscriber: @escaping @Sendable (ModelDescriptor) -> Transcriber
    ) {
        self.descriptor = initial
        self.makeTranscriber = makeTranscriber
        self.current = makeTranscriber(initial)
    }

    /// 换到另一个模型并立即加载。
    ///
    /// 加载可能耗时数十秒（Core ML 首次编译到神经引擎），调用方
    /// 应当在此期间向用户显示进度。加载失败时保持原模型不变。
    func switchTo(_ next: ModelDescriptor) async throws {
        guard next != descriptor else { return }

        let candidate = makeTranscriber(next)
        // 先把新模型加载起来，成功了才替换。
        // 顺序反过来的话，加载失败会让转写器处于不可用状态。
        try await candidate.prepare()

        current = candidate
        descriptor = next
    }

    /// 用同一个模型描述符重建底层转写器。
    ///
    /// 存在的理由：输入语言是 `makeTranscriber` 的构造期参数，换语言不换
    /// 模型时 `switchTo` 的 `next != descriptor` guard 会直接返回、什么都
    /// 不发生。失败语义与 `switchTo` 相同：先建新的、`prepare()` 成功才
    /// 替换，失败时旧转写器原样可用。
    ///
    /// 重入语义：`prepare()` 挂起期间（模型加载可达数十秒）并发的
    /// `switchTo` 可能已提交新模型——那时放弃提交、丢掉 candidate，
    /// 否则 `current` 会被换回旧 descriptor 构造的实例，与 `descriptor`
    /// 两字段脱钩（UI 显示新模型、实际转写旧模型）。
    ///
    /// 生产调用方在 `AppModel`（Task 10 接线），此刻尚无。
    func rebuild() async throws {
        let snapshot = descriptor
        let candidate = makeTranscriber(snapshot)
        try await candidate.prepare()
        // prepare 挂起期间可能有并发 switchTo 提交了新模型——那时丢弃
        // candidate 是对的：switchTo 走的 makeTranscriber 同样读到最新
        // 输入语言，不丢功能。
        guard snapshot == descriptor else { return }
        current = candidate
    }

    func prepare() async throws {
        try await current.prepare()
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await current.transcribe(samples)
    }

    /// 取当前后端的预览能力。换模型后需重新调用。
    func currentPreviewCapable() -> (any PreviewCapable)? {
        current as? PreviewCapable
    }
}
