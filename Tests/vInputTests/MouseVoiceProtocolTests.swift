import Foundation
import Testing

@testable import vInput

@Suite("鼠标语音协议")
struct MouseVoiceProtocolTests {

    /// 真机抓包里的一帧（`MouseDecode/capture.log` 第 556 行），逐字节照抄。
    private func frame(code: UInt8) -> [UInt8] {
        [0x0A, 0x77, 0xFF, 0x34, 0x1B, code, 0x0A, 0x06, 0x07, 0x09,
         0xC9, 0x00, 0xA9, 0x10, 0x04, 0xC5, 0x44]
    }

    // MARK: - 帧解析

    @Test("解析真机抓到的语音键开始帧")
    func parsesRealStartFrame() {
        let parsed = MouseVoiceProtocol.parseControlFrame(Data(frame(code: 0x21)))
        #expect(parsed?.code == 0x21)
        #expect(parsed?.address == [0xC9, 0x00, 0xA9, 0x10, 0x04, 0xC5])
    }

    @Test("抓包里出现过的七种码全部解得出")
    func parsesEveryObservedCode() {
        for code: UInt8 in [0x51, 0x21, 0x22, 0x23, 0x24, 0x27, 0x28] {
            #expect(MouseVoiceProtocol.parseControlFrame(Data(frame(code: code)))?.code == code)
        }
    }

    @Test("长度不对的包不是控制帧")
    func rejectsWrongLength() {
        #expect(MouseVoiceProtocol.parseControlFrame(Data(frame(code: 0x21).dropLast())) == nil)
        #expect(MouseVoiceProtocol.parseControlFrame(Data(count: 128)) == nil)
        #expect(MouseVoiceProtocol.parseControlFrame(Data()) == nil)
    }

    /// 固定字节对不上意味着固件换了协议。此时把第 6 字节当控制码是在猜，
    /// 而猜错的后果正是「凭空多一个没人想要的会话」。
    @Test("前缀被改一位就不认")
    func rejectsBadPrefix() {
        var bytes = frame(code: 0x21)
        bytes[0] = 0x0B
        #expect(MouseVoiceProtocol.parseControlFrame(Data(bytes)) == nil)
    }

    @Test("中段固定字节被改一位就不认")
    func rejectsBadInfix() {
        var bytes = frame(code: 0x21)
        bytes[8] = 0x00
        #expect(MouseVoiceProtocol.parseControlFrame(Data(bytes)) == nil)
    }

    @Test("结尾字节被改一位就不认")
    func rejectsBadSuffix() {
        var bytes = frame(code: 0x21)
        bytes[16] = 0x45
        #expect(MouseVoiceProtocol.parseControlFrame(Data(bytes)) == nil)
    }

    /// 抓包里帧内地址是 `C9 00 …`，而系统面板显示 `C9:01:…`——第二字节
    /// 对不上。在查清它是什么之前不能拿它当判据。
    @Test("地址字节不参与校验")
    func addressIsNotValidated() {
        var bytes = frame(code: 0x21)
        bytes[11] = 0x01
        let parsed = MouseVoiceProtocol.parseControlFrame(Data(bytes))
        #expect(parsed?.code == 0x21)
        #expect(parsed?.address == [0xC9, 0x01, 0xA9, 0x10, 0x04, 0xC5])
    }

    // MARK: - 控制码语义

    @Test("0x21 是语音键开始")
    func voiceStartCode() {
        #expect(MouseVoiceProtocol.classify(code: 0x21) == .voiceStart)
    }

    /// 0x51 是奇数，但按「奇数即开始」处理会让每次按键多开一个空会话。
    /// 抓包证据：3/3 次 0x51 之后 0.31 秒必跟 0x21，中间零个音频包。
    @Test("0x51 只是准备信号，不是开始码")
    func wakeCodeIsNotStart() {
        #expect(MouseVoiceProtocol.classify(code: 0x51) == .wake)
    }

    @Test("0x31 单独成一档——没有配对的结束码")
    func unpairedStartCode() {
        #expect(MouseVoiceProtocol.classify(code: 0x31) == .unpairedStart)
    }

    @Test("其余奇数是开始码")
    func otherOddCodesAreStarts() {
        #expect(MouseVoiceProtocol.classify(code: 0x23) == .otherStart(0x23))
        #expect(MouseVoiceProtocol.classify(code: 0x27) == .otherStart(0x27))
    }

    @Test("偶数是结束码")
    func evenCodesAreStops() {
        #expect(MouseVoiceProtocol.classify(code: 0x22) == .stop(0x22))
        #expect(MouseVoiceProtocol.classify(code: 0x24) == .stop(0x24))
        #expect(MouseVoiceProtocol.classify(code: 0x28) == .stop(0x28))
    }

    // MARK: - 长度分流

    @Test("控制帧与音频包的长度不重合")
    func lengthsAreDistinct() {
        // 两者复用同一个特征，长度是唯一的分流依据——相等就没法分了。
        #expect(MouseVoiceProtocol.controlFrameLength != MouseVoiceProtocol.audioPacketLength)
        // 128 字节 = 4 个 32 字节 SBC 帧
        #expect(MouseVoiceProtocol.audioPacketLength % 32 == 0)
    }
}

@Suite("鼠标目标匹配与门控")
struct MouseTargetMatcherTests {

    @Test("按名字子串匹配目标")
    func matchesTargetBySubstring() {
        #expect(MouseTargetMatcher.isTarget(name: "iMouse", target: "iMouse"))
        #expect(MouseTargetMatcher.isTarget(name: "iMouse Pro", target: "iMouse"))
        #expect(MouseTargetMatcher.isTarget(name: "IMOUSE", target: "iMouse"))
    }

    @Test("不匹配的设备名一律拒绝")
    func rejectsOtherNames() {
        #expect(!MouseTargetMatcher.isTarget(name: "Magic Mouse", target: "iMouse"))
        #expect(!MouseTargetMatcher.isTarget(name: nil, target: "iMouse"))
        #expect(!MouseTargetMatcher.isTarget(name: "", target: "iMouse"))
    }

    /// 用户每天用 RC003 听写。禁止名单先于目标名判断——哪怕有人把
    /// VINPUT_MOUSE_NAME 配成遥控器的名字，也绝不能连上去。
    @Test("遥控器进禁止名单，配成它的名字也连不上")
    func neverConnectsToRemote() {
        #expect(MouseTargetMatcher.isForbidden(name: "MI RC"))
        #expect(MouseTargetMatcher.isForbidden(name: "小米蓝牙语音遥控器"))
        #expect(!MouseTargetMatcher.isTarget(name: "MI RC", target: "MI RC"))
        #expect(!MouseTargetMatcher.isTarget(name: "mi rc", target: "mi"))
    }

    /// 空目标名会让「包含」匹配所有设备，等于取消了「只连 iMouse」。
    @Test("空目标名不匹配任何设备")
    func emptyTargetMatchesNothing() {
        #expect(!MouseTargetMatcher.isTarget(name: "iMouse", target: ""))
        #expect(!MouseTargetMatcher.isTarget(name: "iMouse", target: "   "))
    }

    @Test("默认启用，只有显式 VINPUT_MOUSE=0 才关")
    func enabledByDefault() {
        #expect(MouseVoiceGate.isEnabled(environment: [:]))
        #expect(MouseVoiceGate.isEnabled(environment: ["VINPUT_MOUSE": "1"]))
        #expect(!MouseVoiceGate.isEnabled(environment: ["VINPUT_MOUSE": "0"]))
    }

    @Test("目标名可用环境变量覆盖，空白值当作没配")
    func targetNameOverride() {
        #expect(MouseVoiceGate.targetName(environment: [:]) == "iMouse")
        #expect(MouseVoiceGate.targetName(environment: ["VINPUT_MOUSE_NAME": "vMouse"]) == "vMouse")
        #expect(MouseVoiceGate.targetName(environment: ["VINPUT_MOUSE_NAME": "  "]) == "iMouse")
    }

    /// 两个 CBCentralManager 抢同一台外设会互相踢掉连接。
    /// 扫描诊断只在有人专门查问题时才开着，让它优先。
    @Test("BLE 扫描诊断开着时不拉起鼠标桥")
    func bleScanTakesPrecedence() {
        #expect(MouseVoiceGate.shouldStart(mouseEnabled: true, bleScanEnabled: false))
        #expect(!MouseVoiceGate.shouldStart(mouseEnabled: true, bleScanEnabled: true))
        #expect(!MouseVoiceGate.shouldStart(mouseEnabled: false, bleScanEnabled: false))
    }
}
