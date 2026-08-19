import Foundation

@testable import vInput

/// 记录「哪一层先被调到」。
///
/// 存在的理由：`DictationSession.State.allCasesInPipelineOrder` 是一个手写的
/// 静态数组，**它证明不了 `finish()` 里的真实调用顺序**——把那两段代码对调，
/// 数组一个字都不用改。真正的证据只能来自「校正器与翻译器各自被调到的
/// 那一刻」，所以两个替身共用这一份流水账。
///
/// 做成 actor 而不是数组：校正器跑在 `@unchecked Sendable` 的类里、翻译器
/// 跑在 actor 里，两边都是 async 上下文，共享可变数组会是数据竞争。
actor CallOrderLog {
    private(set) var calls: [String] = []

    func record(_ name: String) {
        calls.append(name)
    }
}

/// 可编程的假翻译器。**不复刻生产逻辑**，只按剧本回答。
///
/// 记 `callCount` 与 `prepareCallCount` 是有用的：流水线好几条规则是
/// 「**不**去调翻译器」（目标是中文、空文本、模型未就绪时不等加载），
/// 而「没调」这件事只有计数看得见——光看返回值，一个把原文原样返回的
/// 翻译器与「根本没调」分不开。
///
/// 记 `receivedTexts` 是给会话那一侧用的：**翻译器收到的是不是校正后的
/// 文本**，是「校正先于翻译」这条规则唯一的行为证据。
///
/// 提到共享文件是因为 `TranslationPipelineTests` 与
/// `DictationTranslationTests` 两处都要用它。各写一份的话两个替身会各自
/// 漂移，而本仓库栽过这个坑（`Bench.swift` 的 shim 漂了两回，M5 期间删掉）。
actor FakeTranslator: Translator {
    enum Behavior: Sendable {
        case succeed(String)
        case fail(TranslatorError)
        /// 抛一个**不是** `TranslatorError` 的错误，走兜底那条 catch。
        case failOther
        case hang
        /// 睡一段固定时间再成功。**用来验证超时预算本身**：同一个延迟，
        /// 预算够就过、不够就超时，两者的差别只能来自预算。
        case slow(Duration, String)
    }

    /// 兜底 catch 的素材。云端实现漏出 URLError 就是这个形态。
    struct OtherError: Error {}

    private let behavior: Behavior
    private let ready: Bool
    private let prepareError: TranslatorError?
    private let log: CallOrderLog?
    private(set) var callCount = 0
    private(set) var prepareCallCount = 0
    /// 每次 `translate` 收到的原文，按顺序。
    private(set) var receivedTexts: [String] = []

    init(
        _ behavior: Behavior,
        ready: Bool = true,
        prepareError: TranslatorError? = nil,
        log: CallOrderLog? = nil
    ) {
        self.behavior = behavior
        self.ready = ready
        self.prepareError = prepareError
        self.log = log
    }

    var isReady: Bool { get async { ready } }

    func prepare() async throws {
        prepareCallCount += 1
        if let prepareError { throw prepareError }
    }

    func translate(_ text: String, to target: TranslationTarget) async throws -> String {
        callCount += 1
        receivedTexts.append(text)
        await log?.record("translate")
        switch behavior {
        case .succeed(let output): return output
        case .fail(let error): throw error
        case .failOther: throw OtherError()
        case .slow(let delay, let output):
            try await Task.sleep(for: delay)
            return output
        case .hang:
            try await Task.sleep(for: .seconds(600))
            return ""
        }
    }
}
