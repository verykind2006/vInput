import Foundation

//  蓝牙鼠标（iMouse，Freqchip 芯片）的语音协议——纯逻辑层。
//
//  这一层不碰 CoreBluetooth 的任何运行时对象，因此全部可以在单元测试里跑。
//  外壳在 `MouseBluetoothBridge.swift`。
//
//  分层的理由与 `BLEScanReport` 那边一样，而且这里更重要：**真机验证要靠
//  用户按键**，我跑不了。帧解析、会话状态机、时长上限这些容易写错的部分
//  全放在这里由测试钉死，真机那一轮只用来验「线通不通」。
//
//  协议来源：2026-08-18 真机抓包（`MouseDecode/capture.log`，13 个控制帧、
//  583 个音频包），不是猜的。

// MARK: - 开关

/// 鼠标音频源的门控。
///
/// **默认启用**——它是产品功能（第三个音频源），不是诊断工具。
/// 留一个关掉的开关是因为它会在每次启动时连一台 BLE 设备：真出问题时
/// 用户要有办法在不改代码的前提下把它摘掉。
enum MouseVoiceGate {
    static let disableKey = "VINPUT_MOUSE"
    static let nameKey = "VINPUT_MOUSE_NAME"

    /// 目标设备默认名。来自用户实测的系统蓝牙面板：
    /// `iMouse / Address: C9:01:A9:10:04:C5 / Services: 0x400000 < BLE >`。
    static let defaultTargetName = "iMouse"

    static func isEnabled(environment: [String: String]) -> Bool {
        environment[disableKey] != "0"
    }

    /// 目标设备名。空白值当作没配——`MouseTargetMatcher` 用的是子串包含，
    /// 空串会匹配**所有**设备，等于把「只连 iMouse」这条约束悄悄取消。
    static func targetName(environment: [String: String]) -> String {
        let raw = environment[nameKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? defaultTargetName : raw
    }

    static var isEnabled: Bool { isEnabled(environment: ProcessInfo.processInfo.environment) }
    static var targetName: String { targetName(environment: ProcessInfo.processInfo.environment) }

    /// 本次启动该不该拉起鼠标桥。
    ///
    /// **BLE 扫描诊断开着时一律不拉。** 两个 `CBCentralManager` 抢同一台
    /// 外设会互相踢掉连接，而扫描器的全部目的就是连上这支鼠标看原始字节。
    /// 让诊断优先，是因为它只在 `VINPUT_BLE_SCAN=1` 时存在，那一定是有人
    /// 正坐在电脑前专门查问题。
    static func shouldStart(mouseEnabled: Bool, bleScanEnabled: Bool) -> Bool {
        mouseEnabled && !bleScanEnabled
    }
}

// MARK: - 目标匹配

/// 决定「这台外设是不是那支鼠标」。
///
/// **最重要的一条仍是不连什么**：用户每天用 RC003 遥控器听写，鼠标桥抢走
/// 它的连接等于把主功能弄坏。所以遥控器的名字进硬编码禁止名单，
/// 先于目标名判断——哪怕 `VINPUT_MOUSE_NAME` 被配成 "MI RC" 也连不上去。
/// 第二道是 identifier 排除（见 `MouseBluetoothBridge.excludedIdentifiers`），
/// 挡住「名字对不上但就是那台」的情形。
enum MouseTargetMatcher {
    static func matches(name: String?, target: String) -> Bool {
        let normalizedTarget = normalize(target)
        guard !normalizedTarget.isEmpty,
              let normalizedName = normalize(name), !normalizedName.isEmpty
        else { return false }
        // **相等，不是包含。**
        //
        // 最初写的是 `contains`，理由是「广播包里的 local name 常带后缀
        // （"iMouse Pro"），要求严格相等会在真机上白连一轮」。推理成立，
        // 现实反驳了它：2026-08-18 真机上，用户周围存在另一台名为
        // **`iMouse2`** 的设备（这类廉价外设重名极常见）。包含匹配把它
        // 当成了目标，于是桥连上一台陌生设备并永远停在「连接中」，
        // 菜单栏一直显示连接中而鼠标本身用得好好的——症状与「没连上」
        // 完全不同，很难往「连错了」上想。
        //
        // 两种错的代价不对称：漏连自己的设备，用户会立刻发现并报告；
        // **连上别人的设备，我们会订阅它的特征、收它的字节**——这既是
        // 功能故障，也是不该发生的事。所以宁可漏，不可错。
        //
        // 真遇到带后缀的名字，用 `VINPUT_MOUSE_NAME` 显式指定即可，
        // 那是一条明确的用户决定，而不是我们替他猜。
        return normalizedName == normalizedTarget
    }

    /// 禁止名单。复用 `XiaomiVoiceRemoteNameMatcher`（遥控器那份名单）——
    /// 抄一份等于让两处各自漂移，而「不能碰 RC003」是同一条约束。
    static func isForbidden(name: String?) -> Bool {
        XiaomiVoiceRemoteNameMatcher.matches(name)
    }

    static func isTarget(name: String?, target: String) -> Bool {
        !isForbidden(name: name) && matches(name: name, target: target)
    }

    private static func normalize(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - 帧

/// 通知包的类别。
enum MousePacketKind: Equatable {
    case control
    case audio
    case unknown(Int)
}

/// 一个 17 字节控制帧。
struct MouseControlFrame: Equatable {
    let code: UInt8
    /// 帧里带的电量百分比。每个控制帧都带，所以按一次键就能刷新一次，
    /// 不必单独去读电池特征。
    let battery: Int
    /// 帧里带的 6 字节地址。**只记录不校验**，理由见 `parseControlFrame`。
    let address: [UInt8]
}

/// 控制码的语义。
enum MouseControlSemantics: Equatable {
    /// `0x51`。语音键按下的**准备**信号，不开会话。
    case wake
    /// `0x21`。语音键开始——唯一会触发听写的开始码。
    case voiceStart
    /// `0x31`。长按开麦，**没有配对的结束码**。
    case unpairedStart
    /// 第三个键的各种动作。**刻意什么都不做。**
    ///
    /// 用户 2026-08-18：「那个键的位置特别不好，容易误碰到，所以暂时不要
    /// 让这个键有任何的功能。」
    ///
    /// 走 `.ignored` 而不是 `.otherStart`，是因为后者会开一个会话——即使
    /// 不听写、音频也被丢掉，长按超过 30 秒仍会撞上限、退订特征、冷却
    /// 10 秒，**鼠标停摆而用户不知道为什么**。对一个「容易误碰」的键来说，
    /// 这正是最该避免的后果。
    case ignored
    /// `0x27`。鼠标上那个多余的按键，映射成回车。
    ///
    /// **它不开任何会话**——按一下就是一次回车，没有「按住」的语义，
    /// 配对的 `0x28`（松开）直接忽略。
    case enterKey
    /// 其他奇数开始码（实测 `0x23`，鼠标上别的 AI 功能键）。
    case otherStart(UInt8)
    /// 任意偶数码 = 结束**它自己那个会话**。
    ///
    /// **不是「结束任何进行中的会话」。** 一次会话只认
    /// `MouseVoiceProtocol.pairedStop(forStart:)` 算出来的那一个码，
    /// 判在 `MouseVoiceSession.handleControl` 里（这一层没有会话状态）。
    /// 理由见那边：默认结束一切已经误伤过 `0x28` 与 `0x24` 两次。
    case stop(UInt8)
}

// MARK: - 不认识的帧的日志限流

/// 「不认识的帧」这类日志的限流器：**按时间窗，不按绝对条数。**
///
/// # 为什么不能用「最多 5 条」
///
/// 原实现是一个只增不减的计数器加 `<= 5` 的判断。它在正常情况下没问题
/// （偶尔一个杂包），但**失败模式是静默的**：固件升级或换一支同名设备之后，
/// 帧解析可能从此全部失败，而日志只在最开始说 5 次，之后彻底安静。
///
/// 排查的人这时看到的是「日志里什么都没有」，最容易得出的结论恰恰是
/// 「鼠标没连上 / 用户没按到键」——与真相（每秒几十帧全解不开）相反。
/// **一个会把人引向反方向的日志比没有日志更糟。** 独立验收 2026-08-18 指出。
///
/// # 这两个数
///
/// 每 `window` 秒最多打 `burst` 条原始内容，外加至多一条汇总。
/// 最坏情况是 6 行/分钟——用户会把整份 `vInput.log` 发回来，这个量级不会
/// 把它冲垮；而「固件换了协议」这种事持续几分钟就足够看出来了。
///
/// 上限要压的是最坏情况：**不认识的分支也接住长度不对的音频包**，
/// 而音频包是每秒 31 个（实测 31.25 包/秒）。不限流的话一分钟就是近 2000 行。
struct MouseUnknownFrameLog {
    /// 每个窗口最多打几条原始内容。
    static let burst = 5
    /// 窗口长度。
    static let window: TimeInterval = 60

    struct Decision: Equatable {
        /// 这一条的原始内容要不要写进日志。
        let shouldLog: Bool
        /// 窗口翻页时结上一窗口的账。nil = 没有被压掉的东西，不必出声。
        let summary: String?
    }

    private var windowStartedAt: Date?
    private var loggedInWindow = 0
    private var suppressedInWindow = 0
    private var total = 0

    mutating func record(at now: Date) -> Decision {
        total += 1
        var summary: String?
        if let start = windowStartedAt, now.timeIntervalSince(start) < Self.window {
            // 同一个窗口里
        } else {
            summary = closeWindow(at: now)
            windowStartedAt = now
            loggedInWindow = 0
            suppressedInWindow = 0
        }

        if loggedInWindow < Self.burst {
            loggedInWindow += 1
            return Decision(shouldLog: true, summary: summary)
        }
        suppressedInWindow += 1
        return Decision(shouldLog: false, summary: summary)
    }

    /// 流停了之后把最后一个窗口的账结掉。桥每秒 tick 一次，挂在那上面。
    ///
    /// **没有这一步，「5 条之后一片安静」会换个形式回来**：压掉两千条，
    /// 然后设备不再发包，那份汇总就永远等不到下一帧来触发。
    mutating func flush(at now: Date) -> String? {
        guard let start = windowStartedAt, now.timeIntervalSince(start) >= Self.window
        else { return nil }
        let summary = closeWindow(at: now)
        windowStartedAt = nil
        loggedInWindow = 0
        return summary
    }

    private mutating func closeWindow(at now: Date) -> String? {
        guard suppressedInWindow > 0, let start = windowStartedAt else { return nil }
        let elapsed = Int(now.timeIntervalSince(start))
        let suppressed = suppressedInWindow
        suppressedInWindow = 0
        return "不认识的帧还在持续：过去 \(elapsed) 秒里另有 \(suppressed) 条没有打印"
            + "（累计 \(total) 条）——固件或设备可能换了协议"
    }
}

/// 鼠标语音协议的常量与帧解析。
///
/// GATT：服务 `FFF1`，特征 `…CB8`（`writeWithoutResponse,write,notify`）。
/// **控制帧与音频复用同一个特征**，靠长度区分：17 字节控制、128 字节音频。
enum MouseVoiceProtocol {
    /// 语音服务。
    static let serviceUUID = "FFF1"
    /// 控制 + 音频复用的那个特征。
    static let voiceCharacteristicUUID = "0783B03E-8535-B5A0-7140-A304D2495CB8"
    /// 同服务下另一个只读通知的特征。抓包里从未来过数据，这里只记录不订阅。
    static let secondaryCharacteristicUUID = "0783B03E-8535-B5A0-7140-A304D2495CBA"

    static let controlFrameLength = 17
    /// 每包 128 字节 = 4 个 32 字节 SBC 帧（16 kHz / 16 blocks / MONO /
    /// Loudness / 8 子带 / bitpool 12），每帧 128 样本 = 8 ms，一包 32 ms。
    static let audioPacketLength = 128

    /// 帧的固定部分——**不含第 4 字节，那是电量**。
    ///
    /// 最初写成 `[0x0A, 0x77, 0xFF, 0x34, 0x1B]`，理由是「抓包里 13/13 个
    /// 控制帧逐字节相同」。**13/13 是真的，但它证明不了任何事**：那 13 帧
    /// 全来自同一次、40 秒内的抓包，电量当然没变。这是「对样本成立、对
    /// 世界不成立」的典型。
    ///
    /// 2026-08-18 当天下午就被推翻：同一支鼠标发来的帧变成
    /// `0A 77 FF 28 1B 27 …`，第 4 字节从 `0x34` 变成 `0x28`。
    /// **`0x34` = 52，而上午读电池特征（`2A19`）正是 52%；`0x28` = 40。**
    ///
    /// 后果不是「少认一个键」而是**整个协议随电量下降而失效**，症状是
    /// 所有帧突然都变成「不认识的 17 字节帧」——极难往电量上想。
    static let framePrefix: [UInt8] = [0x0A, 0x77, 0xFF]
    /// 电量之后、控制码之前的那一字节。抓包里恒为 `0x1B`。
    static let frameBatterySuffix: UInt8 = 0x1B
    static let frameInfix: [UInt8] = [0x0A, 0x06, 0x07, 0x09]
    static let frameSuffix: UInt8 = 0x44

    /// 一个开始码配对的结束码。
    ///
    /// **规律是「开始码 + 1」，三对逐一实测**（2026-08-18 真机、逐动作）：
    /// `0x21`/`0x22` 语音键、`0x23`/`0x24` 第三个键长按、
    /// `0x27`/`0x28` 回车键。
    ///
    /// 拿它做什么见 `MouseVoiceSession.handleControl`：一次会话只认自己的
    /// 配对码，别的偶数码一律不动状态。**这条规律本身也可能不成立**
    /// （换固件），但代价是有界的——会话挂在那里由时长上限收掉，
    /// 而「结束码永远不来」本来就是这台设备上必须处理的一档（`0x31`）。
    static func pairedStop(forStart start: UInt8) -> UInt8 { start &+ 1 }

    /// 映射成回车的那个按键码。抽成常量而不是散在 switch 里，
    /// 是为了让「哪个键接了什么」一眼可查。
    static let enterKeyCode: UInt8 = 0x27
    /// 回车键的松开码。实测与 `0x27` 成对，间隔 8–120 毫秒。
    static let enterReleaseCode: UInt8 = 0x28

    /// 一个通知包属于哪一类。
    ///
    /// **控制帧与音频复用 `…CB8` 这一个特征，长度是唯一的分流依据。**
    /// 第三类不是「忽略」而是「不认识」——固件改了包长时，
    /// 「什么都没发生」与「包来了但没人认」在日志里必须分得开。
    static func kind(ofLength length: Int) -> MousePacketKind {
        switch length {
        case controlFrameLength: return .control
        case audioPacketLength: return .audio
        default: return .unknown(length)
        }
    }

    /// 解析控制帧。**固定字节对不上就返回 nil。**
    ///
    /// 为什么严格：一个 17 字节但布局不同的包意味着固件换了协议。此时把
    /// 第 6 字节当控制码是在猜——猜错会让「开始会话」凭空出现，而这个
    /// 功能的最坏后果正是没人想录的音频被收上来。宁可不认识。
    ///
    /// **地址那 6 字节只记录不校验。** 抓包里是 `C9 00 A9 10 04 C5`，
    /// 而系统蓝牙面板显示的地址是 `C9:01:A9:10:04:C5`——第二字节对不上。
    /// 在没查清这一位到底是什么之前拿它当判据，等于给自己埋一个
    /// 「换一支鼠标就全不认识」的坑。
    static func parseControlFrame(_ data: some DataProtocol) -> MouseControlFrame? {
        let bytes = [UInt8](data)
        guard bytes.count == controlFrameLength else { return nil }
        guard Array(bytes[0..<3]) == framePrefix else { return nil }
        // 第 4 字节是电量，0–100 之外说明这不是我们认识的帧。
        guard bytes[3] <= 100 else { return nil }
        guard bytes[4] == frameBatterySuffix else { return nil }
        guard Array(bytes[6..<10]) == frameInfix else { return nil }
        guard bytes[16] == frameSuffix else { return nil }
        return MouseControlFrame(
            code: bytes[5],
            battery: Int(bytes[3]),
            address: Array(bytes[10..<16])
        )
    }

    /// 控制码 → 语义。
    ///
    /// 规律是**奇数开始、偶数结束**（实测 `0x21`/`0x22`、`0x23`/`0x24`、
    /// `0x27`/`0x28`）。两个例外单独列出：
    ///
    /// - `0x51` 是奇数，但它不开会话。证据：抓包里 3/3 次 `0x51` 之后
    ///   0.31 秒必跟一个 `0x21`，而两者之间**一个音频包都没有**
    ///   （capture.log 第 542 行到第 556 行之间没有 128 字节包）。
    ///   把它当开始码会让每次按键多开一个空会话。
    /// - `0x31` 是奇数开始码，但**没有配对的结束码**——它是 2026-08-18
    ///   那次 11 分钟环境音事故的源头，单列出来好让上层给它更紧的上限。
    static func classify(code: UInt8) -> MouseControlSemantics {
        switch code {
        case 0x51: return .wake
        case 0x21: return .voiceStart
        case 0x31: return .unpairedStart
        // 用户 2026-08-18 指定：鼠标上那个多余的键映射成回车。
        // 实测按一下发 `0x27`、松开发 `0x28`，两次按键完全一致。
        case enterKeyCode: return .enterKey
        // 回车键的松开码。**必须显式忽略**：落到 default 会被当成偶数结束码，
        // 于是「按住语音键说话时按一下回车」= 说到一半被截断。
        // 文档一直声称它「直接忽略」，但原实现只特判了 0x27——
        // 独立验收 2026-08-18 指出这个矛盾。第三个键的 0x24 早就显式加进了
        // 忽略名单，同样的处理没有回头补给 0x28。
        case enterReleaseCode: return .ignored
        // 第三个键。2026-08-18 逐动作实测：短按发单个 `0x41`（无结束码、
        // 不送音频），长按发 `0x23` → `0x24`。用户要求它完全没有功能。
        case 0x41, 0x43, 0x23, 0x24: return .ignored
        default:
            // **偶数即结束，但只结束与它配对的那个会话。**
            //
            // 奇数那一半有抓包证据（`0x51`/`0x21` 之间一个音频包都没有）；
            // 偶数这一半原来是当断言写的「偶数即结束任何进行中的会话」，
            // 没有论证过，而且已经误伤两次：`0x28`（回车松开）截断听写、
            // `0x24`（第三个键松开）也是手工补的忽略名单。配对判据放在
            // 状态机里，那里才知道当前会话是谁开的。
            return code % 2 == 1 ? .otherStart(code) : .stop(code)
        }
    }
}
