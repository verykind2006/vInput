import Foundation
import Testing
@testable import vInput

/// 返回预设结果的转写器。
final class FakeTranscriber: Transcriber, @unchecked Sendable {
    /// `transcribe` 的返回值。
    var result: String = ""
    /// 设置后，`transcribe` 抛出该错误。
    var transcribeError: Error?
    /// 设置后，`prepare` 抛出该错误。
    var prepareError: Error?
    /// 转写前的人为延迟，用于测试超时与并发。
    var delay: Duration = .zero

    private(set) var receivedSamples: [[Float]] = []
    private(set) var prepareCallCount = 0
    /// 首次 transcribe 被调用时的全局序号。
    ///
    /// 与 `FakePreviewEngine.stopOrder` 共用同一个计数器，用于断言
    /// 「先停预览、再发起全量转写」——两者共享同一套 WhisperKit 解码器
    /// 实例，顺序反了会产生数据竞争。只比较计数是抓不到顺序问题的。
    private(set) var firstTranscribeOrder: Int?

    func prepare() async throws {
        prepareCallCount += 1
        if let prepareError { throw prepareError }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        if firstTranscribeOrder == nil {
            firstTranscribeOrder = FakePreviewEngine.orderCounter.next()
        }
        receivedSamples.append(samples)
        if delay > .zero { try await Task.sleep(for: delay) }
        if let transcribeError { throw transcribeError }
        return result
    }
}

@Suite("FakeTranscriber")
struct FakeTranscriberTests {
    @Test("返回预设文本并记录收到的样本")
    func returnsConfiguredResult() async throws {
        let fake = FakeTranscriber()
        fake.result = "你好世界"

        let text = try await fake.transcribe([1, 2, 3])

        #expect(text == "你好世界")
        #expect(fake.receivedSamples == [[1, 2, 3]])
    }

    @Test("抛出预设的错误")
    func throwsConfiguredError() async {
        let fake = FakeTranscriber()
        fake.transcribeError = TranscribeError.modelNotReady

        await #expect(throws: TranscribeError.modelNotReady) {
            try await fake.transcribe([1])
        }
    }
}
