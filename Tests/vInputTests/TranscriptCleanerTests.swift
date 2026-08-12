import Testing
@testable import vInput

@Suite("TranscriptCleaner 幻觉尾巴过滤")
struct TranscriptCleanerTests {

    // MARK: - 必须删掉的

    @Test("删掉括号里的字幕署名")
    func removesParentheticalSubtitleCredit() {
        // 这是真机验收中实际出现的输出
        let actual = "今天下午三点我们讨论一下发版计划看看相关的计划是否可行( 字幕:J Chong )"
        #expect(TranscriptCleaner.clean(actual) == "今天下午三点我们讨论一下发版计划看看相关的计划是否可行")
    }

    @Test("全角括号的字幕署名同样删掉")
    func removesFullWidthParenthetical() {
        #expect(TranscriptCleaner.clean("说了一些话（字幕：张三）") == "说了一些话")
    }

    @Test("方括号与中文书名号形式")
    func removesBracketForms() {
        #expect(TranscriptCleaner.clean("说了一些话[字幕由 Amara.org 社区提供]") == "说了一些话")
        #expect(TranscriptCleaner.clean("说了一些话【中文字幕 by 李四】") == "说了一些话")
    }

    @Test("不带括号的结尾字幕署名")
    func removesTrailingCreditWithoutBrackets() {
        #expect(TranscriptCleaner.clean("说了一些话 字幕:王五") == "说了一些话")
        #expect(TranscriptCleaner.clean("说了一些话 字幕：王五") == "说了一些话")
    }

    @Test("英文 subtitles by 形式")
    func removesEnglishSubtitleCredit() {
        #expect(TranscriptCleaner.clean("some words (Subtitles by the Amara.org community)") == "some words")
    }

    @Test("删除后清理残留的首尾空白")
    func trimsAfterRemoval() {
        #expect(TranscriptCleaner.clean("说了一些话   ( 字幕:J Chong )  ") == "说了一些话")
    }

    // MARK: - 绝对不能删的（保守性）

    @Test("用户真说的括号内容原样保留")
    func keepsLegitimateParentheses() {
        let text = "这个函数（就是那个处理登录的）需要改一下"
        #expect(TranscriptCleaner.clean(text) == text)
    }

    @Test("句中出现的字幕二字不被误删")
    func keepsSubtitleWordInSentence() {
        let text = "帮我把这个视频的字幕文件转成 srt 格式"
        #expect(TranscriptCleaner.clean(text) == text)
    }

    @Test("谢谢观看这类词不删——用户可能真的这么说")
    func keepsAmbiguousPhrases() {
        let text = "今天就讲到这里谢谢观看"
        #expect(TranscriptCleaner.clean(text) == text)
    }

    @Test("普通文本完全不受影响")
    func plainTextUnchanged() {
        let text = "我们来测试一下这个功能这个功能跑了一下午基本的功能框架就已经出来了"
        #expect(TranscriptCleaner.clean(text) == text)
    }

    @Test("空字符串安全返回")
    func emptyIsSafe() {
        #expect(TranscriptCleaner.clean("") == "")
    }

    @Test("整段都是幻觉时返回空串而非崩溃")
    func allHallucinationYieldsEmpty() {
        #expect(TranscriptCleaner.clean("( 字幕:J Chong )") == "")
    }
}
