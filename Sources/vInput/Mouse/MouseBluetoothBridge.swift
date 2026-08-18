import CoreBluetooth
import Foundation

/// 蓝牙鼠标（iMouse）的 CoreBluetooth 外壳。
///
/// # 与遥控器那座桥的关系
///
/// **一行都不从 `XiaomiBluetoothBridge` 派生。** 那是 GPL-3.0 的移植件，
/// 读它是为了学本项目怎么用 CoreBluetooth（先 retrieve 再 scan、订阅前先
/// 发现特征、退订再断开），抄它会把上游的许可证义务和 ATVV 的形状一起
/// 带进来——而这支鼠标的协议比 ATVV 简单得多：一个特征、17 字节控制帧、
/// 128 字节音频包，没有能力协商、没有会话 ID、没有分片重组。
///
/// # 两个非显然的坑（都栽过）
///
/// **① 系统已连接的 BLE 设备不广播。** 鼠标平时是系统已连接的 HID 设备，
/// 这种状态下 `scanForPeripherals` **永远扫不到它**。必须先用
/// `retrieveConnectedPeripherals(withServices:)` 拿系统已连接的那一批。
///
/// **② `FFF1` 不一定能用来检索。** `retrieveConnectedPeripherals` 按服务
/// UUID 过滤，而 macOS 未必把厂商服务算进那份索引。所以检索用的是一组
/// 「几乎一定有」的标准服务（HID / 电池 / 设备信息 / GAP）把设备钓出来，
/// 连上之后再按 `FFF1` 发现服务。
///
/// # 不打断 RC003
///
/// 用户每天用小米遥控器听写，这座桥**绝不能碰它**，三道：
/// - 遥控器名进硬编码禁止名单（`MouseTargetMatcher.isForbidden`），
///   先于目标名判断；
/// - 遥控器桥当前持有的 identifier 由 `excludedIdentifiers` 排除；
/// - 只按名字连（`iMouse`），不按服务 UUID 连——遥控器桥当年的
///   「服务 UUID 匹配**或**名字匹配」正是双设备互抢的隐患来源。
///
/// # 时长上限
///
/// 每秒 tick 一次 `MouseVoiceSession`。撞线时退订 `…CB8`（`.stopReceiving`）
/// 并在冷却后恢复（`.resumeReceiving`）。**不发写入命令去关麦**，理由见
/// `MouseVoiceSession` 的文件头。

/// 桥的连接状态。自己一份小枚举，不复用遥控器那边的
/// `BluetoothBridgeState`——那个带着 ATVV 的 `awaitingCapabilities` 这类
/// 阶段，对这支鼠标没有意义，硬套只会让日志说谎。
enum MouseBridgeState: Equatable {
    case stopped
    case bluetoothUnavailable(String)
    case searching
    case connecting
    case discovering
    case ready(String)
    /// 已主动退订，正在冷却（撞到时长上限）。
    case muted(TimeInterval)
    case reconnecting
}

extension MouseBridgeState {
    /// 菜单栏那一行。
    ///
    /// **`.muted` 必须能被看见。** 2026-08-18 那次 11 分钟环境音，用户是靠
    /// 菜单栏的麦克风图标才发现的；反过来，我们主动掐断一段流之后如果
    /// 什么都不显示，用户只会觉得「语音键突然不好使了」，然后去重启应用。
    func menuLabel(battery: Int?) -> String {
        switch self {
        case .stopped:
            return "鼠标：未启用"
        case .bluetoothUnavailable(let reason):
            return "鼠标：\(reason)"
        case .searching:
            return "鼠标：搜索中…"
        case .connecting, .discovering:
            return "鼠标：连接中…"
        case .reconnecting:
            return "鼠标：重连中…"
        case .muted(let cooldown):
            return "鼠标：已超时静音，\(Int(cooldown)) 秒后恢复"
        case .ready:
            if let battery {
                return "鼠标：已连接（电量 \(battery)%）"
            }
            return "鼠标：已连接"
        }
    }
}

protocol MouseBluetoothBridgeDelegate: AnyObject {
    func mouseBridge(_ bridge: MouseBluetoothBridge, didChange state: MouseBridgeState)
    func mouseBridgeDidStartVoice(_ bridge: MouseBluetoothBridge)
    func mouseBridge(_ bridge: MouseBluetoothBridge, didStopVoice reason: MouseSessionEndReason)
    /// 收到一个音频包（裸 SBC 字节）。**只有听写会话期间才会被调用**——
    /// 过滤在 `MouseVoiceSession.acceptsAudio`。
    func mouseBridge(_ bridge: MouseBluetoothBridge, didReceiveAudio packet: Data)
    func mouseBridge(_ bridge: MouseBluetoothBridge, didUpdateBatteryLevel level: Int?)
    /// 连接断开。录音中要以错误收尾。
    func mouseBridgeDidDisconnect(_ bridge: MouseBluetoothBridge)
}

final class MouseBluetoothBridge: NSObject {
    /// 检索已连接设备时用的服务清单。理由见文件头的坑 ②。
    private static let probeServices: [CBUUID] = [
        CBUUID(string: "1812"),  // HID over GATT
        CBUUID(string: "180F"),  // 电池
        CBUUID(string: "180A"),  // 设备信息
        CBUUID(string: "1800"),  // GAP
        CBUUID(string: MouseVoiceProtocol.serviceUUID),
    ]

    /// 没连上时每隔多久重试一次。鼠标会睡，用户可能要动一下它才醒。
    private static let retryInterval: TimeInterval = 15
    /// 断开后多久重连。
    private static let reconnectDelay: TimeInterval = 3

    private let serviceUUID = CBUUID(string: MouseVoiceProtocol.serviceUUID)
    private let voiceUUID = CBUUID(string: MouseVoiceProtocol.voiceCharacteristicUUID)
    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")

    private let targetName: String
    private let excludedIdentifiers: () -> Set<UUID>
    private weak var delegate: MouseBluetoothBridgeDelegate?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var voiceCharacteristic: CBCharacteristic?
    private var running = false
    private var tickTimer: Timer?

    /// 会话状态机。**桥不自己判会话**——判据全在这里，测试也全打在这里。
    let session = MouseVoiceSession()

    /// 不认识的帧的日志限流。**按时间窗，不按绝对条数**——理由与两个数的
    /// 依据见 `MouseUnknownFrameLog`。
    private var unknownFrames = MouseUnknownFrameLog()

    private(set) var state: MouseBridgeState = .stopped {
        didSet {
            guard oldValue != state else { return }
            delegate?.mouseBridge(self, didChange: state)
        }
    }

    var deviceIdentifier: UUID? { peripheral?.identifier }

    /// 注入按键的实现。**可替换是为了能测**——真发 `CGEvent` 要辅助功能
    /// 授权，测试进程拿不到（TCC 绑 app bundle）。
    private let keyPoster: KeyPoster

    init(
        delegate: MouseBluetoothBridgeDelegate,
        targetName: String = MouseVoiceGate.targetName,
        excludedIdentifiers: @escaping () -> Set<UUID> = { [] },
        keyPoster: KeyPoster = SystemKeyPoster()
    ) {
        self.delegate = delegate
        self.targetName = targetName
        self.excludedIdentifiers = excludedIdentifiers
        self.keyPoster = keyPoster
        super.init()
    }

    var isRunning: Bool { running }

    func start() {
        guard !running else { return }
        running = true
        log("启动 目标名=\(targetName)")
        state = .searching
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            // 不弹系统的蓝牙开启提示：这是一个后台自动连接的附属功能，
            // 用户没有主动要求它连，不该被一个弹窗打断。遥控器那条主路径
            // 已经会弹。
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
        startTicking()
        scheduleRetryTick()
    }

    func stop() {
        guard running else { return }
        running = false
        tickTimer?.invalidate()
        tickTimer = nil
        session.reset()
        central?.stopScan()

        // 先退订再断开。不退订就断的话，设备侧可能仍认为订阅有效，
        // 下一轮连接的头几个包会落在一个已经不存在的连接上。
        if let peripheral, let voiceCharacteristic, voiceCharacteristic.isNotifying {
            peripheral.setNotifyValue(false, for: voiceCharacteristic)
        }
        if let peripheral {
            central?.cancelPeripheralConnection(peripheral)
            peripheral.delegate = nil
        }
        self.peripheral = nil
        voiceCharacteristic = nil
        central?.delegate = nil
        central = nil
        state = .stopped
        log("已停止")
    }

    // MARK: - 时长上限

    /// 每秒 tick。间隔 1 秒足够——判断基于绝对时刻，不依赖 tick 的精确性
    /// （与 `VoiceSessionKeepalive` 同一条理由）。主线程繁忙漏拍时，
    /// 下一次 tick 会把跳过的间隔补齐。
    private func startTicking() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            self.apply(self.session.tick(at: now))
            // 不认识的帧停了之后，把最后一个窗口的账结掉。挂在 tick 上是因为
            // 「压掉两千条然后设备不再发包」时，汇总等不到下一帧来触发。
            if let summary = self.unknownFrames.flush(at: now) { self.log(summary) }
        }
    }

    /// 打一条「不认识的帧」的日志，经过限流。
    ///
    /// 汇总行排在原始内容之前：它结的是**上一个**窗口的账，按时间顺序
    /// 就该先出现。
    private func logUnknownFrame(_ message: @autoclosure () -> String) {
        let decision = unknownFrames.record(at: Date())
        if let summary = decision.summary { log(summary) }
        if decision.shouldLog { log(message()) }
    }

    /// 把状态机的动作落到真实世界。
    ///
    /// 日志写在这里而不是状态机里：状态机的测试比对的是行为，
    /// 不该被字符串绑住。
    private func apply(_ actions: [MouseSessionAction]) {
        for action in actions {
            switch action {
            case .closedSilentForeign(let code):
                log(String(format: "按键 0x%02X 没有送音频，会话已静默收掉", code))

            case .ignoredStop(let code, let expected):
                // **这一行是为了让日志不说谎。** 上面每个控制码都打了一行，
                // 若这里悄无声息，读日志的人会以为会话被它结束了。
                // 它同时是发现新按键的线索：出现一次就说明鼠标上有个键
                // 我们还不认识——把它的码原样报出来，下一轮就能定它的归属。
                log(String(
                    format: "结束码 0x%02X 与本次会话不配对（本次该收 0x%02X），已忽略",
                    code, expected
                ))

            case .pressEnter:
                log("回车键按下，注入 Return")
                keyPoster.postReturn()

            case .beginDictation:
                log("语音键按下，开始录音")
                delegate?.mouseBridgeDidStartVoice(self)

            case .endDictation(let reason):
                log("录音结束：\(describe(reason))")
                delegate?.mouseBridge(self, didStopVoice: reason)

            case .stopReceiving(let cooldown):
                // 这条日志是 2026-08-18 那次事故的直接对策，写清楚发生了什么。
                AppLogger.shared.log(
                    "鼠标 达到会话时长上限，已停止接收音频并退订语音特征，"
                        + "\(Int(cooldown)) 秒后恢复订阅"
                )
                unsubscribeVoice()
                state = .muted(cooldown)

            case .resumeReceiving:
                log("冷却结束，恢复订阅语音特征（需要重新按键才会再录音）")
                subscribeVoice()
                if peripheral != nil { state = .ready(peripheral?.name ?? targetName) }
            }
        }
    }

    private func describe(_ reason: MouseSessionEndReason) -> String {
        switch reason {
        case .controlFrame(let code):
            return "收到结束码 0x\(String(code, radix: 16, uppercase: true))"
        case .durationLimit(let elapsed):
            return "达到时长上限 \(Int(elapsed)) 秒"
        case .disconnected:
            return "连接断开"
        case .superseded(let code):
            return "被新的开始码 0x\(String(code, radix: 16, uppercase: true)) 顶掉"
        }
    }

    private func subscribeVoice() {
        guard let peripheral, let voiceCharacteristic else { return }
        peripheral.setNotifyValue(true, for: voiceCharacteristic)
    }

    private func unsubscribeVoice() {
        guard let peripheral, let voiceCharacteristic else { return }
        peripheral.setNotifyValue(false, for: voiceCharacteristic)
    }

    // MARK: - 查找与连接

    private func log(_ message: String) {
        AppLogger.shared.log("鼠标 \(message)")
    }

    private func scheduleRetryTick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
            guard let self, self.running else { return }
            defer { self.scheduleRetryTick() }
            guard self.peripheral == nil, let central = self.central, central.state == .poweredOn
            else { return }
            self.beginLookup(using: central)
        }
    }

    private func beginLookup(using central: CBCentralManager) {
        guard running, peripheral == nil, central.state == .poweredOn else { return }

        // ① 系统已连接的那一批。**必须先走这条**，理由见文件头的坑 ①。
        let connected = central.retrieveConnectedPeripherals(withServices: Self.probeServices)
        if let match = connected.first(where: { isAcceptable($0) }) {
            connect(match, using: central, source: "retrieveConnectedPeripherals")
            return
        }

        // ② 再广播扫描，兜住「已配对但当前未连接」的情形。
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func isAcceptable(_ candidate: CBPeripheral) -> Bool {
        guard MouseTargetMatcher.isTarget(name: candidate.name, target: targetName) else {
            return false
        }
        return !excludedIdentifiers().contains(candidate.identifier)
    }

    private func connect(_ candidate: CBPeripheral, using central: CBCentralManager, source: String) {
        central.stopScan()
        peripheral = candidate
        candidate.delegate = self
        state = .connecting
        log("连接中 name=\(candidate.name ?? "?") source=\(source)")
        central.connect(candidate, options: nil)
    }

    private func scheduleReconnect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconnectDelay) { [weak self] in
            guard let self, self.running, let central = self.central else { return }
            self.beginLookup(using: central)
        }
    }

    // MARK: - 收包

    /// 按长度分流。**控制帧与音频复用同一个特征**，长度是唯一的依据。
    ///
    /// 不设成 private：这是整座桥里唯一不依赖 CoreBluetooth 运行时对象的
    /// 环节，而**真机验证要靠用户按鼠标上的键**。开放给测试直接喂字节，
    /// 换来的是「分流 + 状态机 + delegate 回调」这一整条链路在 CI 里跑得到。
    /// 把控制码翻译成人话，只用于日志。
    ///
    /// 未知码显式标成「未知」而不是留空——发现新按键时，日志里那个「未知」
    /// 就是线索。
    static func describeSemantics(_ code: UInt8) -> String {
        switch MouseVoiceProtocol.classify(code: code) {
        case .wake: return "语音键按下，准备"
        case .enterKey: return "回车键"
        case .ignored: return "第三个键，刻意无功能"
        case .voiceStart: return "语音会话开始"
        case .unpairedStart: return "长按持续开麦，无结束码"
        case .otherStart(let value): return String(format: "其他按键开始 0x%02X", value)
        // **不写「结束」两个字**：它只结束与它配对的那个会话，
        // 别的会话进行中时它什么也不做（见 MouseVoiceSession.handleControl）。
        // 写成「结束」会让日志在最需要看清的那一刻说谎。
        case .stop(let value): return String(format: "结束码 0x%02X", value)
        }
    }

    func handleVoicePacket(_ data: Data) {
        switch MouseVoiceProtocol.kind(ofLength: data.count) {
        case .control:
            guard let frame = MouseVoiceProtocol.parseControlFrame(data) else {
                logUnknownFrame(
                    "不认识的 17 字节帧（固件可能换了协议）："
                        + data.map { String(format: "%02X", $0) }.joined(separator: " ")
                )
                return
            }
            // **每个控制码都记一行。**
            //
            // 之前只在会话开始/结束时打日志，于是「鼠标上另外那个键按下去
            // 发的是什么码」在日志里查不到——而要给某个键接功能（比如把它
            // 映射成回车），第一步就是知道它的码。
            //
            // 一行一个码不吵：按一次键最多产生两三帧（`0x51` → `0x21` →
            // `0x22`），不像音频包那样每秒 33 个。
            log(String(format: "控制码 0x%02X（%@）", frame.code,
                       Self.describeSemantics(frame.code)))
            apply(session.handleControl(code: frame.code, at: Date()))

        case .audio:
            // 记账必须在过滤之前：非听写会话的音频虽然被丢掉，
            // 会话仍然要知道「其实有流」，否则分不清按键与送流。
            session.noteAudioPacket()
            // 第一道过滤在这里：不是听写会话就一个字节都不往下送。
            // 0x31 / 0x23 开的会话到不了音频源，也就到不了转写与注入。
            guard session.acceptsAudio else { return }
            delegate?.mouseBridge(self, didReceiveAudio: data)

        case .unknown(let length):
            // 原样报一次长度：固件改了包长时，「什么都没发生」和
            // 「包来了但没人认」在日志里必须分得开。
            logUnknownFrame("语音特征来了 \(length) 字节的包，既不是控制帧也不是音频包")
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension MouseBluetoothBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central else { return }
        switch central.state {
        case .poweredOn:
            beginLookup(using: central)
        case .poweredOff:
            state = .bluetoothUnavailable("蓝牙已关闭")
        case .unauthorized:
            state = .bluetoothUnavailable("蓝牙未授权 —— 系统设置 → 隐私与安全性 → 蓝牙")
        case .unsupported:
            state = .bluetoothUnavailable("本机不支持 BLE")
        case .resetting:
            state = .bluetoothUnavailable("蓝牙栈重置中")
        case .unknown:
            state = .bluetoothUnavailable("蓝牙状态未知")
        @unknown default:
            state = .bluetoothUnavailable("蓝牙状态无法识别")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard self.central === central, running, self.peripheral == nil else { return }
        // 广播里的 local name 与 peripheral.name 可能不同，两个都试。
        // **只按名字连，不按服务 UUID 连**——理由见文件头「不打断 RC003」。
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let nameHit = isAcceptable(peripheral)
            || (MouseTargetMatcher.isTarget(name: advertisedName, target: targetName)
                && !excludedIdentifiers().contains(peripheral.identifier))
        guard nameHit else { return }
        connect(peripheral, using: central, source: "广播扫描")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central, self.peripheral === peripheral else { return }
        state = .discovering
        log("已连接 name=\(peripheral.name ?? "?")")
        // 只发现要用的两个服务。不用 nil（「全都要」）：那是诊断工具的做法，
        // 结构早就查清了，产品路径上多发现一遍只是多花时间。
        peripheral.discoverServices([serviceUUID, batteryServiceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.central === central, self.peripheral === peripheral else { return }
        log("连接失败 error=\(error?.localizedDescription ?? "未知")")
        self.peripheral = nil
        voiceCharacteristic = nil
        state = .reconnecting
        scheduleReconnect()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.central === central, self.peripheral === peripheral else { return }
        log("已断开 error=\(error?.localizedDescription ?? "无")")
        apply(session.handleDisconnected())
        delegate?.mouseBridgeDidDisconnect(self)
        self.peripheral = nil
        voiceCharacteristic = nil
        guard running else { return }
        state = .reconnecting
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension MouseBluetoothBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        if let error {
            log("服务发现失败 error=\(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        if !services.contains(where: { $0.uuid == serviceUUID }) {
            // 说清楚缺的是什么。这台设备连上了但没有语音服务，
            // 与「根本没连上」是两回事，日志里必须分得开。
            log("已连接但没有 \(MouseVoiceProtocol.serviceUUID) 语音服务 —— 可能连错了设备")
        }
        for service in services {
            if service.uuid == serviceUUID {
                peripheral.discoverCharacteristics([voiceUUID], for: service)
            } else if service.uuid == batteryServiceUUID {
                peripheral.discoverCharacteristics([batteryLevelUUID], for: service)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard self.peripheral === peripheral else { return }
        if let error {
            log("特征发现失败 error=\(error.localizedDescription)")
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case voiceUUID:
                voiceCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                state = .ready(peripheral.name ?? targetName)
                log("语音特征已就绪，按住鼠标上的语音键即可听写")
            case batteryLevelUUID:
                peripheral.readValue(for: characteristic)
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            default:
                break
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard self.peripheral === peripheral, characteristic.uuid == voiceUUID else { return }
        if let error {
            log("订阅失败 error=\(error.localizedDescription)")
            return
        }
        log("语音特征订阅\(characteristic.isNotifying ? "成功" : "已取消")")
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard self.peripheral === peripheral else { return }
        if let error {
            log("读取失败 uuid=\(characteristic.uuid.uuidString) error=\(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }

        switch characteristic.uuid {
        case voiceUUID:
            handleVoicePacket(data)
        case batteryLevelUUID:
            delegate?.mouseBridge(self, didUpdateBatteryLevel: data.first.map(Int.init))
        default:
            break
        }
    }
}
