import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing

@testable import vInput

/// 遥控器菜单键 → Command+Tab（2026-08-21 用户提的：「小米遥控器上还有多余的
/// 按键，其中有一个键，我想让它按下去之后，起到 Command + Tab 的效果。」
/// 语义当天确认：**按一下切到上一个应用**，不是按住 Cmd 循环选择）。
///
/// 这个键与「·」键同型：系统会真的投递它（用户看到的是弹出右键菜单），
/// 所以必须**两件事都做**——发 Command+Tab ＋ 吞掉原始按键。
///
/// **测得到 / 测不到的分界（本套的重点）：**
/// - 测得到：usage 认得对不对、分派接没接上、听写守卫、吞键状态机、
///   两个键之间不串、几个常量引对没有；
/// - **测不到：Command+Tab 到底切不切得动应用。** 注入 CGEvent 要辅助功能
///   授权（TCC 绑 app bundle，测试进程拿不到），而「应用切没切」只有真机
///   能看。`SystemKeyPoster.appSwitchTap` 那一层的选择因此是**未验证**的，
///   下面只钉住「它现在是哪一层」，让真机说要换时改一行即可。
@Suite("遥控器菜单键映射 Command+Tab")
struct AppSwitchKeyTests {
    /// 0x65 写死钉住——它是真机按出来的数，不是猜的。
    ///
    /// 2026-08-22 18:26–18:27 用户为找这个键连按了十下，日志逐行记下
    /// `遥控器按键 usage=0x65`（18:26:28.413 起，至 18:27:10.056）。
    /// HID 键盘页里 0x65 是 Keyboard Application，也就是「菜单键」。
    @Test("菜单键的 usage 是 0x65")
    func contextMenuUsageIsPinned() {
        #expect(HIDReportParser.contextMenuButtonUsage == 0x65)
    }

    /// 它必须与另外三个已映射的 usage 都不一样，否则按一个键会触发两路。
    @Test("菜单键的 usage 不与已映射的其他键重合")
    func contextMenuUsageIsDistinct() {
        let others: Set<UInt16> = [
            HIDReportParser.backButtonUsage,
            HIDReportParser.powerButtonUsage,
            HIDReportParser.graveButtonUsage,
        ]
        #expect(!others.contains(HIDReportParser.contextMenuButtonUsage),
                "菜单键的 usage 撞上了别的键，按一下会触发两路")
    }

    @Test("菜单键按下沿被检测到")
    func contextMenuPressDetected() {
        #expect(RemoteHIDListener.didPress(
            usage: HIDReportParser.contextMenuButtonUsage, previous: [], current: [0x65]
        ))
    }

    /// **听写进行中忽略。** 说到一半突然切走应用，注入目标就变了——转写结果
    /// 会落到刚切过去的那个窗口里，而不是用户看着的那个。
    @Test("空闲时发 Command+Tab，听写中忽略")
    func appSwitchOnlyWhenIdle() {
        #expect(AppModel.contextMenuKeyPostsAppSwitch(dictationIdle: true))
        #expect(!AppModel.contextMenuKeyPostsAppSwitch(dictationIdle: false))
    }

    /// **原先是推断，2026-08-22 真机验收确认对了。**
    /// usage 0x65 = Keyboard Application = PC 键盘的菜单键，用户按下时看到的
    /// 现象是弹出右键菜单，而 macOS 把这件事绑在 `kVK_ContextualMenu` 上。
    /// 真机上按下菜单键既切了应用、右键菜单也不再弹出——说明吞的正是它。
    ///
    /// 这条断言守的仍然只是「有没有引错常量」——「110 这个数对不对」在
    /// 进程内证不了，同 `SystemKeyPoster.spaceKey` 那条的处境。
    @Test("菜单键的虚拟键码引的是 kVK_ContextualMenu")
    func contextualMenuKeyCodeIsPinned() {
        #expect(RemoteEchoSwallower.Key.contextualMenu.keyCode == Int64(kVK_ContextualMenu))
        #expect(RemoteEchoSwallower.Key.contextualMenu.keyCode == 110)
    }

    /// 两个键的键码必须不同，否则一个键的武装会吞掉另一个键的回声。
    @Test("两个回声键的键码互不相同")
    func echoKeyCodesAreDistinct() {
        let codes = RemoteEchoSwallower.Key.allCases.map(\.keyCode)
        #expect(Set(codes).count == codes.count, "两个键共用了同一个键码：\(codes)")
    }

    /// 日志里得分得清是哪个键——两条日志同形的话，真机验收时读不出来。
    @Test("两个回声键的日志名互不相同且非空")
    func echoKeyLabelsAreDistinct() {
        let labels = RemoteEchoSwallower.Key.allCases.map(\.label)
        #expect(Set(labels).count == labels.count, "两个键的日志名一样：\(labels)")
        #expect(labels.allSatisfy { !$0.isEmpty })
    }

    /// Command+Tab 的两个键码。同「引对常量」那条的道理。
    @Test("Command+Tab 引对了两个 Carbon 常量")
    func appSwitchKeyCodesArePinned() {
        #expect(SystemKeyPoster.tabKey == 48)
        #expect(SystemKeyPoster.tabKey == CGKeyCode(kVK_Tab))
        #expect(SystemKeyPoster.commandKey == 55)
        #expect(SystemKeyPoster.commandKey == CGKeyCode(kVK_Command))
    }

    /// **2026-08-22 真机验收：这一层是对的。**
    ///
    /// Cmd+Tab 由 WindowServer 在比前台应用更高的层次上截获，普通按键走的
    /// `.cgSessionEventTap` 到不到得了它当时是个未知数，所以这一路走
    /// `.cghidEventTap`。真机上短按确实切到了上一个应用——注入这条链通了。
    ///
    /// 同时钉住另外三个键**没有**被顺手改层——它们那条路也是真机验过的。
    @Test("Command+Tab 走 HID 层，其余三个键仍走会话层")
    func tapLayersArePinned() {
        #expect(SystemKeyPoster.appSwitchTap == .cghidEventTap,
                "这一层 2026-08-22 真机验过是对的，别改")
        #expect(SystemKeyPoster.defaultTap == .cgSessionEventTap,
                "回车 / 退格 / 空格三条是真机验过的，不该被 Command+Tab 那一路带着改层")
    }
}

/// 菜单键这一路的吞键：与「·」键共用同一个状态机，重点在**两个键不能串**。
@Suite("菜单键的回声吞键")
struct AppSwitchKeySwallowTests {
    static let base = Date(timeIntervalSinceReferenceDate: 0)
    static let menu = RemoteEchoSwallower.Key.contextualMenu.keyCode
    static let grave = RemoteEchoSwallower.Key.grave.keyCode

    static func armed(
        _ key: RemoteEchoSwallower.Key, at offset: TimeInterval = 0
    ) -> RemoteEchoSwallower.State {
        RemoteEchoSwallower.State(
            armed: key, armedAt: base.addingTimeInterval(offset), awaitingKeyUpFor: nil)
    }

    static func decide(
        keyCode: Int64,
        isKeyDown: Bool = true,
        at offset: TimeInterval,
        state: RemoteEchoSwallower.State
    ) -> RemoteEchoSwallower.Decision {
        RemoteEchoSwallower.decide(
            keyCode: keyCode, isKeyDown: isKeyDown,
            now: base.addingTimeInterval(offset), state: state)
    }

    /// 不吞的后果是「切了应用」和「弹出右键菜单」同时发生。
    @Test("窗口内的菜单键按下被吞掉")
    func swallowsMenuKeyInsideWindow() {
        let decision = Self.decide(keyCode: Self.menu, at: 0.002, state: Self.armed(.contextualMenu))
        #expect(decision.swallow, "菜单键的回声没被吞，用户会同时看到切换和右键菜单")
        #expect(decision.swallowed == .contextualMenu, "吞掉的键没记对，日志会写成「·」键")
        #expect(decision.state.awaitingKeyUpFor == .contextualMenu)
    }

    /// 没武装的菜单键放行——虽然 Mac 键盘上多半没有这个键，但外接 PC 键盘有。
    @Test("没有武装时菜单键照常放行")
    func passesMenuKeyWhenNotArmed() {
        let decision = Self.decide(keyCode: Self.menu, at: 0, state: RemoteEchoSwallower.State())
        #expect(!decision.swallow, "无差别吞掉了菜单键——外接 PC 键盘的菜单键会失灵")
    }

    @Test("超出窗口的菜单键放行")
    func passesMenuKeyAfterWindow() {
        let decision = Self.decide(keyCode: Self.menu, at: 0.051, state: Self.armed(.contextualMenu))
        #expect(!decision.swallow)
    }

    /// **两个键不能串（一）：** 为菜单键武装时，用户自己按的反引号必须放行。
    @Test("为菜单键武装时不吞「·」")
    func menuArmDoesNotSwallowGrave() {
        let decision = Self.decide(keyCode: Self.grave, at: 0.002, state: Self.armed(.contextualMenu))
        #expect(!decision.swallow, "为菜单键武装，却把用户的反引号吞了")
        #expect(decision.observedWhileArmed == .contextualMenu, "该记一条诊断，说明当时武装的是菜单键")
    }

    /// **两个键不能串（二）：** 为「·」武装时不吞菜单键。
    @Test("为「·」武装时不吞菜单键")
    func graveArmDoesNotSwallowMenu() {
        let decision = Self.decide(keyCode: Self.menu, at: 0.002, state: Self.armed(.grave))
        #expect(!decision.swallow, "为「·」武装，却把菜单键吞了")
        #expect(decision.observedWhileArmed == .grave)
    }

    /// **两个键不能串（三）：** 松开沿认键码。吞过「·」的按下沿之后，
    /// 菜单键的松开沿不该被顺手吞掉。
    @Test("松开沿只吞吞过按下沿的那个键")
    func keyUpMatchesTheSwallowedKey() {
        let down = Self.decide(keyCode: Self.grave, at: 0.002, state: Self.armed(.grave))
        #expect(down.state.awaitingKeyUpFor == .grave)
        let wrongUp = Self.decide(
            keyCode: Self.menu, isKeyDown: false, at: 0.01, state: down.state)
        #expect(!wrongUp.swallow, "吞了另一个键的松开事件")
        #expect(wrongUp.state.awaitingKeyUpFor == .grave, "误吞还把待吞的松开沿清掉了")
        let rightUp = Self.decide(
            keyCode: Self.grave, isKeyDown: false, at: 0.02, state: down.state)
        #expect(rightUp.swallow)
    }

    /// 菜单键这一路会看到**我们自己注入的 Tab**（键码 48）穿过这个 tap。
    /// 它必须原样放行，否则功能会把自己发出去的 Command+Tab 吃掉，
    /// 表现是「按键完全没反应」。
    ///
    /// 顺带说明真机日志会多出的那一行：`遥控器菜单键的武装窗口内出现
    /// keyCode=48，不是 110，未吞`——那是**预期噪声**，同时也是「注入确实
    /// 走到了事件层」的证据。若真机日志里除了 48 还有另一个键码，那个就是
    /// 菜单键的真实虚拟键码，改 `Key.contextualMenu.keyCode` 即可。
    @Test("我们注入的 Tab 不会被自己吞掉")
    func doesNotSwallowItsOwnTab() {
        let decision = Self.decide(
            keyCode: Int64(kVK_Tab), at: 0.001, state: Self.armed(.contextualMenu))
        #expect(!decision.swallow, "自己注入的 Tab 被自己的 tap 吞了，应用切换会失效")
        #expect(decision.observedWhileArmed == .contextualMenu, "诊断口没记下这一行")
    }

    /// 武装期间除菜单键外的所有键码一律放行且不改状态。扫 0…127。
    @Test("为菜单键武装期间，其余键码一律放行且不改状态")
    func neverTouchesOtherKeyCodesWhileMenuArmed() {
        var swallowed: [Int64] = []
        var mutated: [Int64] = []
        let state = Self.armed(.contextualMenu)
        for code in Int64(0)...Int64(127) where code != Self.menu {
            for isDown in [true, false] {
                let decision = Self.decide(keyCode: code, isKeyDown: isDown, at: 0.002, state: state)
                if decision.swallow { swallowed.append(code) }
                if decision.state != state { mutated.append(code) }
            }
        }
        #expect(swallowed.isEmpty, "这些键码在武装期间被吞掉了：\(swallowed)")
        #expect(mutated.isEmpty, "这些键码改动了吞键状态：\(mutated)")
    }

    /// 后一次武装覆盖前一次：用户先按「·」再按菜单键，第二次武装之后
    /// 该吞的是菜单键。
    ///
    /// 走的是实例入口（`arm`/`consume`）而不是纯函数，为的是连「`arm` 有没有
    /// 真的把 `armed` 换掉」一起测到；实例是 `@MainActor` 的，所以这条单独标注。
    /// **装的是 `noTapInstaller`**：测试进程绝不装真 tap（四份 SIGSEGV 报告）。
    @MainActor
    @Test("再武装一次会换掉上一次武装的键")
    func rearmingReplacesTheArmedKey() {
        let swallower = RemoteEchoSwallower(installer: RemoteEchoSwallower.noTapInstaller)
        let now = Date()
        swallower.arm(.grave, now: now)
        swallower.arm(.contextualMenu, now: now)
        #expect(!swallower.consume(
            keyCode: Self.grave, isKeyDown: true, now: now.addingTimeInterval(0.002)).swallow,
                "第二次武装没有覆盖第一次，「·」还在被吞")
        #expect(swallower.consume(
            keyCode: Self.menu, isKeyDown: true, now: now.addingTimeInterval(0.003)).swallow)
    }
}

/// HID 报文 → 菜单键回调的分派。真 HID 设备进不了测试进程，所以直接喂报文。
@MainActor
@Suite("菜单键的 HID 分派")
struct AppSwitchKeyDispatchTests {
    static func report(_ usages: [UInt16]) -> Data {
        var bytes: [UInt8] = []
        for usage in usages {
            bytes.append(UInt8(usage & 0xFF))
            bytes.append(UInt8(usage >> 8))
        }
        return Data(bytes.isEmpty ? [0x00, 0x00] : bytes)
    }

    static func fire(_ frames: [[UInt16]])
        -> (cancel: Int, power: Int, grave: Int, menu: Int) {
        let listener = RemoteHIDListener()
        var cancel = 0, power = 0, grave = 0, menu = 0
        listener.onCancelPressed = { cancel += 1 }
        listener.onPowerPressed = { power += 1 }
        listener.onGravePressed = { grave += 1 }
        listener.onContextMenuPressed = { menu += 1 }
        for frame in frames {
            listener.handleReport(reportID: 1, data: report(frame))
        }
        return (cancel, power, grave, menu)
    }

    @Test("0x65 触发菜单键回调，且不误触另外三个")
    func menuDispatch() {
        let counts = Self.fire([[0x65], []])
        #expect(counts.menu == 1, "0x65 没有触发 onContextMenuPressed")
        #expect(counts.cancel == 0 && counts.power == 0 && counts.grave == 0,
                "0x65 误触了别的回调")
    }

    /// 按住不放只算一次——按下沿判断真的接在了这一路上。
    @Test("按住菜单键不放只触发一次")
    func menuOnlyOnPressEdge() {
        let counts = Self.fire([[0x65], [0x65], [0x65], [], [0x65]])
        #expect(counts.menu == 2, "按下沿判断没接上，按住期间重复触发了")
    }

    /// 另外三个已映射的键不该触发菜单键那一路。
    @Test("其他已映射按键不触发菜单键回调")
    func otherKeysDoNotDispatchMenu() {
        let counts = Self.fire([[0x35, 0x66, 0xF1], []])
        #expect(counts.menu == 0, "别的键误触了 onContextMenuPressed")
        #expect(counts.grave == 1 && counts.power == 1 && counts.cancel == 1)
    }

    /// `0x4A`（Home）2026-08-22 同一轮里也按到了，但**没有映射**。
    /// 它误触任何一路都是 bug——这条同时把「下一个可用空键」记在测试里。
    @Test("Home 键 0x4A 目前不触发任何映射")
    func homeKeyIsUnmapped() {
        let counts = Self.fire([[0x4A], []])
        #expect(counts.cancel == 0 && counts.power == 0 && counts.grave == 0 && counts.menu == 0,
                "0x4A 现在还没有映射，它触发了某一路")
    }
}
