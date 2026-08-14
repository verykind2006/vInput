import Testing

@testable import vInput

@Suite("拼音转换")
struct PinyinTests {
    /// 这四组是 M4 的立身之本：同音错字必须判定为同音，
    /// 语义改写必须判定为不同音。数值取自真机实测。
    @Test("同音异字得到相同拼音")
    func homophonesMatch() {
        #expect(Pinyin.toneless("耀空气") == Pinyin.toneless("遥控器"))
        #expect(Pinyin.toneless("数据裤") == Pinyin.toneless("数据库"))
    }

    @Test("语义不同的改写拼音不同")
    func rewritesDiffer() {
        #expect(Pinyin.toneless("useEffect") != Pinyin.toneless("副作用钩子"))
        #expect(Pinyin.toneless("那我明天再看看吧") != Pinyin.toneless("明日再议"))
    }

    /// 声调必须忽略：同音错字绝大多数就是声调差（yào/yáo），
    /// 要求声调一致会把最该修的那一类全部拦掉。
    @Test("忽略声调")
    func ignoresTones() {
        #expect(Pinyin.toneless("耀") == "yao")
        #expect(Pinyin.toneless("遥") == "yao")
    }

    /// 拉丁字母原样穿过转换。因此 useEffect 与 useState
    /// 靠同一套比对即可区分，无需为非汉字另设规则。
    @Test("拉丁字母与数字原样保留")
    func latinPassesThrough() {
        #expect(Pinyin.toneless("useState") == "usestate")
        #expect(Pinyin.toneless("useEffect") != Pinyin.toneless("useState"))
        #expect(Pinyin.toneless("iOS 26") == "ios 26")
    }

    @Test("中英混排各自处理")
    func mixedScript() {
        #expect(Pinyin.toneless("mix中英wen") == "mix zhong ying wen")
    }

    /// 记录 ICU 的实际行为，而非我们期望的行为。
    ///
    /// Mandarin-Latin 规则集顺带做标点归一化：全角句号「。」转成半角
    /// 「.」，而全角逗号「，」不变——不对称，但那是 ICU 的既定行为。
    /// 写死在这里是为了让它日后若改变能被立刻发现。
    @Test("空串与纯标点")
    func degenerateInputs() {
        #expect(Pinyin.toneless("") == "")
        #expect(Pinyin.toneless("，。") == "，.")
    }

    /// 标点归一化不影响闸门，因为比较的两侧走同一个函数，
    /// 同样的归一化对双方同时生效。这条性质才是闸门真正依赖的东西。
    @Test("标点归一化不影响同音判定")
    func punctuationNormalizationIsHarmless() {
        #expect(Pinyin.toneless("耀空气。") == Pinyin.toneless("遥控器。"))
        #expect(Pinyin.toneless("在，") == Pinyin.toneless("再，"))
    }
}
