import Foundation
import Testing

@testable import vInput

/// HID 探针的失控流自我保护。
///
/// # 为什么它也需要
///
/// `BLEScanner.stopRunawayStream` 只停自己**不停探针**，而两者
/// **写同一个文件**（`AppModel.startBLEScan` 把同一个 `BLEScanFileLog`
/// 传给两边）。于是「GATT 那条被掐断了」不等于「不再落盘」。
///
/// 目前 HID 侧落的是报文不是音频，但探针自己的文件头就写着
/// 「**音频完全可能就搭着 HID 报文走**」——这条诊断存在的全部理由就是
/// 「GATT 那边可能一无所获」。一道守卫都不给它，等于赌那句话是错的。
/// 独立验收 2026-08-18 指出（P4）。
@Suite("HID 探针的失控流自我保护")
@MainActor
struct HIDReportProbeGuardTests {
    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func makeLog() throws -> (BLEScanFileLog, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hid-probe-test-\(UUID().uuidString)", isDirectory: true)
        let log = try #require(BLEScanFileLog(directory: directory, name: "scan.log"))
        return (log, directory)
    }

    @Test("报文流不间断超过上限时停下来，并且此后一个字节都不再落盘")
    func stopsRunawayReportStream() throws {
        let (fileLog, directory) = try makeLog()
        defer { try? FileManager.default.removeItem(at: directory) }

        let probe = HIDReportProbe(targetName: "iMouse", fileLog: fileLog)
        var companionStopped = false
        probe.onRunawayStop = { companionStopped = true }

        let report = Data(repeating: 0xAB, count: 20)
        var firedAt: TimeInterval?
        for step in stride(from: 0.0, through: 200, by: 0.03) where firedAt == nil {
            probe.handle(reportID: 1, data: report, at: at(step))
            if probe.hasStoppedRunawayStream { firedAt = step }
        }

        #expect(firedAt != nil)
        #expect((firedAt ?? 0) <= BLEScanStreamGuard.maxBurstDuration + 1)
        #expect(companionStopped, "GATT 那边必须一起停——两条路写的是同一个文件")

        fileLog.waitForPendingWrites()
        let before = try String(contentsOfFile: fileLog.path, encoding: .utf8).count

        // 走一遍真实的收尾路径。**stop() 会清空 streamGuards**，之后来的报文
        // 若只靠守卫拦，会拿到一份崭新的、从零计时的守卫，于是又开始落盘。
        probe.stop()
        for step in stride(from: 300.0, through: 400, by: 0.03) {
            probe.handle(reportID: 1, data: report, at: at(step))
        }
        fileLog.waitForPendingWrites()
        let after = try String(contentsOfFile: fileLog.path, encoding: .utf8).count
        #expect(after == before, "停了就是停了——之后的报文一个字节都不该再进文件")
    }

    /// **按 report ID 分开计账。**
    ///
    /// 混在一起算的话，鼠标平时的指针报文（移动一下就是一串）会不停地把
    /// 「上一个包」的时刻刷新，于是任何两个通道交织在一起都变成一整段
    /// 连续流——正常用鼠标就会撞线，而一轮真机诊断被误伤的代价是把用户
    /// 叫回来重按一轮。分开算之后，一条通道的账不会花掉另一条的额度。
    @Test("按 report ID 分开计账，指针通道不吃掉音频通道的额度")
    func accountsPerReportID() throws {
        let (fileLog, directory) = try makeLog()
        defer { try? FileManager.default.removeItem(at: directory) }

        let probe = HIDReportProbe(targetName: "iMouse", fileLog: fileLog)
        let report = Data(repeating: 0x01, count: 8)

        // 通道 1：每 5 秒来一个（空档超过 2 秒，永远是新的一段）
        for step in stride(from: 0.0, through: 600, by: 5) {
            probe.handle(reportID: 1, data: report, at: at(step))
        }
        #expect(!probe.hasStoppedRunawayStream, "稀疏的通道不该撞线")

        // 通道 2：不间断连发，只有它自己撞线
        for step in stride(from: 0.0, through: 200, by: 0.03) {
            probe.handle(reportID: 2, data: report, at: at(step))
        }
        #expect(probe.hasStoppedRunawayStream)
    }

    /// 正常按键那种「按一下、松开、再按一下」不该被误伤。
    @Test("按十次每次五秒不会误伤")
    func normalPressesAreNotHarmed() throws {
        let (fileLog, directory) = try makeLog()
        defer { try? FileManager.default.removeItem(at: directory) }

        let probe = HIDReportProbe(targetName: "iMouse", fileLog: fileLog)
        let report = Data(repeating: 0x02, count: 8)
        var now: TimeInterval = 0
        for _ in 0..<10 {
            for step in stride(from: 0.0, through: 5, by: 0.03) {
                probe.handle(reportID: 3, data: report, at: at(now + step))
            }
            now += 15
        }
        #expect(!probe.hasStoppedRunawayStream)
    }
}
