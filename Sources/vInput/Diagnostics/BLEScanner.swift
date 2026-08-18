import CoreBluetooth
import Foundation

/// BLE GATT 扫描诊断——CoreBluetooth 外壳。
///
/// # 这是干什么的
///
/// 用户新买的蓝牙鼠标 `iMouse` 带收音功能，但**不是标准蓝牙音频输入设备**
/// （只有 BLE，没有 HFP/A2DP，`system_profiler SPAudioDataType` 里查无此
/// 设备），所以音频必然走自定义协议。这个工具去查清它到底走什么，回答
/// 三个问题：
///
/// 1. 它暴露哪些 GATT 服务与特征？UUID、properties、能读到的值。
/// 2. 它讲不讲 ATVV？（与 `ATVVProtocol` 的四个 UUID 逐一比对，
///    见 `ATVVFingerprint`。讲的话 M3 的解码器与状态机大部分能直接复用，
///    工作量差一个数量级。）
/// 3. 按语音键时哪个特征来数据？
///
/// **本轮只做诊断，不实现音频接入。** 扫描结果决定 M7 的规模。
///
/// # 怎么跑
///
/// ```
/// ./scripts/build-app.sh
/// open --env VINPUT_BLE_SCAN=1 dist/vInput.app
/// ```
///
/// 启动后等日志出现 `BLESCAN 结构扫描完成`，再按住鼠标上的语音键说三五秒，
/// 松开；重复两三次。然后菜单栏「结束 BLE 扫描并汇总」，把
/// `~/Library/Logs/vInput/vInput.log` 与 `ble-scan-*.log` 一起发回来。
///
/// # 为什么必须做成应用内的模式，而不是独立 CLI
///
/// CoreBluetooth 要 TCC 授权，而授权绑 app bundle——独立可执行文件大概率
/// 拿不到蓝牙权限。这与麦克风是同一类问题。所以照 `VINPUT_BENCH=1` 的路子
/// 做成环境变量门控的应用内模式（`BLEScanGate`），**默认不启用**。
///
/// # 两个非显然的坑
///
/// **① 已连接的 BLE 设备不广播。** 鼠标平时是系统已连接的 HID 设备，
/// 这种状态下 `scanForPeripherals` **永远扫不到它**。必须先用
/// `retrieveConnectedPeripherals(withServices:)` 拿系统已连接的那一批。
/// 上游的 `XiaomiBluetoothBridge` 也是先 retrieve 再 scan，同一个道理。
///
/// **② macOS 不把 HID over GATT（0x1812）交给 CoreBluetooth。** 系统会把
/// 这个服务从 `peripheral.services` 里滤掉。因此如果音频是搭 HID 报文走的
/// （鼠标暴露了 `{Page=0xFF00,Usage=0}` 厂商自定义页，这条路完全可能），
/// GATT 这边会**什么都扫不到**。所以同一个开关还会拉起
/// `HIDReportProbe`，两条路一起看，免得白按一轮键。
///
/// # 与 RC003 的隔离
///
/// 用户每天在用小米遥控器听写，**扫描器绝不能碰它**：
/// - 名字进硬编码禁止名单（`BLEScanTargetMatcher.isForbidden`），
///   先于目标名判断；
/// - 遥控器桥当前持有的 identifier 由 `excludedIdentifiers` 排除；
/// - 启动延迟几秒，让遥控器桥先抢到连接；
/// - `stop()` 退订全部特征后再断开。
///
/// 代码独立写，不从 `XiaomiBluetoothBridge`（GPL-3.0 的移植件）派生。
final class BLEScanner: NSObject {
    /// 探测已连接设备时用的服务清单。
    ///
    /// `retrieveConnectedPeripherals` 必须给服务 UUID，而鼠标的厂商服务
    /// UUID 恰恰是我们要查的东西——先拿几个「几乎一定有」的标准服务把它
    /// 钓出来，连上之后再 `discoverServices(nil)` 看全貌。
    private static let probeServices: [CBUUID] = [
        CBUUID(string: "1812"),  // HID over GATT。鼠标必有；macOS 未必交给我们，但可用于检索
        CBUUID(string: "180F"),  // 电池
        CBUUID(string: "180A"),  // 设备信息
        CBUUID(string: "1800"),  // GAP
        CBUUID(string: ATVVProtocol.serviceUUID),
        CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),  // Nordic UART
    ]

    /// 没连上时每隔多久重试一次并留一行日志。
    ///
    /// 鼠标会睡；用户可能要动一下它才醒。没有这行周期日志的话，用户盯着
    /// 一片安静的日志不知道是工具坏了还是设备没醒。
    private static let retryInterval: TimeInterval = 15

    private let targetName: String
    private let excludedIdentifiers: () -> Set<UUID>
    private let fileLog: BLEScanFileLog?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var notifications = BLEScanNotificationLog()
    private var discoveredServices: [CBUUID] = []
    private var discoveredCharacteristics: [CBUUID] = []
    private var pendingServiceCount = 0
    /// 已发出 read 但还没回值的特征。用来区分「读回来的值」与「订阅推来的
    /// 通知」——两者走同一个回调，混在一起会让第三个问题失去答案。
    private var pendingReads = Set<CBUUID>()
    private var announcedPeripherals = Set<UUID>()
    /// 已发出 `setNotifyValue(true)` 的特征。结构汇总要按名报出来——
    /// 用户按键前得知道「到底有几条线在听」。
    private var subscribedCharacteristics: [CBUUID] = []
    /// 「被遥控器桥占用」只报一次。重试每 15 秒一轮，不去重会把日志刷满，
    /// 而这条信息说一遍就够了。
    private var reportedExclusion = false
    private var running = false
    private var structureReported = false

    init(
        targetName: String = BLEScanGate.targetName,
        excludedIdentifiers: @escaping () -> Set<UUID> = { [] },
        fileLog: BLEScanFileLog? = BLEScanFileLog()
    ) {
        self.targetName = targetName
        self.excludedIdentifiers = excludedIdentifiers
        self.fileLog = fileLog
        super.init()
    }

    var isRunning: Bool { running }

    func start() {
        guard !running else {
            log("已在扫描中，忽略重复启动")
            return
        }
        running = true
        structureReported = false
        log("启动 目标名=\(targetName)")
        if let fileLog {
            log("原始包将写入 \(fileLog.path)")
        } else {
            log("原始包文件创建失败，只有主日志里的限流版本")
        }
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        scheduleRetryTick()
    }

    func stop() {
        guard running else { return }
        running = false
        central?.stopScan()

        // 先退订再断开。不退订就断的话，设备侧可能仍认为订阅有效，
        // 下一轮扫描的头几个包会落在一个已经不存在的连接上。
        if let peripheral {
            for service in peripheral.services ?? [] {
                for characteristic in service.characteristics ?? []
                where characteristic.isNotifying {
                    peripheral.setNotifyValue(false, for: characteristic)
                }
            }
            central?.cancelPeripheralConnection(peripheral)
        }

        for line in notifications.flush(at: Date()) {
            AppLogger.shared.log(line)
            fileLog?.write(line)
        }
        log(fingerprintSummary())
        log("已停止")

        peripheral?.delegate = nil
        peripheral = nil
        central?.delegate = nil
        central = nil
        discoveredServices = []
        discoveredCharacteristics = []
        subscribedCharacteristics = []
        pendingReads = []
        announcedPeripherals = []
        pendingServiceCount = 0
        reportedExclusion = false
    }

    // MARK: - 私有

    private func log(_ message: String) {
        AppLogger.shared.log("BLESCAN \(message)")
        fileLog?.write("BLESCAN \(message)")
    }

    private func fingerprintSummary() -> String {
        ATVVFingerprint.evaluate(
            services: discoveredServices,
            characteristics: discoveredCharacteristics
        ).summary.replacingOccurrences(of: "BLESCAN ", with: "")
    }

    /// 周期性重试。鼠标会睡，用户也可能晚一步才打开它。
    private func scheduleRetryTick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
            guard let self, self.running else { return }
            defer { self.scheduleRetryTick() }
            guard self.peripheral == nil, let central = self.central, central.state == .poweredOn
            else { return }
            log("还没找到「\(targetName)」——确认鼠标已开机并已与本机配对，"
                + "动一下它让它醒过来")
            beginLookup(using: central)
        }
    }

    private func beginLookup(using central: CBCentralManager) {
        guard running, peripheral == nil, central.state == .poweredOn else { return }

        // ① 系统已连接的那一批。**必须先走这条**：已连接的 BLE 设备不广播，
        //    只靠 scanForPeripherals 会永远扫不到一支正在用的鼠标。
        let connected = central.retrieveConnectedPeripherals(withServices: Self.probeServices)
        for candidate in connected {
            announce(candidate, source: "系统已连接", advertisement: nil, rssi: nil)
        }
        if let match = connected.first(where: { isAcceptable($0) }) {
            connect(match, using: central, source: "retrieveConnectedPeripherals")
            return
        }

        // ② 再广播扫描，兜住「已配对但当前未连接」的情形。
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        log("开始广播扫描（系统已连接列表里没有目标）")
    }

    /// 把看到的每一台设备记一行。**不只记目标**：用户报的名字与
    /// CoreBluetooth 看到的名字未必一致（系统蓝牙面板显示的是 classic 侧的
    /// 名字），扫不到目标时这份清单就是唯一的线索。
    private func announce(
        _ candidate: CBPeripheral,
        source: String,
        advertisement: [String: Any]?,
        rssi: NSNumber?
    ) {
        guard announcedPeripherals.insert(candidate.identifier).inserted else { return }
        var line = "PEER source=\(source) name=\(candidate.name ?? "（无名）")"
        line += " id=\(candidate.identifier.uuidString)"
        if let rssi { line += " rssi=\(rssi)" }
        if let advertisement {
            if let localName = advertisement[CBAdvertisementDataLocalNameKey] as? String {
                line += " localName=\(localName)"
            }
            if let services = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
                line += " adv_services=[\(services.map(BLEScanFormatter.describeUUID).joined(separator: " "))]"
            }
            // 厂商数据的头两字节是 Bluetooth SIG 分配的公司 ID，
            // 扫不出服务时它常常是唯一能指认厂商的东西。
            if let manufacturer = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data {
                line += " manufacturer=\(BLEScanFormatter.hex(manufacturer, limit: 16))"
            }
        }
        log(line)
    }

    private func isAcceptable(_ candidate: CBPeripheral) -> Bool {
        guard BLEScanTargetMatcher.isTarget(name: candidate.name, target: targetName) else {
            return false
        }
        guard !excludedIdentifiers().contains(candidate.identifier) else {
            // 这条日志本身就是一份证据：遥控器桥只在名字匹配小米、
            // **或广播里带 ATVV 服务 UUID** 时才连（见
            // XiaomiBluetoothBridge.centralManager(_:didDiscover:…)）。
            // 鼠标被它抢走，说明鼠标广播了 ATVV 服务 UUID——那就是问题二
            // 的答案，而且是最强的那种。
            if !reportedExclusion {
                reportedExclusion = true
                log("目标「\(candidate.name ?? "?")」正被遥控器桥占用 —— "
                    + "这本身说明它广播了 ATVV 服务 UUID，是「讲 ATVV」的强证据；"
                    + "请先关掉遥控器再重试，以便扫到完整的 GATT 结构")
            }
            return false
        }
        return true
    }

    private func connect(_ candidate: CBPeripheral, using central: CBCentralManager, source: String) {
        central.stopScan()
        peripheral = candidate
        candidate.delegate = self
        log("连接中 name=\(candidate.name ?? "?") source=\(source)")
        central.connect(candidate, options: nil)
    }

    private func reportStructureIfComplete() {
        guard !structureReported, pendingServiceCount == 0 else { return }
        structureReported = true
        log("结构扫描完成 服务 \(discoveredServices.count) 个 特征 \(discoveredCharacteristics.count) 个")
        log(fingerprintSummary())

        log("已订阅 \(subscribedCharacteristics.count) 个可通知特征："
            + subscribedCharacteristics.map(BLEScanFormatter.describeUUID).joined(separator: " "))
        log("★ 现在按住鼠标上的语音键说三五秒再松开，重复两三次；"
            + "然后菜单栏「结束 BLE 扫描并汇总」")
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEScanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central else { return }
        switch central.state {
        case .poweredOn:
            log("蓝牙就绪")
            beginLookup(using: central)
        case .poweredOff:
            log("蓝牙已关闭")
        case .unauthorized:
            // 这正是「独立 CLI 拿不到权限」那件事的现场信号。
            log("蓝牙未授权 —— 系统设置 → 隐私与安全性 → 蓝牙 里给 vInput 打勾")
        case .unsupported:
            log("本机不支持 BLE")
        case .resetting:
            log("蓝牙栈重置中")
        case .unknown:
            log("蓝牙状态未知")
        @unknown default:
            log("蓝牙状态无法识别")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard self.central === central, running else { return }
        announce(peripheral, source: "广播", advertisement: advertisementData, rssi: RSSI)
        guard self.peripheral == nil else { return }

        // 广播里的 local name 与 peripheral.name 可能不同，两个都试。
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let nameHit = isAcceptable(peripheral)
            || (BLEScanTargetMatcher.isTarget(name: advertisedName, target: targetName)
                && !excludedIdentifiers().contains(peripheral.identifier))
        guard nameHit else { return }
        connect(peripheral, using: central, source: "广播扫描")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central, self.peripheral === peripheral else { return }
        log("已连接 name=\(peripheral.name ?? "?")")
        // nil 表示「全都要」。这正是本工具的目的——我们不知道要找什么 UUID。
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.central === central, self.peripheral === peripheral else { return }
        log("连接失败 error=\(error?.localizedDescription ?? "未知")")
        self.peripheral = nil
        beginLookup(using: central)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.central === central, self.peripheral === peripheral else { return }
        log("已断开 error=\(error?.localizedDescription ?? "无")")
        for line in notifications.flush(at: Date()) {
            AppLogger.shared.log(line)
            fileLog?.write(line)
        }
        self.peripheral = nil
        structureReported = false
        discoveredServices = []
        discoveredCharacteristics = []
        subscribedCharacteristics = []
        guard running else { return }
        beginLookup(using: central)
    }
}

// MARK: - CBPeripheralDelegate

extension BLEScanner: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        if let error {
            log("服务发现失败 error=\(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        discoveredServices = services.map(\.uuid)
        pendingServiceCount = services.count
        log("服务 \(services.count) 个："
            + services.map { BLEScanFormatter.describeUUID($0.uuid) }.joined(separator: " "))
        if services.isEmpty {
            // macOS 会把 HID over GATT（0x1812）从这份列表里滤掉。空列表
            // 不代表设备没有 GATT，而是说明它的东西都藏在 HID 那侧。
            log("一个服务都没拿到 —— macOS 会屏蔽 HID over GATT，"
                + "这说明音频很可能走 HID 报文而非 GATT，看 HIDPROBE 那几行")
            reportStructureIfComplete()
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard self.peripheral === peripheral else { return }
        pendingServiceCount = max(0, pendingServiceCount - 1)
        defer { reportStructureIfComplete() }

        if let error {
            log("特征发现失败 service=\(BLEScanFormatter.describeUUID(service.uuid)) "
                + "error=\(error.localizedDescription)")
            return
        }
        for characteristic in service.characteristics ?? [] {
            discoveredCharacteristics.append(characteristic.uuid)
            log(BLEScanFormatter.line(for: ScannedCharacteristic(
                serviceUUID: service.uuid,
                uuid: characteristic.uuid,
                properties: characteristic.properties,
                value: characteristic.value
            )).replacingOccurrences(of: "BLESCAN ", with: ""))

            // 描述符里的 0x2901（Characteristic User Description）常常直接
            // 写着「Audio」「Voice」——对厂商自定义 UUID 来说，这是唯一
            // 不用猜的线索。
            peripheral.discoverDescriptors(for: characteristic)

            if characteristic.properties.contains(.read) {
                pendingReads.insert(characteristic.uuid)
                peripheral.readValue(for: characteristic)
            }
            if characteristic.properties.contains(.notify)
                || characteristic.properties.contains(.indicate) {
                subscribedCharacteristics.append(characteristic.uuid)
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverDescriptorsFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard self.peripheral === peripheral, error == nil else { return }
        for descriptor in characteristic.descriptors ?? [] {
            peripheral.readValue(for: descriptor)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor descriptor: CBDescriptor,
        error: Error?
    ) {
        guard self.peripheral === peripheral, error == nil else { return }
        guard let value = descriptor.value else { return }
        let text: String
        if let string = value as? String {
            text = string
        } else if let data = value as? Data {
            text = BLEScanFormatter.hex(data, limit: 16)
        } else {
            text = String(describing: value)
        }
        log("DESC char=\(BLEScanFormatter.describeUUID(descriptor.characteristic?.uuid ?? descriptor.uuid))"
            + " uuid=\(BLEScanFormatter.describeUUID(descriptor.uuid)) value=\(text)")
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard self.peripheral === peripheral else { return }
        if let error {
            log("订阅失败 uuid=\(BLEScanFormatter.describeUUID(characteristic.uuid)) "
                + "error=\(error.localizedDescription)")
            return
        }
        log("订阅\(characteristic.isNotifying ? "成功" : "已取消") "
            + "uuid=\(BLEScanFormatter.describeUUID(characteristic.uuid))")
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard self.peripheral === peripheral else { return }
        if let error {
            // 读失败大多是「需要加密链路」。不静默吞掉：一个读不到的特征
            // 与一个没有值的特征，含义完全不同。
            log("读取失败 uuid=\(BLEScanFormatter.describeUUID(characteristic.uuid)) "
                + "error=\(error.localizedDescription)")
            pendingReads.remove(characteristic.uuid)
            return
        }
        let data = characteristic.value ?? Data()

        if pendingReads.remove(characteristic.uuid) != nil {
            log("READ uuid=\(BLEScanFormatter.describeUUID(characteristic.uuid)) "
                + "len=\(data.count) hex=\(BLEScanFormatter.hex(data))")
            return
        }

        // 通知：主日志走限流，原始字节一个不少地进文件。
        fileLog?.write(
            "RAW uuid=\(characteristic.uuid.uuidString) len=\(data.count) "
                + "hex=\(BLEScanFormatter.hex(data, limit: .max))"
        )
        for line in notifications.record(uuid: characteristic.uuid, data: data, at: Date()) {
            AppLogger.shared.log(line)
        }
    }
}
