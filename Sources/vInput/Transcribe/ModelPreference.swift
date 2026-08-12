import Foundation

/// 模型偏好顺序。
///
/// 应用启动时按此顺序查找 `vendor/models/<name>`，取第一个本地已存在的。
/// 因此**换模型只需下载对应目录，不需要改代码**：
///
/// ```bash
/// ./scripts/fetch-model.sh openai_whisper-large-v3
/// ```
///
/// 想临时退回小模型做对比，把对应目录移走即可。
///
/// 顺序依据：质量优先，同时保留逐级降级的余地。
/// - `large-v3`：完整 32 层解码器，质量天花板，M3 上约 1.5–2.5 秒 / 5 秒音频
/// - `large-v3-v20240930_turbo`：OpenAI 官方 turbo，4 层解码器，约 0.6–1 秒
/// - `base`：M1 的起步模型，约 0.75 秒，但中文标点与技术术语明显不足
enum ModelPreference {
    static let preferredModels = [
        "openai_whisper-large-v3",
        "openai_whisper-large-v3-v20240930_turbo",
        "openai_whisper-large-v3-v20240930_turbo_632MB",
        "openai_whisper-medium",
        "openai_whisper-small",
        "openai_whisper-base",
    ]
}
