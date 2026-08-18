import CoreBluetooth
import Foundation
import Testing

@testable import vInput

/// BLE 扫描诊断的纯逻辑部分。
///
/// 分成「纯值类型 + CoreBluetooth 外壳」两层正是为了这些测试：真机扫描
/// 需要用户按鼠标上的键，一轮就是一次往返；把格式化、UUID 比对、限流
/// 这些容易写错的部分挪到能自动跑的一侧，真机那一轮就只用来验「线通不通」。
@Suite("BLE 扫描诊断")
struct BLEScanReportTests {

    // MARK: - 特征属性

    @Test("属性按固定顺序展开，便于跨次扫描比对")
    func propertiesAreOrdered() {
        let properties: CBCharacteristicProperties = [.notify, .read, .writeWithoutResponse]
        #expect(BLEScanFormatter.describe(properties) == "read,writeWithoutResponse,notify")
    }

    @Test("没有任何属性时给出可见的占位符，而不是空字符串")
    func emptyPropertiesArePlaceholder() {
        #expect(BLEScanFormatter.describe([]) == "无")
    }

    @Test("indicate 与 notify 分开列出")
    func indicateIsDistinctFromNotify() {
        #expect(BLEScanFormatter.describe([.indicate]) == "indicate")
        #expect(BLEScanFormatter.describe([.notify, .indicate]) == "notify,indicate")
    }

    // MARK: - 十六进制

    @Test("十六进制大写、空格分隔")
    func hexIsUppercaseSpaceSeparated() {
        #expect(BLEScanFormatter.hex(Data([0x0A, 0x01, 0x00, 0xFF])) == "0A 01 00 FF")
    }

    @Test("空数据不输出空字符串")
    func emptyHexIsPlaceholder() {
        #expect(BLEScanFormatter.hex(Data()) == "（空）")
    }

    /// 音频包一秒能来几十个，全量打进主日志会把它冲掉。截断保留头部——
    /// 协议头几乎总在前几个字节，尾部是载荷。
    @Test("超长数据截断并标注剩余字节数")
    func hexTruncates() {
        let data = Data((0..<8).map(UInt8.init))
        #expect(BLEScanFormatter.hex(data, limit: 4) == "00 01 02 03 …(+4)")
    }

    // MARK: - 特征行

    @Test("特征行含服务、UUID、属性；无值时明示")
    func characteristicLineWithoutValue() {
        let found = ScannedCharacteristic(
            serviceUUID: CBUUID(string: "180F"),
            uuid: CBUUID(string: "2A19"),
            properties: [.read, .notify],
            value: nil
        )
        #expect(
            BLEScanFormatter.line(for: found)
                == "BLESCAN CHAR service=180F(电池服务) uuid=2A19(电量) props=read,notify value=未读到"
        )
    }

    @Test("特征行带值时给出长度与十六进制")
    func characteristicLineWithValue() {
        let found = ScannedCharacteristic(
            serviceUUID: CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664"),
            uuid: CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664"),
            properties: [.notify],
            value: Data([0x0B, 0x01, 0x00])
        )
        let line = BLEScanFormatter.line(for: found)
        #expect(line.contains("uuid=AB5E0004-5A21-4F05-BC7D-AF01F617B664(ATVV 控制)"))
        #expect(line.contains("len=3"))
        #expect(line.contains("hex=0B 01 00"))
    }

    /// 未知 UUID 不加括号注释——加个「(未知)」只是噪音，而这些恰恰是
    /// 要人肉去查的那些。
    @Test("未知 UUID 不追加标注")
    func unknownUUIDHasNoLabel() {
        #expect(BLEScanKnownUUIDs.label(for: CBUUID(string: "FF01")) == nil)
        #expect(BLEScanFormatter.describeUUID(CBUUID(string: "FF01")) == "FF01")
    }

    @Test("已知 UUID 带中文标注")
    func knownUUIDsAreLabeled() {
        #expect(BLEScanKnownUUIDs.label(for: CBUUID(string: "180A")) == "设备信息服务")
        #expect(BLEScanKnownUUIDs.label(for: CBUUID(string: "1812")) == "HID over GATT")
        #expect(
            BLEScanKnownUUIDs.label(for: CBUUID(string: ATVVProtocol.audioUUID)) == "ATVV 音频"
        )
    }

    // MARK: - ATVV 指纹

    /// 这是整个诊断要回答的第二个问题：讲不讲 ATVV。讲，M3 的解码器与
    /// 状态机大部分能直接复用；不讲，等于重做一遍 M3。
    @Test("四个 UUID 全中 → 完全匹配")
    func fullATVVMatch() {
        let fingerprint = ATVVFingerprint.evaluate(
            services: [CBUUID(string: ATVVProtocol.serviceUUID)],
            characteristics: [
                CBUUID(string: ATVVProtocol.transmitUUID),
                CBUUID(string: ATVVProtocol.audioUUID),
                CBUUID(string: ATVVProtocol.controlUUID),
            ]
        )
        #expect(fingerprint.verdict == .full)
        #expect(fingerprint.missingCharacteristics.isEmpty)
        #expect(fingerprint.summary.contains("完全匹配"))
    }

    @Test("有服务但特征缺一 → 部分匹配，且列出缺的那个")
    func partialATVVMatch() {
        let fingerprint = ATVVFingerprint.evaluate(
            services: [CBUUID(string: ATVVProtocol.serviceUUID)],
            characteristics: [
                CBUUID(string: ATVVProtocol.transmitUUID),
                CBUUID(string: ATVVProtocol.audioUUID),
            ]
        )
        #expect(fingerprint.verdict == .partial)
        #expect(fingerprint.missingCharacteristics == [CBUUID(string: ATVVProtocol.controlUUID)])
        #expect(fingerprint.summary.contains(ATVVProtocol.controlUUID))
    }

    /// 服务没扫到但特征在（有些设备把这几个特征挂在另一个服务下），
    /// 仍算部分匹配——这种情况下 ATVV 的报文格式多半照旧可用。
    @Test("只有特征没有服务，仍算部分匹配")
    func characteristicsWithoutService() {
        let fingerprint = ATVVFingerprint.evaluate(
            services: [CBUUID(string: "180F")],
            characteristics: [CBUUID(string: ATVVProtocol.audioUUID)]
        )
        #expect(fingerprint.hasService == false)
        #expect(fingerprint.verdict == .partial)
    }

    @Test("一个都不中 → 不匹配")
    func noATVVMatch() {
        let fingerprint = ATVVFingerprint.evaluate(
            services: [CBUUID(string: "1812"), CBUUID(string: "180F")],
            characteristics: [CBUUID(string: "2A19")]
        )
        #expect(fingerprint.verdict == .none)
        #expect(fingerprint.summary.contains("不匹配"))
        #expect(fingerprint.summary.contains("重做一遍 M3"))
    }

    // MARK: - 目标设备匹配

    @Test("按名字匹配目标，大小写与空白不敏感")
    func targetMatching() {
        #expect(BLEScanTargetMatcher.matches(name: "iMouse", target: "iMouse"))
        #expect(BLEScanTargetMatcher.matches(name: "  IMOUSE ", target: "imouse"))
        // 精确匹配：同前缀的别人的设备一律不连。真机上用户旁边就有一台
        // iMouse2——诊断路径连错的后果比生产路径更重，它订阅全部特征并落盘。
        #expect(!BLEScanTargetMatcher.matches(name: "iMouse Pro", target: "iMouse"))
        #expect(!BLEScanTargetMatcher.matches(name: "iMouse2", target: "iMouse"))
        #expect(!BLEScanTargetMatcher.matches(name: "Magic Mouse", target: "iMouse"))
        #expect(!BLEScanTargetMatcher.matches(name: nil, target: "iMouse"))
        #expect(!BLEScanTargetMatcher.matches(name: "iMouse", target: ""))
    }

    /// **绝不能连上遥控器。** 用户每天在用它听写，扫描器抢走连接
    /// 等于把主功能弄坏——诊断工具不该有这种代价。
    @Test("遥控器的名字一律拒绝，哪怕目标名配置错了")
    func remoteIsNeverATarget() {
        #expect(BLEScanTargetMatcher.isForbidden(name: "MI RC"))
        #expect(BLEScanTargetMatcher.isForbidden(name: "小米蓝牙语音遥控器"))
        #expect(BLEScanTargetMatcher.isForbidden(name: "Xiaomi Bluetooth Remote 2 Pro"))
        #expect(!BLEScanTargetMatcher.isForbidden(name: "iMouse"))
        #expect(!BLEScanTargetMatcher.isForbidden(name: nil))
    }

    @Test("目标名配成遥控器时，禁止名单优先")
    func forbiddenBeatsTarget() {
        #expect(!BLEScanTargetMatcher.isTarget(name: "MI RC", target: "MI RC"))
        #expect(BLEScanTargetMatcher.isTarget(name: "iMouse", target: "iMouse"))
    }

    // MARK: - 通知限流

    /// 16 kHz ADPCM 一秒约 65 个包。全量写进主日志会把用户日常那条日志
    /// 冲成一片十六进制——而用户正是要把这份日志发回来看的。
    /// 前几个包给全量（协议头在这里），之后按秒汇总。
    @Test("每个特征前若干包给全量十六进制")
    func firstPacketsAreDetailed() {
        var log = BLEScanNotificationLog()
        let uuid = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
        let start = Date(timeIntervalSince1970: 0)

        var lines: [String] = []
        for index in 0..<BLEScanNotificationLog.detailedPacketCount {
            lines += log.record(
                uuid: uuid,
                data: Data([UInt8(index)]),
                at: start.addingTimeInterval(Double(index) * 0.01)
            )
        }
        #expect(lines.count == BLEScanNotificationLog.detailedPacketCount)
        #expect(lines[0].contains("#1"))
        #expect(lines[0].contains("len=1"))
        #expect(lines[0].contains("hex=00"))
        #expect(lines.last?.contains("#\(BLEScanNotificationLog.detailedPacketCount)") == true)
    }

    @Test("超过全量额度后不再逐包输出，改为按秒汇总")
    func laterPacketsAggregate() {
        var log = BLEScanNotificationLog()
        let uuid = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
        let start = Date(timeIntervalSince1970: 0)

        for index in 0..<BLEScanNotificationLog.detailedPacketCount {
            _ = log.record(uuid: uuid, data: Data([0x01]), at: start)
            _ = index
        }

        // 窗口内的包一律沉默。
        var quiet: [String] = []
        for offset in 0..<10 {
            quiet += log.record(
                uuid: uuid,
                data: Data([0x02, 0x03]),
                at: start.addingTimeInterval(0.05 * Double(offset))
            )
        }
        #expect(quiet.isEmpty)

        // 跨过一秒才吐一条汇总。
        let summary = log.record(uuid: uuid, data: Data([0x04, 0x05]), at: start.addingTimeInterval(1.2))
        #expect(summary.count == 1)
        #expect(summary[0].contains("汇总"))
        #expect(summary[0].contains("11 包"))
        #expect(summary[0].contains("22 字节"))
    }

    @Test("不同特征各自计数，互不影响")
    func perCharacteristicCounters() {
        var log = BLEScanNotificationLog()
        let audio = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
        let control = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")
        let start = Date(timeIntervalSince1970: 0)

        for _ in 0..<BLEScanNotificationLog.detailedPacketCount {
            _ = log.record(uuid: audio, data: Data([0x01]), at: start)
        }
        let controlLines = log.record(uuid: control, data: Data([0x09]), at: start)
        #expect(controlLines.count == 1)
        #expect(controlLines[0].contains("#1"))
    }

    /// 收尾必须报总数：用户按了一次语音键，到底哪个特征来了数据、来了
    /// 多少，是这次诊断的第三个问题的直接答案。
    @Test("收尾输出每个特征的合计，按 UUID 排序保证可复现")
    func flushReportsTotals() {
        var log = BLEScanNotificationLog()
        let audio = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
        let control = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")
        let start = Date(timeIntervalSince1970: 0)

        for _ in 0..<3 {
            _ = log.record(uuid: control, data: Data([0x01, 0x02]), at: start)
        }
        for _ in 0..<20 {
            _ = log.record(uuid: audio, data: Data(repeating: 0xAB, count: 10), at: start)
        }

        let lines = log.flush(at: start.addingTimeInterval(2))
        let totals = lines.filter { $0.contains("合计") }
        #expect(totals.count == 2)
        #expect(totals[0].contains("AB5E0003"))
        #expect(totals[0].contains("20 包"))
        #expect(totals[0].contains("200 字节"))
        #expect(totals[1].contains("AB5E0004"))
        #expect(totals[1].contains("3 包"))
        #expect(totals[1].contains("6 字节"))
    }

    @Test("没收到任何通知时，收尾明确说「一个包都没有」")
    func flushWithoutTrafficIsExplicit() {
        var log = BLEScanNotificationLog()
        let lines = log.flush(at: Date(timeIntervalSince1970: 0))
        #expect(lines.count == 1)
        #expect(lines[0].contains("一个通知包都没收到"))
    }

    @Test("收尾后再收包，从头计数——第二轮按键要能重新看到全量头部")
    func flushResetsCounters() {
        var log = BLEScanNotificationLog()
        let uuid = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
        let start = Date(timeIntervalSince1970: 0)
        _ = log.record(uuid: uuid, data: Data([0x01]), at: start)
        _ = log.flush(at: start)
        let lines = log.record(uuid: uuid, data: Data([0x02]), at: start)
        #expect(lines.count == 1)
        #expect(lines[0].contains("#1"))
    }

    /// HID 侧诊断复用同一套限流与计数，只换行首标签。复制一份的话两条
    /// 诊断路径迟早各自漂移，而它们本来就是一回事。
    @Test("换标签后 HID 报文走同一套限流")
    func hidVariantSharesThrottling() {
        var log = BLEScanNotificationLog(
            tag: "HIDPROBE report",
            emptyMessage: "BLESCAN HIDPROBE 一个 HID 报文都没收到"
        )
        let start = Date(timeIntervalSince1970: 0)
        let lines = log.record(channel: "1", data: Data([0x01, 0x02]), at: start)
        #expect(lines == ["BLESCAN HIDPROBE report=1 #1 len=2 hex=01 02"])

        for _ in 0..<BLEScanNotificationLog.detailedPacketCount {
            _ = log.record(channel: "1", data: Data([0xFF]), at: start)
        }
        let aggregated = log.record(channel: "1", data: Data([0xFF]), at: start.addingTimeInterval(1.5))
        #expect(aggregated.count == 1)
        #expect(aggregated[0].hasPrefix("BLESCAN HIDPROBE report=1 汇总"))
    }

    @Test("空标签变体用自己的收尾话术")
    func hidVariantHasOwnEmptyMessage() {
        var log = BLEScanNotificationLog(
            tag: "HIDPROBE report",
            emptyMessage: "BLESCAN HIDPROBE 一个 HID 报文都没收到"
        )
        #expect(log.flush(at: Date()) == ["BLESCAN HIDPROBE 一个 HID 报文都没收到"])
    }

    // MARK: - 原始包落盘

    /// 主日志被限流了，但原始字节必须一个不少地留下来：拿到之后就能离线
    /// 试解码（比如按 ADPCM 试跑），不必再拉用户按一轮键。
    @Test("原始包写到独立文件，一行一包")
    func fileLogWritesEveryPacket() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ble-scan-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileLog = try #require(BLEScanFileLog(directory: directory, name: "scan.log"))
        fileLog.write("第一行")
        fileLog.write("第二行")
        fileLog.waitForPendingWrites()

        let contents = try String(contentsOfFile: fileLog.path, encoding: .utf8)
        let lines = contents.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("第一行"))
        #expect(lines[1].hasSuffix("第二行"))
    }

    @Test("文件日志每行带时间戳，用来对按键时刻")
    func fileLogLinesAreTimestamped() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ble-scan-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileLog = try #require(BLEScanFileLog(directory: directory, name: "scan.log"))
        fileLog.write("x")
        fileLog.waitForPendingWrites()

        let contents = try String(contentsOfFile: fileLog.path, encoding: .utf8)
        // "MM-dd HH:mm:ss.SSS  x"
        #expect(contents.count > 20)
        #expect(contents.hasSuffix("  x\n"))
    }

    // MARK: - 开关

    /// 与 `VINPUT_BENCH` 同一个路子：默认不启用，日志里留一行说明这次
    /// 启动到底读到了什么——菜单项藏没藏住只能靠肉眼，日志能事后核对。
    @Test("默认不启用，只有环境变量为 1 才开")
    func gatingIsOptIn() {
        #expect(!BLEScanGate.isEnabled(environment: [:]))
        #expect(!BLEScanGate.isEnabled(environment: ["VINPUT_BLE_SCAN": "0"]))
        #expect(!BLEScanGate.isEnabled(environment: ["VINPUT_BLE_SCAN": "true"]))
        #expect(BLEScanGate.isEnabled(environment: ["VINPUT_BLE_SCAN": "1"]))
    }

    @Test("目标名可被环境变量覆盖，默认 iMouse")
    func targetNameDefaultsToIMouse() {
        #expect(BLEScanGate.targetName(environment: [:]) == "iMouse")
        #expect(BLEScanGate.targetName(environment: ["VINPUT_BLE_SCAN_NAME": "MX Master"]) == "MX Master")
        // 空值当没配，否则会退化成「匹配所有设备」
        #expect(BLEScanGate.targetName(environment: ["VINPUT_BLE_SCAN_NAME": "  "]) == "iMouse")
    }
}

@Suite("扫描器的失控流自我保护")
struct BLEScanStreamGuardTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// 2026-08-18：0x31 触发后设备持续送流 11 分钟，把用户不知情的房间
    /// 环境音全写进了抓包文件。判据是「连续流的时长」，90 秒与
    /// scripts/mouse-decode.sh 取同一个数。
    @Test("不间断收流超过上限时报停")
    func stopsRunawayStream() {
        var guardian = BLEScanStreamGuard()
        var stoppedAt: TimeInterval?

        // 每 30 ms 一个包（实测的音频包间隔），一直发 11 分钟
        for step in stride(from: 0.0, through: 660, by: 0.03) {
            if case .burst = guardian.record(at: at(step)) {
                stoppedAt = step
                break
            }
        }

        #expect(stoppedAt != nil)
        #expect((stoppedAt ?? 0) >= BLEScanStreamGuard.maxBurstDuration)
        #expect((stoppedAt ?? 0) < BLEScanStreamGuard.maxBurstDuration + 1)
    }

    /// 诊断的正常用法是按几秒、松开、再按几秒。空档超过阈值就当新一段
    /// 开始，所以按十次也不会误伤。
    @Test("按十次每次五秒不会误伤")
    func doesNotFireOnNormalUsage() {
        var guardian = BLEScanStreamGuard()
        var now: TimeInterval = 0

        for _ in 0..<10 {
            for step in stride(from: 0.0, through: 5, by: 0.03) {
                let fired = guardian.record(at: at(now + step))
                #expect(fired == nil)
            }
            now += 5 + 10   // 松开 10 秒
        }
    }

    @Test("空档结束一段流，计时从头开始")
    func gapResetsBurst() {
        var guardian = BLEScanStreamGuard()

        for step in stride(from: 0.0, through: 80, by: 0.5) {
            let fired = guardian.record(at: at(step))
            #expect(fired == nil)
        }
        // 一个超过阈值的空档
        let resumeAt = 80 + BLEScanStreamGuard.gapEndsBurst + 1
        let afterGap = guardian.record(at: at(resumeAt))
        #expect(afterGap == nil)
        // 若空档没有重置计时，这一下（距最初已 100 多秒）就会误报
        let later = guardian.record(at: at(resumeAt + 20))
        #expect(later == nil)
    }

    @Test("单个包不会触发")
    func singlePacketIsFine() {
        var guardian = BLEScanStreamGuard()
        let fired = guardian.record(at: t0)
        #expect(fired == nil)
        #expect(guardian.burstDuration(at: t0) == 0)
    }

    @Test("reset 清掉当前这一段")
    func resetClearsBurst() {
        var guardian = BLEScanStreamGuard()
        for step in stride(from: 0.0, through: 80, by: 0.5) {
            _ = guardian.record(at: at(step))
        }
        guardian.reset()
        let fired = guardian.record(at: at(80.5))
        #expect(fired == nil)
        #expect(guardian.burstDuration(at: at(80.5)) == 0)
    }

    // MARK: - 总量上限

    /// **只有单段上限挡不住无限累积。**
    ///
    /// 原实现只有 `burstStartedAt` / `lastPacketAt` 两个字段，空档超过 2 秒
    /// 就归零——于是「89 秒 + 松 3 秒 + 89 秒 + 松 3 秒 …」可以一直落盘，
    /// 每一段都差一点点撞线。11 分钟那次事故完全可能以这个形状重演。
    /// 独立验收 2026-08-18 指出（P3）。
    @Test("差一点撞线的段无限重复，总量上限会兜住")
    func totalCapCatchesRepeatedNearMissBursts() {
        var guardian = BLEScanStreamGuard()
        var now: TimeInterval = 0
        var stop: BLEScanStreamGuard.Stop?

        // 每段 89 秒（差 1 秒撞不到单段上限），松 3 秒（超过 2 秒的分段阈值）
        outer: for _ in 0..<20 {
            for step in stride(from: 0.0, through: BLEScanStreamGuard.maxBurstDuration - 1, by: 0.03) {
                if let fired = guardian.record(at: at(now + step)) {
                    stop = fired
                    break outer
                }
            }
            now += BLEScanStreamGuard.maxBurstDuration - 1 + 3
        }

        guard case .total(let duration, let bursts)? = stop else {
            Issue.record("总量上限没有触发，落盘可以无限累积")
            return
        }
        #expect(duration >= BLEScanStreamGuard.maxTotalDuration)
        #expect(bursts >= 2)
    }

    /// 总量上限必须严格大于单段上限，否则单段那一档变成死代码。
    @Test("总量上限大于单段上限")
    func totalCapIsLooserThanBurstCap() {
        #expect(BLEScanStreamGuard.maxTotalDuration > BLEScanStreamGuard.maxBurstDuration)
    }

    /// 一轮诊断的正常用法（按十次、每次五秒）离总量上限还很远。
    @Test("正常用法离总量上限还很远")
    func normalUsageIsFarFromTotalCap() {
        var guardian = BLEScanStreamGuard()
        var now: TimeInterval = 0
        for _ in 0..<10 {
            for step in stride(from: 0.0, through: 5, by: 0.03) {
                #expect(guardian.record(at: at(now + step)) == nil)
            }
            now += 15
        }
        #expect(guardian.totalStreamDuration < BLEScanStreamGuard.maxTotalDuration / 2)
    }

    /// **触发之后必须彻底停止落盘。** 判据留在守卫自己身上，而不是依赖
    /// 外壳记得去 stop()——外壳那条路要经过 CoreBluetooth，测不到。
    @Test("触发之后一直报停")
    func stopIsLatched() {
        var guardian = BLEScanStreamGuard()
        var stoppedAt: TimeInterval?
        for step in stride(from: 0.0, through: 200, by: 0.03) where stoppedAt == nil {
            if guardian.record(at: at(step)) != nil { stoppedAt = step }
        }
        #expect(stoppedAt != nil)

        // 之后哪怕隔很久再来一个包，也不该再放行
        #expect(guardian.record(at: at(5000)) != nil)
        // reset 之后才重新开始
        guardian.reset()
        #expect(guardian.record(at: at(5001)) == nil)
    }
}
