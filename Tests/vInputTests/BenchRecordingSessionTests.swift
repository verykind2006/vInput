import Foundation
import Testing

@testable import vInput

@MainActor
@Suite("基准集录制会话")
struct BenchRecordingSessionTests {
    private func makeManifest() -> BenchManifest {
        BenchManifest(entries: [
            BenchEntry(id: "a", text: "第一句", category: .technical),
            BenchEntry(id: "b", text: "第二句", category: .colloquial),
        ])
    }

    @Test("初始停在第一条")
    func startsAtFirstEntry() {
        let session = BenchRecordingSession(manifest: makeManifest())
        #expect(session.current?.id == "a")
        #expect(session.progressText == "1 / 2")
    }

    @Test("前进到下一条")
    func advances() {
        let session = BenchRecordingSession(manifest: makeManifest())
        session.advance()
        #expect(session.current?.id == "b")
        #expect(session.progressText == "2 / 2")
    }

    /// 一次性录完二十几段不允许出错是不现实的，必须能重录单条。
    @Test("可以回到上一条重录")
    func canGoBack() {
        let session = BenchRecordingSession(manifest: makeManifest())
        session.advance()
        session.retreat()
        #expect(session.current?.id == "a")
    }

    @Test("走到末尾后不越界")
    func doesNotOverrun() {
        let session = BenchRecordingSession(manifest: makeManifest())
        session.advance()
        session.advance()
        session.advance()
        #expect(session.current?.id == "b")
    }

    @Test("跳到指定条目")
    func jumpsToEntry() {
        let session = BenchRecordingSession(manifest: makeManifest())
        session.jump(toID: "b")
        #expect(session.current?.id == "b")
    }

    /// 菜单里的标准文本一个字都不能少：用户照着它读，截断了就录不出
    /// 对得上参考答案的音频。基准集最长一条 64 字，远超一行能放下的量。
    @Test("标准文本分行显示，不截断")
    func wrapsWithoutTruncating() {
        let text = String(repeating: "字", count: 64)
        let lines = BenchRecordingSession.wrap(text, perLine: 20)
        #expect(lines.count == 4)
        #expect(lines.map(\.count) == [20, 20, 20, 4])
        #expect(lines.joined() == text)
    }

    @Test("短文本只占一行")
    func wrapsShortText() {
        #expect(BenchRecordingSession.wrap("第一句", perLine: 20) == ["第一句"])
    }

    @Test("当前条目的文本按行取出")
    func exposesCurrentLines() {
        let session = BenchRecordingSession(manifest: makeManifest())
        #expect(session.currentLines == ["第一句"])
    }

    /// 入口默认隐藏是这个功能的前提：它把音频写到磁盘，而原始设计写明
    /// 「音频不落盘」。菜单藏没藏住只能靠肉眼看，但「没开环境变量就建不出
    /// 会话」这条能测——真被改成常态功能时，这里会先红。
    ///
    /// 开着 VINPUT_BENCH 跑测试时跳过：那时它本就该能开。
    @Test(
        "没有 VINPUT_BENCH=1 时开不出录制会话",
        .enabled(if: ProcessInfo.processInfo.environment["VINPUT_BENCH"] != "1")
    )
    func recordingIsDisabledWithoutEnvironmentFlag() {
        #expect(AppModel.benchEnabled == false)
        let model = AppModel()
        model.startBenchRecording()
        #expect(model.benchSession == nil)
    }
}
