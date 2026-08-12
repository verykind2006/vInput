import Testing
@testable import vInput

@Suite("TypingSink 分块")
struct TypingSinkChunkTests {
    @Test("短文本只产生一块")
    func shortTextSingleChunk() {
        let units = Array("你好".utf16)
        let chunks = TypingSink.chunkRanges(unitCount: units.count, chunkSize: 20, units: units)
        #expect(chunks.count == 1)
        #expect(chunks[0] == 0..<2)
    }

    @Test("长文本按块大小切分")
    func longTextSplits() {
        let units = Array(String(repeating: "字", count: 50).utf16)
        let chunks = TypingSink.chunkRanges(unitCount: units.count, chunkSize: 20, units: units)
        #expect(chunks.count == 3)
        #expect(chunks[0] == 0..<20)
        #expect(chunks[1] == 20..<40)
        #expect(chunks[2] == 40..<50)
    }

    @Test("空文本产生零块")
    func emptyTextNoChunks() {
        let chunks = TypingSink.chunkRanges(unitCount: 0, chunkSize: 20, units: [])
        #expect(chunks.isEmpty)
    }

    @Test("不在代理对中间切开")
    func neverSplitsSurrogatePair() {
        // "😀" 是一个代理对，占 2 个 UTF-16 单元。
        // 构造成第 20 个单元正好是高位代理的情形。
        let text = String(repeating: "a", count: 19) + "😀" + String(repeating: "b", count: 10)
        let units = Array(text.utf16)
        let chunks = TypingSink.chunkRanges(unitCount: units.count, chunkSize: 20, units: units)

        // 第一块应缩短到 19，把整个代理对留给下一块。
        #expect(chunks[0] == 0..<19)
        #expect(chunks[1].lowerBound == 19)

        // 逐块重组后必须与原文完全一致。
        let rebuilt = chunks
            .map { String(decoding: units[$0], as: UTF16.self) }
            .joined()
        #expect(rebuilt == text)
    }

    @Test("连续 emoji 也能正确重组")
    func consecutiveEmoji() {
        let text = String(repeating: "🎉", count: 30)
        let units = Array(text.utf16)
        let chunks = TypingSink.chunkRanges(unitCount: units.count, chunkSize: 7, units: units)
        let rebuilt = chunks
            .map { String(decoding: units[$0], as: UTF16.self) }
            .joined()
        #expect(rebuilt == text)
    }

    @Test("中英混排长文本能完整重组")
    func mixedScriptRoundTrip() {
        let text = String(repeating: "把 useEffect 的 dependency array 改一下。", count: 8)
        let units = Array(text.utf16)
        let chunks = TypingSink.chunkRanges(unitCount: units.count, chunkSize: 20, units: units)
        let rebuilt = chunks
            .map { String(decoding: units[$0], as: UTF16.self) }
            .joined()
        #expect(rebuilt == text)
    }
}

@Suite("TypingSink 权限")
@MainActor
struct TypingSinkPermissionTests {
    @Test("未授权时抛出 accessibilityDenied 而不发送事件")
    func deniedWhenUntrusted() {
        var sink = TypingSink()
        sink.isAccessibilityTrusted = { false }

        #expect(throws: TextSinkError.accessibilityDenied) {
            try sink.send("你好")
        }
    }

    @Test("空文本直接返回，不检查权限")
    func emptyTextIsNoop() throws {
        var sink = TypingSink()
        sink.isAccessibilityTrusted = { false }

        // 不抛错即通过
        try sink.send("")
    }
}
