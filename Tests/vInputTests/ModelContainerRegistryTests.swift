import Foundation
import MLXLMCommon
import Testing

@testable import vInput

/// 共用机制本身。
///
/// **这一套证明的是「登记处的判重、归一化、生命周期、失败重试都对」，
/// 证明不了「2 GB 权重只落了一次盘」**——注入的假闭包递增的是它自己的
/// 计数器。真模型只加载一次这件事必须在真机日志里看：
/// `模型容器：共用已有加载器` 那一行，加上第二层预热耗时接近 0
/// （冷加载实测 14.1 秒）。两者是两件事，别拿这一套当那件事的证据。
@Suite("模型容器登记处")
struct ModelContainerRegistryTests {
    /// 唯一的键，避免并行跑的用例之间互相看见对方的条目。
    private func freshKey(_ label: String = #function) -> ModelContainerKey {
        .identifier("\(label)-\(UUID().uuidString)")
    }

    @Test("同一个键只建一个加载器，加载闭包只跑一次")
    func sharesLoaderForSameKey() async throws {
        let registry = ModelContainerRegistry<Int>()
        let counter = LoadCounter()
        let key = freshKey()
        let make: @Sendable () -> OneShotLoader<Int> = {
            registry.loader(for: key) {
                await counter.noteStart()
                await counter.noteFinish()
                return 7
            }
        }

        let first = make()
        let second = make()
        #expect(first === second)
        #expect(try await first.value() == 7)
        #expect(try await second.value() == 7)
        #expect(await counter.started == 1)
    }

    @Test("不同键各建各的加载器")
    func separateLoadersForDifferentKeys() async throws {
        let registry = ModelContainerRegistry<Int>()
        let counter = LoadCounter()
        let base = URL(fileURLWithPath: "/models/\(UUID().uuidString)", isDirectory: true)
        let load: @Sendable () async throws -> Int = {
            await counter.noteStart()
            await counter.noteFinish()
            return 1
        }

        let a = registry.loader(for: .local(base.appendingPathComponent("4b")), load: load)
        let b = registry.loader(for: .local(base.appendingPathComponent("7b")), load: load)
        #expect(a !== b)
        _ = try await a.value()
        _ = try await b.value()
        #expect(await counter.started == 2)
        #expect(registry.liveLoaderCount == 2)
    }

    /// 目录键与标识符键碰巧同名时不能串——两者走的是
    /// `loadModelContainer` 的两个不同重载。
    @Test("目录键与标识符键不互相命中")
    func directoryKeyDoesNotCollideWithIdentifier() {
        let registry = ModelContainerRegistry<Int>()
        let name = UUID().uuidString
        let byDirectory = registry.loader(for: .local(URL(fileURLWithPath: "/\(name)"))) { 1 }
        let byIdentifier = registry.loader(for: .identifier("/\(name)")) { 1 }
        #expect(byDirectory !== byIdentifier)
    }

    /// 纯字符串层面的归一化，与路径存不存在无关。
    @Test(
        "同一个目录的不同写法命中同一个键",
        arguments: [
            ("/models/a/b", "/models/a/b/"),
            ("/models/a/b", "/models/a/./b"),
            ("/models/a/b", "/models/a/sub/../b"),
        ]
    )
    func normalizesDirectoryPaths(lhs: String, rhs: String) {
        #expect(
            ModelContainerKey.local(URL(fileURLWithPath: lhs))
                == ModelContainerKey.local(URL(fileURLWithPath: rhs)),
            "\(lhs) 与 \(rhs) 没有归一化到同一个键，共用会静默落空"
        )
    }

    /// 符号链接段。**必须建一个真目录才测得出来**：实测
    /// `resolvingSymlinksInPath` 只对**真的存在**的路径解符号链接——
    /// 拿一个虚构的 `/private/tmp/…` 写这条用例，它会红，而红的原因
    /// 与共用机制毫无关系。生产上模型目录必然存在，落在能解开的那一侧。
    ///
    /// 值得单独测是因为 macOS 上 `/tmp` 正是指向 `/private/tmp` 的符号链接，
    /// 而两层的目录来路不同（校正来自偏好，翻译将来可能来自别处），
    /// 只要有一边走过 realpath 就会写成 `/private/…`。
    @Test("同一个目录经符号链接的两种写法命中同一个键")
    func normalizesSymlinkedPaths() throws {
        let directory = URL(
            fileURLWithPath: "/tmp/vinput-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let viaPrivate = URL(fileURLWithPath: "/private" + directory.path, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: viaPrivate.path), "前提没成立：路径不存在")
        #expect(ModelContainerKey.local(directory) == ModelContainerKey.local(viaPrivate))
    }

    @Test("不同目录不会被归一化成同一个键")
    func distinctDirectoriesStayDistinct() {
        #expect(
            ModelContainerKey.local(URL(fileURLWithPath: "/models/4b"))
                != ModelContainerKey.local(URL(fileURLWithPath: "/models/7b"))
        )
    }

    /// 判重与写入之间只要有一丝空隙，两个并发调用就会各建一个加载器——
    /// `OneShotLoader` 注释里记着的 M4 那个坑在上一层的复现。
    ///
    /// 32 轮 × 8 个并发调用：单轮的窗口是纳秒级，一次撞不上不说明没有，
    /// 反复撞才有话语权。
    @Test("并发领取只建一个加载器")
    func concurrentLookupsCreateOneLoader() async {
        for round in 0..<32 {
            let registry = ModelContainerRegistry<Int>()
            let counter = LoadCounter()
            let key = freshKey("round-\(round)")

            let identities = await withTaskGroup(of: ObjectIdentifier.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        let loader = registry.loader(for: key) {
                            await counter.noteStart()
                            await uninterruptibleSleep(.milliseconds(5))
                            await counter.noteFinish()
                            return 42
                        }
                        _ = try? await loader.value()
                        return ObjectIdentifier(loader)
                    }
                }
                var seen: Set<ObjectIdentifier> = []
                for await identity in group { seen.insert(identity) }
                return seen
            }

            let started = await counter.started
            #expect(identities.count == 1, "第 \(round) 轮拿到了 \(identities.count) 个不同的加载器")
            #expect(started == 1, "第 \(round) 轮加载了 \(started) 次")
        }
    }

    /// 失败不能被缓存成永久失败，且重试期间两层仍然共用同一个加载器。
    ///
    /// 「仍然共用」这半句是登记处的责任：失败后若把条目摘掉，两层会在重试时
    /// 各建一个新加载器——共用恰好在最需要它的那一刻失效。
    @Test("加载失败后仍共用同一个加载器，且能重试成功")
    func failureIsNotCachedAndStaysShared() async throws {
        let registry = ModelContainerRegistry<Int>()
        let counter = LoadCounter()
        let key = freshKey()
        let load: @Sendable () async throws -> Int = {
            await counter.noteStart()
            guard await counter.started > 1 else { throw CorrectorError.engineFailed("boom") }
            await counter.noteFinish()
            return 7
        }

        let first = registry.loader(for: key, load: load)
        await #expect(throws: CorrectorError.engineFailed("boom")) { try await first.value() }

        // 换一个「使用者」再领一次：拿到的必须还是同一个加载器。
        let second = registry.loader(for: key, load: load)
        #expect(second === first, "失败之后登记处换了新加载器，重试时共用会落空")
        #expect(try await second.value() == 7)
        #expect(await counter.started == 2)
    }

    /// 弱引用语义：使用者全部释放后条目消失，下一个使用者重新加载。
    ///
    /// 这一条守着「不改变现有生产行为」——今天换校正模型时旧
    /// `MLXCorrector` 连同它的容器一起释放。登记处若强持有，旧模型会永远
    /// 留在内存里，为省内存做的东西反过来成了泄漏。
    @Test("没人持有时条目消失，新使用者重新加载")
    func releasesLoaderWhenNobodyHoldsIt() async throws {
        let registry = ModelContainerRegistry<Int>()
        let counter = LoadCounter()
        let key = freshKey()
        let load: @Sendable () async throws -> Int = {
            await counter.noteStart()
            await counter.noteFinish()
            return 3
        }

        var holder: OneShotLoader<Int>? = registry.loader(for: key, load: load)
        _ = try await holder!.value()
        #expect(registry.liveLoaderCount == 1)

        holder = nil
        #expect(registry.liveLoaderCount == 0, "没人持有了，条目还在——容器会一直占着内存")

        let revived = registry.loader(for: key, load: load)
        _ = try await revived.value()
        #expect(await counter.started == 2)
    }

    /// 一个使用者还活着时，条目不能被清掉。
    @Test("还有人持有时条目不消失")
    func keepsLoaderWhileSomeoneHoldsIt() {
        let registry = ModelContainerRegistry<Int>()
        let key = freshKey()
        var dropped: OneShotLoader<Int>? = registry.loader(for: key) { 1 }
        let kept = registry.loader(for: key) { 1 }
        #expect(dropped === kept)
        dropped = nil
        #expect(registry.liveLoaderCount == 1)
        let third = registry.loader(for: key) { 1 }
        #expect(third === kept)
    }
}

/// 两层真的去登记处领了加载器——共用的接线。
///
/// **与上面那套是两回事。** 上面测的是登记处，这里测的是
/// `MLXCorrector` / `MLXTranslator` 有没有用它。没有这几条的话，把
/// `init` 里的 `registry.loader(...)` 换回 `OneShotLoader { ... }`，
/// 上面整套仍然全绿。
///
/// 用得起真类型是因为**构造它们不加载任何模型**——`init` 只是把闭包存起来，
/// 一个字节的权重都不读，因此不需要 Metal 着色器，`swift test` 下也能跑。
@Suite("校正与翻译共用模型容器")
struct SharedModelContainerWiringTests {
    private func modelDirectory(_ name: String) -> URL {
        URL(
            fileURLWithPath: "/models/\(UUID().uuidString)/\(name)",
            isDirectory: true
        )
    }

    @Test("指向同一目录时两层拿到同一个容器加载器")
    func correctorAndTranslatorShareOneLoader() async {
        let registry = ModelContainerRegistry<ModelContainer>()
        let directory = modelDirectory("qwen3-4b-instruct-2507-4bit")

        let corrector = MLXCorrector(modelDirectory: directory, registry: registry)
        let translator = MLXTranslator(modelDirectory: directory, registry: registry)

        #expect(await corrector.loaderIdentity == translator.loaderIdentity)
        #expect(registry.liveLoaderCount == 1, "同一个模型被登记了两次，两份权重会同时驻留")
    }

    /// 写法不同但指的是同一个目录时也要共用——生产上校正的目录来自偏好、
    /// 翻译的目录将来可能来自别处，两边只要有一边多个尾斜杠就分家了。
    @Test("同一目录的不同写法也共用")
    func sharesAcrossEquivalentPathSpellings() async {
        let registry = ModelContainerRegistry<ModelContainer>()
        let base = "/models/\(UUID().uuidString)/qwen3-4b"

        let corrector = MLXCorrector(
            modelDirectory: URL(fileURLWithPath: base), registry: registry)
        let translator = MLXTranslator(
            modelDirectory: URL(fileURLWithPath: base + "/"), registry: registry)

        #expect(await corrector.loaderIdentity == translator.loaderIdentity)
        #expect(registry.liveLoaderCount == 1)
    }

    @Test("指向不同目录时各自加载")
    func differentDirectoriesLoadSeparately() async {
        let registry = ModelContainerRegistry<ModelContainer>()
        let corrector = MLXCorrector(
            modelDirectory: modelDirectory("qwen3-4b-instruct-2507-4bit"), registry: registry)
        let translator = MLXTranslator(
            modelDirectory: modelDirectory("qwen2.5-7b-instruct-4bit"), registry: registry)

        #expect(await corrector.loaderIdentity != translator.loaderIdentity)
        #expect(registry.liveLoaderCount == 2)
    }

    /// 校正层的另一条路：不给目录时按 Hugging Face 标识符加载。
    /// 它和「本地目录」是 `loadModelContainer` 的两个重载，不能互相命中。
    @Test("按标识符的校正器不与按目录的翻译器共用")
    func identifierBackedCorrectorDoesNotShareWithDirectory() async {
        let registry = ModelContainerRegistry<ModelContainer>()
        let directory = modelDirectory("qwen3-4b-instruct-2507-4bit")
        let corrector = MLXCorrector(modelID: directory.path, registry: registry)
        let translator = MLXTranslator(modelDirectory: directory, registry: registry)

        #expect(await corrector.loaderIdentity != translator.loaderIdentity)
    }

    /// 两个校正器指向同一目录时也共用——`AppModel` 换模型/开关校正时会新建
    /// `MLXCorrector`，新旧两个实例在旧的被释放之前是同时存在的。
    @Test("两个校正器指向同一目录时共用")
    func twoCorrectorsShare() async {
        let registry = ModelContainerRegistry<ModelContainer>()
        let directory = modelDirectory("qwen3-4b-instruct-2507-4bit")
        let first = MLXCorrector(modelDirectory: directory, registry: registry)
        let second = MLXCorrector(modelDirectory: directory, registry: registry)
        #expect(await first.loaderIdentity == second.loaderIdentity)
    }

    /// 两层都释放之后容器要跟着走，否则换模型会把旧权重永远留在内存里。
    @Test("两层都释放后登记处不再持有容器")
    func containerIsReleasedWhenBothLayersGo() {
        let registry = ModelContainerRegistry<ModelContainer>()
        let directory = modelDirectory("qwen3-4b-instruct-2507-4bit")
        var corrector: MLXCorrector? = MLXCorrector(modelDirectory: directory, registry: registry)
        var translator: MLXTranslator? = MLXTranslator(
            modelDirectory: directory, registry: registry)
        #expect(registry.liveLoaderCount == 1)

        corrector = nil
        #expect(registry.liveLoaderCount == 1, "还有翻译层在用，容器不该被放掉")
        translator = nil
        #expect(registry.liveLoaderCount == 0, "两层都走了，旧模型还留在内存里")
        _ = corrector
        _ = translator
    }
}
