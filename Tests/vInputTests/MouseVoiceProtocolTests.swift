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
        #expect(MouseVoiceProtocol.classify(code: 0x25) == .otherStart(0x25))
        // 0x27 已单列为回车键，见下方 MouseEnterKeyTests。
        #expect(MouseVoiceProtocol.classify(code: 0x25) == .otherStart(0x25))
    }

    @Test("偶数是结束码")
    func evenCodesAreStops() {
        #expect(MouseVoiceProtocol.classify(code: 0x22) == .stop(0x22))
        #expect(MouseVoiceProtocol.classify(code: 0x26) == .stop(0x26))
        #expect(MouseVoiceProtocol.classify(code: 0x2A) == .stop(0x2A))
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

/// 第 4 字节是电量，不是固定签名。
///
/// 最初的实现把它写进 `framePrefix`，理由是「抓包里 13/13 个控制帧逐字节
/// 相同」——**13/13 是真的，但那 13 帧全来自同一次 40 秒的抓包，电量当然
/// 没变**。同一天下午真机就推翻了它：帧变成 `0A 77 FF 28 1B 27 …`，
/// 而 `0x34` = 52 恰是上午电池特征的读数，`0x28` = 40。
///
/// 后果不是「少认一个键」，是**整个协议随电量下降而失效**，症状是所有帧
/// 突然变成「不认识的 17 字节帧」——极难往电量上想。
/// 鼠标上那个多余的按键映射成回车（用户 2026-08-18 指定）。
///
/// 实测：按一下发 `0x27`、松开发 `0x28`，两次按键完全一致
/// （日志 16:01:18 与 16:01:20）。
@Suite("鼠标的回车键")
struct MouseEnterKeyTests {
    @Test("0x27 是回车键，不是普通开始码")
    func classifiesEnterKey() {
        #expect(MouseVoiceProtocol.classify(code: 0x27) == .enterKey)
        #expect(MouseVoiceProtocol.enterKeyCode == 0x27)
    }

    /// **回车不开会话。** 它没有「按住」的语义，配对的 0x28 直接忽略——
    /// 若走 otherStart 那条路，按一下回车会开一个 30 秒上限的空会话，
    /// 期间菜单栏状态和互斥守卫都会被它占住。
    @Test("回车不开会话，只发一次按键")
    func enterDoesNotOpenSession() {
        let session = MouseVoiceSession()
        let now = Date()
        #expect(session.handleControl(code: 0x27, at: now) == [.pressEnter])
        #expect(!session.isDictating)
        // 松开码落到空闲期，什么也不做。
        #expect(session.handleControl(code: 0x28, at: now) == [])
        #expect(!session.isDictating)
    }

    /// 正在听写时按它照发——用户按它就是想换行/确认，两件事不冲突。
    @Test("听写期间按回车不打断听写")
    func enterDuringDictationKeepsSession() {
        let session = MouseVoiceSession()
        let now = Date()
        _ = session.handleControl(code: 0x21, at: now)
        #expect(session.isDictating)
        #expect(session.handleControl(code: 0x27, at: now) == [.pressEnter])
        #expect(session.isDictating, "回车不该结束听写")
    }
}

/// 第三个键刻意没有任何功能。
///
/// 用户 2026-08-18：「那个键的位置特别不好，容易误碰到，所以暂时不要让
/// 这个键有任何的功能。」
///
/// 逐动作实测：短按发单个 `0x41`（无结束码、不送音频），
/// 长按发 `0x23` → `0x24`。会话层的行为在 MouseVoiceSessionTests 里测。
@Suite("第三个键：刻意无功能")
struct MouseThirdButtonTests {
    @Test("它的四个码全部被忽略")
    func classifiesAsIgnored() {
        #expect(MouseVoiceProtocol.classify(code: 0x41) == .ignored)
        #expect(MouseVoiceProtocol.classify(code: 0x43) == .ignored)
        #expect(MouseVoiceProtocol.classify(code: 0x23) == .ignored)
        #expect(MouseVoiceProtocol.classify(code: 0x24) == .ignored)
    }
}

/// 回车键的松开码必须被忽略，不能当成结束码。
///
/// 文档一直声称「配对的 0x28 直接忽略」，但原实现只特判了 0x27，
/// 0x28 落到 default → 偶数 → `.stop` → 结束正在进行的听写。
/// **于是「按住语音键说话时按一下回车」= 说到一半被截断。**
/// 独立验收 2026-08-18 指出这个矛盾：两个既有测试恰好各覆盖一半
/// （`.idle` 下的 0x28、`.dictating` 下的 0x27），避开了这一格。
@Suite("回车键的松开码")
struct MouseEnterReleaseTests {
    @Test("0x28 被忽略，不是结束码")
    func releaseIsIgnored() {
        #expect(MouseVoiceProtocol.classify(code: 0x28) == .ignored)
        #expect(MouseVoiceProtocol.enterReleaseCode == 0x28)
    }
}

@Suite("控制帧的电量字节")
struct MouseControlFrameBatteryTests {
    private func frame(battery: UInt8, code: UInt8) -> Data {
        Data([0x0A, 0x77, 0xFF, battery, 0x1B, code,
              0x0A, 0x06, 0x07, 0x09,
              0xC9, 0x00, 0xA9, 0x10, 0x04, 0xC5, 0x44])
    }

    @Test("电量变化不影响解析——这正是当初漏掉的那一维")
    func parsesAcrossBatteryLevels() {
        for battery in [UInt8(100), 52, 40, 7, 0] {
            let parsed = MouseVoiceProtocol.parseControlFrame(frame(battery: battery, code: 0x27))
            #expect(parsed?.code == 0x27, "电量 \(battery) 时解析失败")
            #expect(parsed?.battery == Int(battery))
        }
    }

    /// 两次真机实测的原样字节。
    @Test("真机抓到的两种电量都认得")
    func parsesRealCaptures() {
        // 2026-08-18 上午，电量 52%
        let morning = Data([0x0A, 0x77, 0xFF, 0x34, 0x1B, 0x51,
                            0x0A, 0x06, 0x07, 0x09,
                            0xC9, 0x00, 0xA9, 0x10, 0x04, 0xC5, 0x44])
        #expect(MouseVoiceProtocol.parseControlFrame(morning)?.battery == 52)
        // 同日下午，电量 40%，按的是那个多余的键
        let afternoon = Data([0x0A, 0x77, 0xFF, 0x28, 0x1B, 0x27,
                              0x0A, 0x06, 0x07, 0x09,
                              0xC9, 0x00, 0xA9, 0x10, 0x04, 0xC5, 0x44])
        let parsed = MouseVoiceProtocol.parseControlFrame(afternoon)
        #expect(parsed?.code == 0x27)
        #expect(parsed?.battery == 40)
    }

    /// 放宽了一个字节就得守住边界，否则「不认识的帧」这道防线会变松。
    @Test("电量超出 0–100 一律不认")
    func rejectsImpossibleBattery() {
        #expect(MouseVoiceProtocol.parseControlFrame(frame(battery: 101, code: 0x21)) == nil)
        #expect(MouseVoiceProtocol.parseControlFrame(frame(battery: 255, code: 0x21)) == nil)
    }
}

@Suite("鼠标目标匹配与门控")
struct MouseTargetMatcherTests {

    @Test("名字必须完全相等（大小写与空白不计）")
    func matchesTargetExactly() {
        #expect(MouseTargetMatcher.isTarget(name: "iMouse", target: "iMouse"))
        #expect(MouseTargetMatcher.isTarget(name: "IMOUSE", target: "iMouse"))
        #expect(MouseTargetMatcher.isTarget(name: " iMouse ", target: "iMouse"))
    }

    /// **这条替换了原来钉住「子串匹配」的用例。**
    ///
    /// 原实现用 `contains`，理由是「广播名常带后缀（"iMouse Pro"）」。
    /// 2026-08-18 真机推翻了它：用户周围存在另一台 `iMouse2`，包含匹配把
    /// 它当成目标，桥连上陌生设备后永远停在「连接中」，而鼠标本身用得
    /// 好好的——症状与「没连上」完全不同，很难往「连错了」上想。
    ///
    /// 代价不对称：漏连自己的设备用户会立刻发现；连上别人的设备我们会
    /// 订阅它的特征、收它的字节。宁可漏，不可错。
    @Test("同前缀的别人的设备一律不连")
    func rejectsSimilarlyNamedDevices() {
        #expect(!MouseTargetMatcher.isTarget(name: "iMouse2", target: "iMouse"))
        #expect(!MouseTargetMatcher.isTarget(name: "iMouse Pro", target: "iMouse"))
        #expect(!MouseTargetMatcher.isTarget(name: "iMouseX", target: "iMouse"))
        // 反向也不行：目标名比设备名长时同样不该匹配。
        #expect(!MouseTargetMatcher.isTarget(name: "iMouse", target: "iMouse2"))
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

    // MARK: - 不认识的帧的日志限流

    /// **失败模式是静默的。** 原实现是「最多 5 条，永不重置」：固件升级或
    /// 换一支设备之后帧解析可能全部失败，而日志只在最开始说 5 次，之后
    /// 彻底安静——排查的人看到的是「日志里什么都没有」，最容易得出的结论
    /// 恰恰是「鼠标没连上 / 没按到键」，与真相（每秒几十帧全解不开）相反。
    /// 独立验收 2026-08-18 指出（P7）。
    @Test("同一个窗口里最多打前几条")
    func limitsBurstWithinWindow() {
        var log = MouseUnknownFrameLog()
        let start = Date()
        var logged = 0
        for step in 0..<50 {
            if log.record(at: start.addingTimeInterval(Double(step) * 0.03)).shouldLog {
                logged += 1
            }
        }
        #expect(logged == MouseUnknownFrameLog.burst)
    }

    /// 关键的一条：**窗口过去之后必须重新出声。**
    @Test("过了窗口重新开口，并汇总被压掉的条数")
    func resumesAfterWindow() {
        var log = MouseUnknownFrameLog()
        let start = Date()
        for step in 0..<50 {
            _ = log.record(at: start.addingTimeInterval(Double(step) * 0.03))
        }

        let next = log.record(at: start.addingTimeInterval(MouseUnknownFrameLog.window + 1))
        #expect(next.shouldLog)
        // 第一个窗口打了 burst 条，压掉 50 - burst 条，汇总里要说出来
        #expect(next.summary?.contains("\(50 - MouseUnknownFrameLog.burst)") == true)
        #expect(next.summary?.contains("51") == true)  // 累计
    }

    /// 流停了以后也要把最后一个窗口的账结掉——否则「5 条之后一片安静」
    /// 换了个形式又回来了：压掉 2000 条，然后设备不再发包，汇总永远不打。
    /// 桥每秒 tick 一次，`flush` 挂在那上面。
    @Test("流停了之后 flush 把最后一个窗口的账结掉")
    func flushReportsTrailingWindow() {
        var log = MouseUnknownFrameLog()
        let start = Date()
        for step in 0..<50 {
            _ = log.record(at: start.addingTimeInterval(Double(step) * 0.03))
        }

        let summary = log.flush(at: start.addingTimeInterval(MouseUnknownFrameLog.window + 1))
        #expect(summary != nil)
        // 结过账就不再重复报
        #expect(log.flush(at: start.addingTimeInterval(MouseUnknownFrameLog.window * 3)) == nil)
    }

    /// 没有被压掉任何东西时不该产生噪音行。
    @Test("没压掉东西就不产生汇总行")
    func quietWhenNothingSuppressed() {
        var log = MouseUnknownFrameLog()
        let start = Date()
        for step in 0..<MouseUnknownFrameLog.burst {
            #expect(log.record(at: start.addingTimeInterval(Double(step))).summary == nil)
        }
        #expect(log.flush(at: start.addingTimeInterval(MouseUnknownFrameLog.window * 2)) == nil)
    }
}
