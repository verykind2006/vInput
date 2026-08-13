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

    @Test("结尾独立的谢谢观看会被删——真机验收中它反复作为幻觉出现")
    func removesTrailingFiller() {
        // 推翻了最初「用户可能真的这么说」的判断：实际使用中它作为幻觉
        // 出现的频率远高于用户真说的频率。
        #expect(TranscriptCleaner.clean("今天下午三点开会。谢谢观看") == "今天下午三点开会。")
        // 连接用的逗号随幻觉一起删掉，句末标点则保留
        #expect(TranscriptCleaner.clean("说了一些话，谢谢大家观看。") == "说了一些话")
        #expect(TranscriptCleaner.clean("正文内容 感谢观看") == "正文内容")
    }

    @Test("句中出现的谢谢观看不被误删")
    func keepsFillerMidSentence() {
        // 只删结尾独立成句的，句中出现一律保留
        let text = "谢谢观看大家的支持我很感动"
        #expect(TranscriptCleaner.clean(text) == text)
    }

    @Test("谢谢大家同样作为结尾幻觉被删")
    func removesTrailingThanksEveryone() {
        // 真机反馈：结尾冒出「谢谢大家」。它比「谢谢观看」更可能是真话，
        // 但实测作为幻觉出现的频率明显更高。主防线是分段级的无语音概率
        // 过滤，这里是兜底。
        #expect(TranscriptCleaner.clean("这次测试结果比较满意。谢谢大家") == "这次测试结果比较满意。")
        #expect(TranscriptCleaner.clean("正文内容，谢谢大家。") == "正文内容")
    }

    @Test("长短语优先匹配，不会截半")
    func longestPhraseWins() {
        // 若「谢谢大家」排在「谢谢大家观看」之前，会留下孤零零的「观看」
        #expect(TranscriptCleaner.clean("正文。谢谢大家观看") == "正文。")
        #expect(TranscriptCleaner.clean("正文。谢谢大家收看") == "正文。")
    }

    @Test("整段就是幻觉套话时返回空")
    func fillerOnlyYieldsEmpty() {
        #expect(TranscriptCleaner.clean("谢谢观看") == "")
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
