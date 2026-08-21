import Foundation
import Testing

@testable import vInput

/// 「一个模型都没有」时**不许自作主张去下载一个**。
///
/// 失效链（QA 2026-08-22，本机盘上留着证据目录
/// `…/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-base`）：
/// 零模型时 `bootstrap()` 造 `ModelDescriptor(name: "openai_whisper-base",
/// folder: "")`，而空 folder 在 `makeTranscriber` 里的含义是「交给 WhisperKit
/// 按名字下载」。于是用户在向导下载失败之后按一下「开始听写」，
/// 一个他没要过的 140MB 模型就从**官方源**开始下——忽略他刚被指定的那个源。
@Suite("零模型时的转写器")
struct MissingModelTranscriberTests {

    /// 空目录的描述符必须换来 `MissingModelTranscriber`，**不是** WhisperKit。
    ///
    /// 这一条只能真跑：扫源码看不出 `makeTranscriber` 返回的是哪个类型，
    /// 而这正是那条会偷偷联网的岔路口。
    @Test func emptyFolderYieldsTheNonDownloadingTranscriber() {
        let transcriber = AppModel.makeTranscriber(ModelCatalog.noModel)
        let isMissing = transcriber is MissingModelTranscriber
        #expect(isMissing, "空目录换来的是 \(type(of: transcriber))，那条路会去联网下载")
    }

    /// 反向：有目录时仍然要拿到真的 WhisperKit 转写器。
    /// 只有上面那条的话，「一律返回 MissingModelTranscriber」也能全绿——
    /// 而那样这个应用就再也转写不了任何东西了。
    @Test func realFolderStillYieldsWhisperKit() {
        let descriptor = ModelDescriptor(name: "turbo", folder: "/some/where/turbo")
        let transcriber = AppModel.makeTranscriber(descriptor)
        let isWhisperKit = transcriber is WhisperKitTranscriber
        #expect(isWhisperKit, "有目录时换来的是 \(type(of: transcriber))")
    }

    /// `prepare()` 立刻失败，且报的是「模型尚未就绪」。
    ///
    /// **不许卡住、不许联网。** 它是那条会自己下载 140MB 的路的替代品，
    /// 报错反而是它唯一该做的事。
    @Test func prepareFailsImmediately() async {
        var thrown: TranscribeError?
        do {
            try await MissingModelTranscriber().prepare()
        } catch let error as TranscribeError {
            thrown = error
        } catch {
            thrown = nil
        }
        #expect(thrown == .modelNotReady)
    }

    @Test func transcribeFailsImmediately() async {
        var thrown: TranscribeError?
        do {
            _ = try await MissingModelTranscriber().transcribe([0, 0, 0])
        } catch let error as TranscribeError {
            thrown = error
        } catch {
            thrown = nil
        }
        #expect(thrown == .modelNotReady)
    }

    /// 那句错误一路显示到菜单栏都得说得通（`AppModel` 直接把它放进头部）。
    @Test func theErrorReadsAsChinese() {
        #expect(TranscribeError.modelNotReady.description == "模型尚未就绪")
    }
}
