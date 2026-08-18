import CoreBluetooth
import Foundation

//  BLE GATT 扫描诊断——纯逻辑层。
//
//  这一层不碰 CoreBluetooth 的任何运行时对象（只用它的值类型 CBUUID /
//  CBCharacteristicProperties），因此全部可以在单元测试里跑。
//  外壳在 `BLEScanner.swift`。
//
//  为什么要分这一层：真机扫描的每一轮都要用户在电脑前按鼠标上的键，
//  一轮就是一次往返。格式化、UUID 比对、限流这些容易写错的部分放在
//  这里，真机那一轮就只用来验「线通不通」，而不是验「字符串拼没拼对」。

// MARK: - 开关

/// 扫描诊断的环境变量门控。
///
/// 照 `VINPUT_BENCH=1` 的路子：**默认不启用**。理由与那边一样——
/// 它会连接一台不是主功能所需的蓝牙设备并把原始字节写到磁盘，
/// 藏起来是为了让这个例外不会被误当成常态功能。
enum BLEScanGate {
    static let enableKey = "VINPUT_BLE_SCAN"
    static let nameKey = "VINPUT_BLE_SCAN_NAME"

    /// 目标设备默认名。来自用户实测的系统蓝牙面板：
    /// `iMouse / Address: C9:01:A9:10:04:C5 / Services: 0x400000 < BLE >`。
    static let defaultTargetName = "iMouse"

    static func isEnabled(environment: [String: String]) -> Bool {
        environment[enableKey] == "1"
    }

    /// 目标设备名。可用 `VINPUT_BLE_SCAN_NAME` 覆盖——换一支鼠标不必改代码。
    ///
    /// 空白值当作没配：`matches` 用的是子串包含，空串会匹配**所有**设备，
    /// 那就等于把「只连 iMouse」这条约束悄悄取消了。
    static func targetName(environment: [String: String]) -> String {
        let raw = environment[nameKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? defaultTargetName : raw
    }

    static var isEnabled: Bool { isEnabled(environment: ProcessInfo.processInfo.environment) }
    static var targetName: String { targetName(environment: ProcessInfo.processInfo.environment) }
}

// MARK: - 目标匹配

/// 决定「这台外设要不要连」。
///
/// **最重要的一条是不连什么**：用户每天在用 RC003 遥控器听写，扫描器
/// 抢走它的连接等于把主功能弄坏。诊断工具不该有这种代价，所以遥控器的
/// 名字进硬编码禁止名单，先于目标名判断——哪怕
/// `VINPUT_BLE_SCAN_NAME` 被配成 "MI RC" 也连不上去。
enum BLEScanTargetMatcher {
    static func matches(name: String?, target: String) -> Bool {
        let normalizedTarget = normalize(target)
        guard !normalizedTarget.isEmpty, let normalizedName = normalize(name), !normalizedName.isEmpty
        else { return false }
        // **相等，不是包含**——与 `MouseTargetMatcher` 保持一致。
        //
        // 原来这里和那边都写的 `contains`，理由是「广播名常带后缀」。
        // 真机推翻了它：用户旁边存在另一台 `iMouse2`，包含匹配会连上
        // **别人的设备**、订阅它全部可通知特征、把原始字节写进
        // `ble-scan-*.log`。那边已在 `8ab0554` 改成精确匹配，
        // 诊断这份漏掉了——同一个 bug 修了一半，独立验收 2026-08-18 指出。
        //
        // 诊断路径的后果比生产路径更重：它订阅的是**全部**特征并落盘。
        return normalizedName == normalizedTarget
    }

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

// MARK: - 已知 UUID

/// 给扫到的 UUID 配一句中文标注。
///
/// 只为**已知**的加标注，未知的原样打印——未知的恰恰是要人肉去查的那些，
/// 给它们加个「(未知)」只是噪音。
enum BLEScanKnownUUIDs {
    private static let labels: [CBUUID: String] = [
        CBUUID(string: "1800"): "GAP",
        CBUUID(string: "1801"): "GATT 服务",
        CBUUID(string: "180A"): "设备信息服务",
        CBUUID(string: "180F"): "电池服务",
        CBUUID(string: "1812"): "HID over GATT",
        CBUUID(string: "2A19"): "电量",
        CBUUID(string: "2A24"): "型号",
        CBUUID(string: "2A26"): "固件版本",
        CBUUID(string: "2A28"): "软件版本",
        CBUUID(string: "2A29"): "厂商",
        CBUUID(string: "2BED"): "电量状态",

        // ATVV（Android TV Voice）。这四个就是 M3 在 RC003 上跑通的那套，
        // 定义在 `ATVVProtocol`，此处只做识别。
        CBUUID(string: ATVVProtocol.serviceUUID): "ATVV 语音服务",
        CBUUID(string: ATVVProtocol.transmitUUID): "ATVV 下行(主机→设备)",
        CBUUID(string: ATVVProtocol.audioUUID): "ATVV 音频",
        CBUUID(string: ATVVProtocol.controlUUID): "ATVV 控制",

        // Nordic UART Service。第三方 BLE 麦克风/遥控器里极常见的透传通道，
        // 很多厂商懒得定义协议就直接拿它推音频。**这只是识别提示，不是
        // 断言**——扫到它只说明「这是一条串口式透传」，载荷格式仍未知。
        CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"): "Nordic UART 服务",
        CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"): "Nordic UART RX",
        CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"): "Nordic UART TX",
    ]

    static func label(for uuid: CBUUID) -> String? { labels[uuid] }
}

// MARK: - 扫描到的特征

struct ScannedCharacteristic: Equatable {
    let serviceUUID: CBUUID
    let uuid: CBUUID
    let properties: CBCharacteristicProperties
    var value: Data?
}

// MARK: - 格式化

enum BLEScanFormatter {
    /// 属性展开成固定顺序的名字。
    ///
    /// 固定顺序不是洁癖：两次扫描的输出要能直接对着看（换固件、换按键
    /// 模式），顺序一变就得逐字段比对。
    private static let propertyTable: [(CBCharacteristicProperties, String)] = [
        (.broadcast, "broadcast"),
        (.read, "read"),
        (.writeWithoutResponse, "writeWithoutResponse"),
        (.write, "write"),
        (.notify, "notify"),
        (.indicate, "indicate"),
        (.authenticatedSignedWrites, "authenticatedSignedWrites"),
        (.extendedProperties, "extendedProperties"),
        (.notifyEncryptionRequired, "notifyEncryptionRequired"),
        (.indicateEncryptionRequired, "indicateEncryptionRequired"),
    ]

    static func describe(_ properties: CBCharacteristicProperties) -> String {
        let names = propertyTable.filter { properties.contains($0.0) }.map(\.1)
        return names.isEmpty ? "无" : names.joined(separator: ",")
    }

    static func describeUUID(_ uuid: CBUUID) -> String {
        guard let label = BLEScanKnownUUIDs.label(for: uuid) else { return uuid.uuidString }
        return "\(uuid.uuidString)(\(label))"
    }

    /// 十六进制。默认截断到 32 字节并标注剩余数量。
    ///
    /// 截断保留**头部**：协议头几乎总在前几个字节，尾部是载荷。
    /// 完整字节另有去处（`BLEScanFileLog`），这里只管人眼能看的那份。
    static func hex(_ data: Data, limit: Int = 32) -> String {
        guard !data.isEmpty else { return "（空）" }
        let shown = data.prefix(limit)
        let body = shown.map { String(format: "%02X", $0) }.joined(separator: " ")
        guard data.count > limit else { return body }
        return "\(body) …(+\(data.count - limit))"
    }

    static func line(for characteristic: ScannedCharacteristic) -> String {
        var line = "BLESCAN CHAR service=\(describeUUID(characteristic.serviceUUID))"
        line += " uuid=\(describeUUID(characteristic.uuid))"
        line += " props=\(describe(characteristic.properties))"
        guard let value = characteristic.value else { return line + " value=未读到" }
        return line + " len=\(value.count) hex=\(hex(value))"
    }
}

// MARK: - ATVV 指纹

/// 把扫到的 UUID 与 `ATVVProtocol` 的四个 UUID 逐一比对。
///
/// **这是整个诊断要回答的第二个问题**，也是决定 M7 规模的那一个：
/// 讲 ATVV 的话，M3 的 `IMAADPCMDecoder`、`FrameAccumulator`、
/// `ATVVCapabilities`、`ATVVSessionGate` 与整套连接/重连状态机大部分能
/// 直接复用；不讲的话等于重做一遍 M3。
struct ATVVFingerprint: Equatable {
    enum Verdict: Equatable {
        case full
        case partial
        case none
    }

    let hasService: Bool
    let matchedCharacteristics: [CBUUID]
    let missingCharacteristics: [CBUUID]

    /// 三个特征的固定顺序：下行、音频、控制。
    static let expectedCharacteristics: [CBUUID] = [
        CBUUID(string: ATVVProtocol.transmitUUID),
        CBUUID(string: ATVVProtocol.audioUUID),
        CBUUID(string: ATVVProtocol.controlUUID),
    ]

    var verdict: Verdict {
        if hasService, missingCharacteristics.isEmpty { return .full }
        if !hasService, matchedCharacteristics.isEmpty { return .none }
        return .partial
    }

    static func evaluate(services: [CBUUID], characteristics: [CBUUID]) -> ATVVFingerprint {
        let serviceSet = Set(services)
        let characteristicSet = Set(characteristics)
        let matched = expectedCharacteristics.filter { characteristicSet.contains($0) }
        let missing = expectedCharacteristics.filter { !characteristicSet.contains($0) }
        return ATVVFingerprint(
            hasService: serviceSet.contains(CBUUID(string: ATVVProtocol.serviceUUID)),
            matchedCharacteristics: matched,
            missingCharacteristics: missing
        )
    }

    /// 一行结论，直接写进日志给人看。
    ///
    /// 把「这意味着什么」也写进去，而不只是报匹配数：读日志的人（用户）
    /// 不该需要回头翻代码才知道这一行是好消息还是坏消息。
    var summary: String {
        let head = "BLESCAN ATVV 服务=\(hasService ? "有" : "无")"
            + " 特征命中 \(matchedCharacteristics.count)/\(Self.expectedCharacteristics.count)"
        switch verdict {
        case .full:
            return head + " → 完全匹配：M3 的解码器与状态机大部分可直接复用"
        case .partial:
            let missing = missingCharacteristics.map(\.uuidString).joined(separator: ",")
            return head + " 缺=\(missing) → 部分匹配：报文格式可能通用，需逐特征核对"
        case .none:
            return head + " → 不匹配：不讲 ATVV，M7 等于重做一遍 M3"
        }
    }
}

// MARK: - 通知限流

/// 订阅到的通知按特征分组计数，并对写进主日志的量做限流。
///
/// **为什么要限流**：16 kHz 的 ADPCM 一秒约 65 个包。全量写进
/// `~/Library/Logs/vInput/vInput.log` 会把用户日常那条日志冲成一片
/// 十六进制——而用户正是要把这份日志发回来看的。
///
/// 策略：每个特征前几个包给全量十六进制（协议头在这里），之后按秒汇总。
/// 完整字节一个不少地进 `BLEScanFileLog`，两者分工。
struct BLEScanNotificationLog {
    /// 每个特征给全量十六进制的包数。5 个足以看清协议头与包长规律。
    static let detailedPacketCount = 5
    /// 汇总窗口。1 秒既能看出「按下的瞬间开始来数据」，又不会刷屏。
    static let aggregateInterval: TimeInterval = 1

    private struct Counter {
        var totalPackets = 0
        var totalBytes = 0
        var windowStart: Date?
        var windowPackets = 0
        var windowBytes = 0
    }

    /// 行首标签。GATT 通知与 HID 报文用同一套限流与计数，只有这一处不同
    /// ——复制一份等于让两条诊断路径各自漂移，而它们本来就是一回事。
    let tag: String
    /// 一个包都没收到时的那行话。
    let emptyMessage: String

    private var counters: [String: Counter] = [:]

    init(tag: String = "NOTIFY uuid", emptyMessage: String = "BLESCAN NOTIFY 一个通知包都没收到") {
        self.tag = tag
        self.emptyMessage = emptyMessage
    }

    mutating func record(uuid: CBUUID, data: Data, at now: Date) -> [String] {
        record(channel: BLEScanFormatter.describeUUID(uuid), data: data, at: now)
    }

    mutating func record(channel: String, data: Data, at now: Date) -> [String] {
        var counter = counters[channel] ?? Counter()
        counter.totalPackets += 1
        counter.totalBytes += data.count
        defer { counters[channel] = counter }

        if counter.totalPackets <= Self.detailedPacketCount {
            return [
                "BLESCAN \(tag)=\(channel)"
                    + " #\(counter.totalPackets) len=\(data.count)"
                    + " hex=\(BLEScanFormatter.hex(data))"
            ]
        }

        if counter.windowStart == nil { counter.windowStart = now }
        counter.windowPackets += 1
        counter.windowBytes += data.count

        guard let start = counter.windowStart,
              now.timeIntervalSince(start) >= Self.aggregateInterval
        else { return [] }

        let elapsed = now.timeIntervalSince(start)
        let line = "BLESCAN \(tag)=\(channel)"
            + " 汇总 \(counter.windowPackets) 包 \(counter.windowBytes) 字节"
            + "（\(String(format: "%.1f", elapsed)) 秒窗口）"
        counter.windowStart = nil
        counter.windowPackets = 0
        counter.windowBytes = 0
        return [line]
    }

    /// 收尾：吐出未满一秒的窗口，再报每个特征的合计，然后清零。
    ///
    /// 合计那几行是**第三个问题的直接答案**——用户按了一次语音键，
    /// 到底哪个特征来了数据、来了多少。清零是为了让第二轮按键能重新
    /// 看到全量的协议头。
    mutating func flush(at now: Date) -> [String] {
        guard !counters.isEmpty else { return [emptyMessage] }
        var lines: [String] = []
        for channel in counters.keys.sorted() {
            guard let counter = counters[channel] else { continue }
            if counter.windowPackets > 0 {
                let elapsed = counter.windowStart.map { now.timeIntervalSince($0) } ?? 0
                lines.append(
                    "BLESCAN \(tag)=\(channel)"
                        + " 汇总 \(counter.windowPackets) 包 \(counter.windowBytes) 字节"
                        + "（\(String(format: "%.1f", elapsed)) 秒窗口）"
                )
            }
            lines.append(
                "BLESCAN \(tag)=\(channel)"
                    + " 合计 \(counter.totalPackets) 包 \(counter.totalBytes) 字节"
            )
        }
        counters.removeAll()
        return lines
    }
}

// MARK: - 失控流自我保护

/// 长时间不间断收流时让扫描器自己停下来。
///
/// **这条是 2026-08-18 那次事故直接逼出来的。** 鼠标的 `0x31`（长按开麦）
/// 没有配对的结束码，触发后设备持续送流 **11 分钟**，把用户不知情的房间
/// 环境音全写进了抓包文件，随后还被解码脚本解成 15 MB 的 WAV 转写了一遍。
/// 用户是靠菜单栏的麦克风图标才发现的。
///
/// 教训比这支鼠标更普遍：**任何诊断工具在长时间无预期地接收数据时，都该
/// 自己停下来并告警，而不是闷头记录。** 产品路径上的对策是
/// `MouseVoiceSession` 的时长上限；`scripts/mouse-decode.sh` 已加（提交
/// `b7ca232`）；扫描器本身这一条当时列成了待办，就是这里。
///
/// 判据是「连续流的时长」而不是「总包数」：诊断的正常用法是按几秒、松开、
/// 再按几秒，包与包之间有明显的空档。空档超过 `gapEndsBurst` 就当新一段
/// 开始，所以按十次也不会误伤；而一段不间断的流超过 `maxBurstDuration`
/// 就一定不是有人按着键在说话。
struct BLEScanStreamGuard {
    /// 单段连续流的上限。与 `scripts/mouse-decode.sh` 取同一个数——
    /// 同一支设备用同一个判据，日志与脚本对得上。
    static let maxBurstDuration: TimeInterval = 90
    /// 多长的空档算「这一段结束了」。音频包间隔实测 30 ms，
    /// 2 秒比它大两个数量级，不会被抖动误判。
    static let gapEndsBurst: TimeInterval = 2

    private var burstStartedAt: Date?
    private var lastPacketAt: Date?

    /// 记一个包，返回「是否该停了」。
    mutating func record(at now: Date) -> Bool {
        if let last = lastPacketAt, now.timeIntervalSince(last) <= Self.gapEndsBurst {
            // 同一段流的延续
        } else {
            burstStartedAt = now
        }
        lastPacketAt = now
        guard let start = burstStartedAt else { return false }
        return now.timeIntervalSince(start) >= Self.maxBurstDuration
    }

    /// 当前这一段流已经持续了多久。只用于日志。
    func burstDuration(at now: Date) -> TimeInterval {
        guard let start = burstStartedAt else { return 0 }
        return now.timeIntervalSince(start)
    }

    mutating func reset() {
        burstStartedAt = nil
        lastPacketAt = nil
    }
}

// MARK: - 原始包落盘

/// 把每一个通知包的完整字节写进独立文件。
///
/// **为什么不复用 `AppLogger`**：主日志被限流了（理由见
/// `BLEScanNotificationLog`），但原始字节必须一个不少地留下来——拿到之后
/// 就能离线试解码（比如照 M3 的 `IMAADPCMDecoder` 试跑一遍），不必再拉
/// 用户按一轮键。一轮真机往返比一个文件贵得多。
///
/// **为什么不进 `~/Library/Logs/vInput/vInput.log`**：那份日志用户会整个
/// 发出来，混进几万行十六进制没法看。
final class BLEScanFileLog: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.vinput.ble-scan-log")
    private let formatter: DateFormatter

    /// - Parameters:
    ///   - directory: 落盘目录。默认 `~/Library/Logs/vInput`，与主日志同处，
    ///     用户「打开日志」时一眼能看到。
    ///   - name: 文件名。默认带启动时刻，避免两轮扫描的字节混在一起。
    init?(directory: URL? = nil, name: String? = nil) {
        let target: URL
        if let directory {
            target = directory
        } else {
            guard let logs = FileManager.default
                .urls(for: .libraryDirectory, in: .userDomainMask).first
            else { return nil }
            target = logs.appendingPathComponent("Logs/vInput", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        fileURL = target.appendingPathComponent(
            name ?? "ble-scan-\(stamp.string(from: Date())).log"
        )
    }

    var path: String { fileURL.path }

    func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async { [fileURL] in
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    /// 等待队列排空。测试用；生产路径上不需要（进程退出前的最后几行
    /// 无关紧要，而阻塞主线程会卡住退出）。
    func waitForPendingWrites() {
        queue.sync {}
    }
}
