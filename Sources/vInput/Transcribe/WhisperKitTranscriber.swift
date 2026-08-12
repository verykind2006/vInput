import Foundation
import WhisperKit

/// WhisperKit 适配层。
///
/// 用 actor 而非 class，是因为模型加载与推理都不可重入：
/// 两个会话同时触发时，第二个必须排队而不是并发进入 Core ML。
actor WhisperKitTranscriber: Transcriber {
    /// 低于此时长的音频不送去转写，避免 Whisper 对极短片段产生幻觉文本。
    static let minimumDuration: TimeInterval = 0.3

    private let modelName: String
    /// 本地模型目录。设置后优先于 `modelName`，跳过网络下载。
    ///
    /// 存在这个参数是因为 WhisperKit 内置的 URLSession 下载器在丢包
    /// 网络下会整体超时放弃（见计划「风险 0」）。模型由
    /// `scripts/fetch-model.sh` 用 curl 预先拉取。
    private let modelFolder: String?
    private let language: String
    /// 把输出统一转成简体。Whisper 即便指定 language="zh" 也常输出繁体。
    /// 面向繁体用户时可关闭。
    private let normalizeToSimplified: Bool
    private var pipe: WhisperKit?

    init(
        modelName: String = "base",
        modelFolder: String? = nil,
        language: String = "zh",
        normalizeToSimplified: Bool = true
    ) {
        self.modelName = modelName
        self.modelFolder = modelFolder
        self.language = language
        self.normalizeToSimplified = normalizeToSimplified
    }

    func prepare() async throws {
        guard pipe == nil else { return }
        do {
            let config = if let modelFolder {
                WhisperKitConfig(modelFolder: modelFolder)
            } else {
                WhisperKitConfig(model: modelName)
            }
            pipe = try await WhisperKit(config)
        } catch {
            throw TranscribeError.engineFailed(error.localizedDescription)
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let duration = Double(samples.count) / AudioFormat.sampleRate
        guard duration >= Self.minimumDuration else {
            throw TranscribeError.audioTooShort
        }

        try await prepare()
        guard let pipe else { throw TranscribeError.modelNotReady }

        do {
            let options = DecodingOptions(language: language)
            let results = try await pipe.transcribe(
                audioArray: samples,
                decodeOptions: options
            )
            let text = results
                .map(\.text)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalizeToSimplified ? ChineseScript.toSimplified(text) : text
        } catch {
            throw TranscribeError.engineFailed(error.localizedDescription)
        }
    }
}
