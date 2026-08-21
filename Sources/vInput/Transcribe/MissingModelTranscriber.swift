import Foundation

/// 「一个模型都没有」时顶在转写位上的那个东西：**立刻失败，绝不联网。**
///
/// ## 它替掉的是一条会自己去下载的路
///
/// 原先 `AppModel.bootstrap()` 在本地一个模型都没有时，会造一个
/// `ModelDescriptor(name: "openai_whisper-base", folder: "")`，而空 folder 在
/// `makeTranscriber` 里的含义是「交给 WhisperKit 按名字下载」
/// （`WhisperKitConfig(model:downloadBase:)` 那一支）。于是这条链是成立的：
///
/// 向导下载失败 → 用户关掉向导 → 面板说「就绪」 → 他按「开始听写」 →
/// **一个他没要过的 140 MB `openai_whisper-base` 从官方源开始下**，
/// 而且忽略他刚在向导里被指定的那个源，头部还写着「正在加载模型…」。
///
/// 这条路真的跑过：本机盘上留着
/// `~/Library/Application Support/vInput/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-base`。
///
/// 三点都是错的：用户没要过这个模型；它比向导刚下失败的那个差得多；
/// 它走的是刚刚被判定不通的那个源。所以这里不是「换一个更好的兜底模型」，
/// 而是**取消兜底**——没有模型就该说没有模型（头部那行由
/// `MenuPanelModel.headerStatus(hasModel:)` 负责说），而不是替用户
/// 做一个几百兆的决定。
///
/// 报 `.modelNotReady` 而不是 `.engineFailed`：前者的中文说明正是
/// 「模型尚未就绪」，一路显示到菜单栏都说得通。
struct MissingModelTranscriber: Transcriber {
    func prepare() async throws {
        throw TranscribeError.modelNotReady
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        throw TranscribeError.modelNotReady
    }
}
