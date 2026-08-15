import Foundation
@testable import vInput

/// 加载耗时可控的假校正器，用来复现「模型还没加载完」这段窗口期。
///
/// 真实模型有 2 GB，测试里绝不加载。
actor FakeSlowCorrector: Corrector {
    /// 加载怎么实现。两种都要能模拟，因为它们暴露的是同一个缺陷的两副面孔。
    enum LoadStyle: Sendable {
        /// 朴素实现：在调用方的任务里直接加载，自身不做任何取消保护——
        /// 修复前的 `MLXCorrector` 就是这样。用它才能验证「加载不被超时
        /// 取消」这条性质确实来自流水线，而不是校正器自己兜住了。
        /// 加载响应取消（对应从 Hugging Face 下载时的 `checkCancellation`）。
        case naive
        /// 与修复后的 `MLXCorrector` 同构：加载交给 `OneShotLoader`，
        /// 且不响应取消（对应 MLX 从本地目录读权重那种一路同步的加载）。
        case guarded
    }

    let counter: LoadCounter

    private let loadDuration: Duration
    private let style: LoadStyle
    private let loader: OneShotLoader<Bool>
    private let editsWhenReady: [CorrectionEdit]
    private let inferenceHangs: Bool
    /// 朴素实现的就绪标志。`guarded` 模式下由 `loader` 记录。
    private var naiveReady = false

    /// - Parameters:
    ///   - loadDuration: 一次加载的耗时。
    ///   - style: 见 `LoadStyle`。
    ///   - edits: 就绪后推理返回的替换清单。
    ///   - inferenceHangs: 推理是否卡住，用于验证推理的超时保护还在。
    init(
        loadDuration: Duration,
        style: LoadStyle = .guarded,
        edits: [CorrectionEdit] = [],
        inferenceHangs: Bool = false
    ) {
        let counter = LoadCounter()
        self.counter = counter
        self.loadDuration = loadDuration
        self.style = style
        self.editsWhenReady = edits
        self.inferenceHangs = inferenceHangs
        loader = OneShotLoader {
            await counter.noteStart()
            await uninterruptibleSleep(loadDuration)
            await counter.noteFinish()
            return true
        }
    }

    var isReady: Bool {
        get async {
            switch style {
            case .naive: naiveReady
            case .guarded: await loader.ready != nil
            }
        }
    }

    func prepare() async throws {
        switch style {
        case .naive:
            guard !naiveReady else { return }
            await counter.noteStart()
            try await Task.sleep(for: loadDuration)
            await counter.noteFinish()
            naiveReady = true
        case .guarded:
            _ = try await loader.value()
        }
    }

    func edits(for text: String) async throws -> [CorrectionEdit] {
        guard await isReady else { throw CorrectorError.modelNotReady }
        if inferenceHangs {
            try await Task.sleep(for: .seconds(60))
        }
        return editsWhenReady
    }
}

/// 记录加载被发起、完成了多少次。
///
/// 加载跑在 detached 任务里，计数必须是并发安全的。
actor LoadCounter {
    private(set) var started = 0
    private(set) var finished = 0

    func noteStart() { started += 1 }
    func noteFinish() { finished += 1 }
}

/// 不理会取消的等待，模拟 MLX 从本地目录读权重那种一路同步的加载。
///
/// 不能用 `Task.sleep`：它一被取消就抛错返回，那模拟的是另一种加载。
func uninterruptibleSleep(_ duration: Duration) async {
    let seconds = Double(duration.components.seconds)
        + Double(duration.components.attoseconds) / 1e18
    await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            continuation.resume()
        }
    }
}
