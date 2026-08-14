import Testing

@testable import vInput

@Suite("校正提示词")
struct CorrectionPromptTests {
    @Test("用户提示包含待校正文本")
    func userPromptCarriesText() {
        #expect(CorrectionPrompt.user(for: "小米耀空气").contains("小米耀空气"))
    }

    /// 提示词里必须给出格式范例，否则 4B 模型极易输出整句。
    @Test("系统提示写明输出格式")
    func instructionsSpecifyFormat() {
        #expect(CorrectionPrompt.instructions.contains("→"))
    }

    /// 「没有错误」的约定输出必须天然解析成空清单，
    /// 这样流水线里不需要为它写一个特判分支。
    @Test("无改动标记解析为空清单")
    func emptyMarkerParsesToNothing() {
        #expect(CorrectionEditParser.parse(CorrectionPrompt.noChangeMarker).isEmpty)
    }
}
