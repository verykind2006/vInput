import Testing

@testable import vInput

@Suite("拼音闸门")
struct CorrectionGateTests {
    @Test("同音替换放行")
    func allowsHomophones() {
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "耀空气", replacement: "遥控器")))
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "数据裤", replacement: "数据库")))
    }

    /// 这条是闸门存在的全部理由：模型「好心」把术语翻译成中文，
    /// 或自作主张重写句子，都必须被拦下。
    @Test("异音替换拦下")
    func rejectsRewrites() {
        #expect(!CorrectionGate.allows(
            CorrectionEdit(original: "useEffect", replacement: "副作用钩子")))
        #expect(!CorrectionGate.allows(
            CorrectionEdit(original: "那我明天再看看吧", replacement: "明日再议")))
    }

    /// 英文标识符之间的替换必须拦下：它们拼音转换后都是原样，
    /// 靠字面即可区分，不需要额外规则。
    @Test("英文标识符之间不得互换")
    func rejectsIdentifierSwaps() {
        #expect(!CorrectionGate.allows(
            CorrectionEdit(original: "useState", replacement: "useEffect")))
    }

    @Test("声调差异不影响放行")
    func toneDifferenceAllowed() {
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "在", replacement: "再")))
        #expect(CorrectionGate.allows(
            CorrectionEdit(original: "他", replacement: "她")))
    }

    @Test("增删字数导致读音不同，拦下")
    func lengthChangeRejected() {
        #expect(!CorrectionGate.allows(
            CorrectionEdit(original: "遥控器", replacement: "蓝牙遥控器")))
    }
}
