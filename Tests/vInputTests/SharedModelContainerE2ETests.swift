import Foundation
import MLXLMCommon
import Testing

@testable import vInput

/// 共用模型容器的端到端体检：**真的只读了一次 2 GB 权重吗。**
///
/// 这一套存在的唯一理由，是 `ModelContainerRegistryTests` 证明不了它。
/// 那边注入的是假加载闭包，「加载计数 == 1」计的是那个假闭包被调了几次——
/// 它证明的是共用机制正确，不是权重只落了一次盘。两件事之间隔着
/// `loadModelContainer` 这个真正花 14 秒、真正吃 2 GB 的东西。
///
/// 这里量的是那 14 秒和那 2 GB：第二层 `prepare()` 的耗时，以及两次
/// `prepare()` 之间进程物理内存占用的增量。
///
/// **必须用 `xcodebuild` 跑**（`./scripts/e2e.sh`）。SwiftPM 命令行编不出
/// mlx-swift 的 Metal 着色器，MLX 一初始化就报
/// `Failed to load the default metallib`，而单元测试照常通过——M4 期间踩过。
/// 门控与 `CorrectionE2ETests` 共用同一个标记文件，理由见 `E2EGate`。
@Suite("模型容器共用端到端", .enabled(if: E2EGate.isEnabled), .serialized)
struct SharedModelContainerE2ETests {
    @Test("翻译层拿到校正层已加载好的容器，不再读一遍权重")
    func secondLayerReusesLoadedWeights() async throws {
        let directory = E2EGate.defaultModelDirectory
        try #require(
            FileManager.default.fileExists(atPath: directory.path),
            "模型不在默认位置：\(directory.path)"
        )

        // 用独立的登记处而非 `SharedModelContainers.registry`：同一个进程里
        // 别的用例可能已经把这个模型加载过了，那样第一次 `prepare()` 也会是
        // 0 秒，整条用例退化成恒真。
        let registry = ModelContainerRegistry<ModelContainer>()
        let corrector = MLXCorrector(modelDirectory: directory, registry: registry)
        let translator = MLXTranslator(modelDirectory: directory, registry: registry)

        let footprintBefore = physicalFootprintBytes()
        let coldStarted = ContinuousClock.now
        try await corrector.prepare()
        let cold = ContinuousClock.now - coldStarted
        let footprintAfterCold = physicalFootprintBytes()

        let warmStarted = ContinuousClock.now
        try await translator.prepare()
        let warm = ContinuousClock.now - warmStarted
        let footprintAfterWarm = physicalFootprintBytes()

        let coldGrowth = Int64(footprintAfterCold) - Int64(footprintBefore)
        let warmGrowth = Int64(footprintAfterWarm) - Int64(footprintAfterCold)
        print(
            """
            [共用体检] 模型=\(directory.lastPathComponent)
            [共用体检] 第一层加载 耗时 \(cold) 物理内存 +\(megabytes(coldGrowth)) MB
            [共用体检] 第二层加载 耗时 \(warm) 物理内存 +\(megabytes(warmGrowth)) MB
            """
        )

        #expect(await corrector.loaderIdentity == translator.loaderIdentity)
        #expect(await translator.isReady, "第二层没就绪，说明它拿到的不是已加载好的容器")

        // **先量后写，阈值都是回填的**（2026-08-18 本机，
        // Models/qwen3-4b-instruct-2507-4bit）：
        // 第一层 3.138 秒 / +2202.3 MB，第二层 0.000002 秒 / +0.0 MB。
        //
        // 这一条先立着：第一层没真的把权重读进来的话，第二层「不涨」是恒真的，
        // 整条用例就成了空判据。1 GB 对实测的 2202 MB 有 2.2 倍余量。
        #expect(
            coldGrowth > 1_000 * 1024 * 1024,
            "第一层只涨了 \(megabytes(coldGrowth)) MB，模型根本没加载，下面两条都不作数"
        )
        // 第二份权重会是 2 GB 量级；200 MB 只是给分配器噪声留的余量。
        #expect(
            warmGrowth < 200 * 1024 * 1024,
            "第二层又涨了 \(megabytes(warmGrowth)) MB，共用没生效，两份权重同时驻留"
        )
        // 实测最快的一次真加载是「有页缓存」的 3.7 秒（M8 第 0 步），本轮 3.1 秒。
        // 100 毫秒离两边都很远：既不会被 2 微秒的命中误判，也接不上任何一次真加载。
        #expect(
            warm < .milliseconds(100),
            "第二层耗时 \(warm)，不像是拿现成容器，像是又加载了一遍（第一层 \(cold)）"
        )
    }

    private func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1024 / 1024)
    }

    /// 进程的物理内存占用（phys_footprint），与「活动监视器」里那一列同源。
    private func physicalFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
