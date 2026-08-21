import Foundation

/// 模型偏好顺序。
///
/// 应用启动时在模型根目录下按此顺序查找 `<name>`，取第一个本地已存在的。
/// 根目录是 `~/Library/Application Support/vInput/huggingface`，开发机上
/// 若仓库里有 `vendor/models` 则优先用它（判据见 `ModelCatalog.resolveRoot`）。
/// 因此**换模型只需下载对应目录，不需要改代码**：
///
/// ```bash
/// ./scripts/fetch-model.sh openai_whisper-large-v3
/// ```
///
/// 想临时退回小模型做对比，把对应目录移走即可。
///
/// 顺序依据：**默认取速度与质量的平衡点，而非质量天花板。**
///
/// M1 实测（Apple M3，见 docs/model-benchmark-2026-08-12.txt）：
///
/// | 场景 | 音频 | turbo | large-v3 |
/// |---|---|---|---|
/// | 闲聊 | 4.0s | 0.60s | 2.02s |
/// | 技术短句 | 5.1s | 0.71s | 2.95s |
/// | 技术密集 | 12.1s | 1.09s | 5.14s |
/// | 长文 | 24.6s | 1.58s | 8.71s |
///
/// turbo 快 3–5.5 倍，代价是个别同音错字与长文标点缺失——而这两样
/// 正是 M4 润色层要解决的。听写工具的手感由延迟主导，因此默认用 turbo，
/// 需要质量天花板时可在菜单里随时切到 large-v3。
enum ModelPreference {
    static let preferredModels = [
        "openai_whisper-large-v3-v20240930_turbo",
        "openai_whisper-large-v3-v20240930_turbo_632MB",
        "openai_whisper-large-v3",
        "openai_whisper-medium",
        "openai_whisper-small",
        "openai_whisper-base",
    ]
}
