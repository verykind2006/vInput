import Foundation
import Testing

@testable import vInput

/// `scripts/mouse-decode.sh` 的超长会话剔除。
///
/// # 为什么值得为一个开发脚本写测试
///
/// 那条时长上限是 2026-08-18 那次 11 分钟环境音之后加的，而它**跳过的只是
/// 解码**：`cp "$LOG" "$OUT/capture.log"` 无条件排在判断之前，于是那 11 分钟
/// 的原始十六进制仍然完整躺在 `capture.log` 里，只是没解成 WAV。
/// 脚本打的那行「不解码不落盘」是假的。独立验收 2026-08-18 指出（P2）。
///
/// 修好之后必须有东西钉住它：这条路径**只有在真的误触了长按开麦时才会被
/// 走到**，也就是说没人会在日常使用中发现它退化了。把脚本里那段 Python
/// 抠出来喂合成日志，是唯一能在 CI 里跑的验法。
///
/// 只需要 python3（macOS 自带），不需要 ffmpeg，也不加载任何模型。
@Suite("mouse-decode 的超长会话剔除")
struct MouseDecodeRedactionTests {
    static let audioUUID = "0783B03E-8535-B5A0-7140-A304D2495CB8"

    /// 把脚本里的 Python 抠出来。
    ///
    /// 抠而不是复制一份：复制的那份会和脚本各自漂移，而漂移的表现恰恰是
    /// 「测试全绿但脚本还在落盘」。
    static func embeddedPython() throws -> String {
        let script = try String(
            contentsOf: BenchManifest.repositoryRoot
                .appendingPathComponent("scripts/mouse-decode.sh"),
            encoding: .utf8
        )
        let opener = "python3 - \"$OUT\" \"$MODEL_FOLDER\" \"$LOG\" <<'PY'\n"
        guard let start = script.range(of: opener),
              let end = script.range(of: "\nPY\n", range: start.upperBound..<script.endIndex)
        else {
            throw ExtractionFailure.notFound
        }
        return String(script[start.upperBound..<end.lowerBound])
    }

    enum ExtractionFailure: Error { case notFound }

    private static func stamp(_ seconds: Double) -> String {
        let hour = Int(seconds) / 3600
        let minute = (Int(seconds) % 3600) / 60
        let second = seconds - Double(hour * 3600 + minute * 60)
        return String(format: "08-18 %02d:%02d:%06.3f", hour, minute, second)
    }

    private static func controlLine(_ code: UInt8, at seconds: Double) -> String {
        let bytes: [UInt8] = [
            0x0A, 0x77, 0xFF, 0x34, 0x1B, code, 0x0A, 0x06, 0x07, 0x09,
            0xC9, 0x00, 0xA9, 0x10, 0x04, 0xC5, 0x44,
        ]
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        return "\(stamp(seconds))  RAW uuid=\(audioUUID) len=17 hex=\(hex)"
    }

    private static func audioLine(at seconds: Double) -> String {
        let hex = (0..<128).map { String(format: "%02X", $0 % 256) }.joined(separator: " ")
        return "\(stamp(seconds))  RAW uuid=\(audioUUID) len=128 hex=\(hex)"
    }

    /// 一份合成抓包：一次正常的 0.6 秒听写，加一次 200 秒的 `0x31` 长按开麦。
    private static func syntheticCapture() -> String {
        var lines: [String] = []
        var now = 3600.0
        lines.append(controlLine(0x21, at: now))
        for _ in 0..<20 {
            now += 0.03
            lines.append(audioLine(at: now))
        }
        now += 0.03
        lines.append(controlLine(0x22, at: now))

        now += 1
        let unpairedStart = now
        lines.append(controlLine(0x31, at: now))
        for index in 0..<300 {
            lines.append(audioLine(at: unpairedStart + 0.5 + Double(index) * 0.66))
        }
        lines.append(controlLine(0x21, at: unpairedStart + 200))
        return lines.joined(separator: "\n") + "\n"
    }

    @Test("超长会话的原始十六进制不进快照，正常会话一行不少")
    func redactsOverlongSessionsFromSnapshot() throws {
        let python = try Self.embeddedPython()

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mouse-decode-test-\(UUID().uuidString)", isDirectory: true)
        let out = directory.appendingPathComponent("MouseDecode", isDirectory: true)
        try FileManager.default.createDirectory(
            at: out.appendingPathComponent("sbc"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: out.appendingPathComponent("wav"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("ble-scan-synthetic.log")
        try Self.syntheticCapture().write(to: source, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", "-c", python, out.path, "/not/used/model", source.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "脚本里的 Python 跑挂了：\n\(output)")

        let snapshot = try String(
            contentsOf: out.appendingPathComponent("capture.log"), encoding: .utf8
        )
        let audioLines = snapshot.split(separator: "\n").filter { $0.contains("len=128") }

        // 正常那段的 20 个包必须还在——快照要能复现同一批 WAV
        #expect(
            audioLines.count == 20,
            "快照里应当只剩正常会话的 20 个音频包，实际 \(audioLines.count) 个"
        )
        // 剔除要留痕：一份少了几百行而不说明的快照，比不剔除更容易误导人
        #expect(snapshot.contains("【已剔除】"))
        #expect(snapshot.contains("300 行"))

        // 源日志一个字节都不动——删用户的原始记录不是这个脚本的权限
        let original = try String(contentsOf: source, encoding: .utf8)
        #expect(original.split(separator: "\n").filter { $0.contains("len=128") }.count == 320)

        // 屏幕上那段话也不能说反
        #expect(output.contains("未被改动"))
    }
}
