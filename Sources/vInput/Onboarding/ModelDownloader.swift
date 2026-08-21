import Foundation
import WhisperKit

enum ModelDownloadError: Error, Equatable { case transportFailed }

/// 真正下载的能力。抽协议是为了能测——真下载要联网、要 1.5GB。
@MainActor
protocol ModelDownloadBackend {
    func download(
        variant: String, into root: String, endpoint: String,
        onProgress: @escaping (Double) -> Void
    ) async throws
}

/// 转写模型的获取。
///
/// 底下是 `WhisperKit.download(variant:downloadBase:useBackgroundSession:from:token:endpoint:progressCallback:)`
/// ——**公开 API，不用改 `vendor/`**，而且它同时给了 `endpoint`（可传镜像）
/// 与 `progressCallback`（进度条不用自己造）。这一条是本批「只保主链」
/// 那个范围决定的技术基础。
enum ModelDownloader {
    /// **只下 turbo。** 用户 2026-08-21：「目前我用下来觉得 Turbo 模型就够用」。
    /// 因此向导里没有模型选择这一步。
    static let variant = "openai_whisper-large-v3-v20240930_turbo"

    enum Outcome: Equatable {
        case alreadyPresent
        case downloaded(source: DownloadSource)
        /// 带上是哪个源失败的：出问题时要能分清模型坏了还是源坏了。
        case failed(source: DownloadSource)
    }

    nonisolated static func percentText(_ fraction: Double) -> String {
        let clamped = min(1, max(0, fraction))
        return "\(Int((clamped * 100).rounded()))%"
    }

    @MainActor
    static func run(
        root: String,
        alreadyPresent: (String) -> Bool,
        backend: ModelDownloadBackend,
        source: DownloadSource,
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async -> Outcome {
        let folder = (root as NSString).appendingPathComponent(variant)
        if alreadyPresent(folder) { return .alreadyPresent }
        do {
            try await backend.download(
                variant: variant, into: root, endpoint: source.endpoint, onProgress: onProgress)
            AppLogger.shared.log("模型下载完成：\(variant)，源=\(source.displayName)")
            return .downloaded(source: source)
        } catch {
            AppLogger.shared.log("模型下载失败：源=\(source.displayName) 错误=\(error)")
            return .failed(source: source)
        }
    }
}

/// 生产实现：转发给 WhisperKit。**这一层在测试进程里跑不到**
/// （真联网、1.5GB），逻辑因此全部留在上面的 `run` 里。
///
/// ## `downloadBase` 传什么、为什么要挪目录
///
/// `WhisperKit.download(variant:downloadBase:...)` 落盘的位置**不是**
/// `downloadBase` 本身，而是 `downloadBase/models/<repo>/<variant>`——
/// 这条嵌套写死在 `HubApi.localRepoLocation(_:)`
/// （`downloadBase.appending(component: repo.type.rawValue)
/// .appending(component: repo.id)`，`repo.type.rawValue` 是字面量
/// `"models"`，`repo.id` 默认 `"argmaxinc/whisperkit-coreml"`），
/// `WhisperKit.download` 的返回值是这个嵌套目录再拼上 `variantPath`。
///
/// 而 `ModelCatalog.discover(in:)` 只看 `root` 的**直接子目录**是否是合法模型
/// 目录（子目录下直接有 `AudioEncoder.mlmodelc` 等三个文件夹），不递归。
/// 两边对不上：如果把 `applicationSupportRoot()`/`defaultDownloadBase()`
/// 原样当 `downloadBase` 传给 `WhisperKit.download`，模型会下到
/// `root/models/argmaxinc/whisperkit-coreml/<variant>`，`discover` 在
/// `root` 下只看到一个叫 `models` 的目录、里面没有 `AudioEncoder.mlmodelc`，
/// 判定「不是模型目录」而整个丢弃——这就是任务描述里说的「下载 1.5GB
/// 然后报告找不到模型」。
///
/// 因此这里把 `root` 原样当 `downloadBase` 传下去（借它当临时脚手架），
/// 下载完成后把 WhisperKit 实际吐出的目录**挪到** `root/<variant>`
/// （`ModelDownloader.run` 里 `alreadyPresent` 检查的正是这个位置），
/// 再删掉挪空的 `models/` 脚手架目录，不留残留。
@MainActor
struct WhisperKitDownloadBackend: ModelDownloadBackend {
    func download(
        variant: String, into root: String, endpoint: String,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let downloadBase = URL(fileURLWithPath: root, isDirectory: true)
        let downloaded = try await WhisperKit.download(
            variant: variant,
            downloadBase: downloadBase,
            from: "argmaxinc/whisperkit-coreml",
            token: nil,
            endpoint: endpoint,
            progressCallback: { progress in
                Task { @MainActor in onProgress(progress.fractionCompleted) }
            })

        let destination = downloadBase.appendingPathComponent(variant, isDirectory: true)
        if downloaded.path != destination.path {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: downloaded, to: destination)
        }
        // 清掉 downloadBase/models 这层脚手架——模型已经挪到 root 的直接
        // 子目录了，留着空壳目录只会让人误以为还有别的东西没搬完。
        try? FileManager.default.removeItem(
            at: downloadBase.appendingPathComponent("models", isDirectory: true))
    }
}
