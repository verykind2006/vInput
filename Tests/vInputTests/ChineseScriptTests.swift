import Testing
@testable import vInput

@Suite("ChineseScript 繁简转换")
struct ChineseScriptTests {
    @Test("繁体转成简体")
    func convertsTraditionalToSimplified() {
        #expect(ChineseScript.toSimplified("測試") == "测试")
        #expect(ChineseScript.toSimplified("發佈計劃") == "发布计划")
        #expect(ChineseScript.toSimplified("這個") == "这个")
    }

    @Test("已是简体的文本不被改动")
    func leavesSimplifiedUntouched() {
        let text = "已经是简体的句子不该被改坏"
        #expect(ChineseScript.toSimplified(text) == text)
    }

    @Test("英文与标识符原样保留")
    func preservesLatinIdentifiers() {
        let text = "把 useEffect 裏的 dependency array 改一下"
        let result = ChineseScript.toSimplified(text)
        #expect(result.contains("useEffect"))
        #expect(result.contains("dependency array"))
        #expect(result == "把 useEffect 里的 dependency array 改一下")
    }

    @Test("空字符串安全返回")
    func emptyStringIsSafe() {
        #expect(ChineseScript.toSimplified("") == "")
    }

    @Test("纯符号与数字不受影响")
    func punctuationAndDigitsUnchanged() {
        let text = "12345 ,.!?  —— @#$"
        #expect(ChineseScript.toSimplified(text) == text)
    }

    @Test("Task 2 spike 的真实输出能被正确转换")
    func convertsRealSpikeOutput() {
        // 这是 base 模型在 Task 2 验证中的实际输出。
        // 注意「寒暑」「樹足」是同音错字，不是繁简问题，
        // 转换器不负责修它们——那是模型或 M4 润色层的职责。
        let actual = "幫我把這個寒暑裏的依賴樹足改一下,然後跑一遍測試。"
        #expect(ChineseScript.toSimplified(actual) == "帮我把这个寒暑里的依赖树足改一下,然后跑一遍测试。")
    }
}
