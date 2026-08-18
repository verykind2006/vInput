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
    /// 其他奇数开始码（实测 `0x23` / `0x27`，鼠标上别的 AI 功能键）。
    case otherStart(UInt8)
    /// 任意偶数码 = 结束。
    case stop(UInt8)
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

    /// 帧的固定部分。抓包里 13/13 个控制帧逐字节相同，只有第 6 字节（码）变。
    static let framePrefix: [UInt8] = [0x0A, 0x77, 0xFF, 0x34, 0x1B]
    static let frameInfix: [UInt8] = [0x0A, 0x06, 0x07, 0x09]
    static let frameSuffix: UInt8 = 0x44

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
        guard Array(bytes[0..<5]) == framePrefix else { return nil }
        guard Array(bytes[6..<10]) == frameInfix else { return nil }
        guard bytes[16] == frameSuffix else { return nil }
        return MouseControlFrame(code: bytes[5], address: Array(bytes[10..<16]))
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
        default:
            return code % 2 == 1 ? .otherStart(code) : .stop(code)
        }
    }
}
