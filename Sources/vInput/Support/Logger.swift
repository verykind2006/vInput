import Foundation

/// 落盘日志。
///
/// 存在的理由：这个应用的大部分故障只在 GUI 运行时出现——切换模型失败、
/// 权限被拒、注入被目标应用拒绝——而菜单栏一点就关，状态看不到。
/// 没有日志就只能靠猜。
///
/// **不记录转写内容**，只记录事件与错误，符合 spec 的隐私要求。
/// 需要排查转写质量时由用户显式开启 `logsTranscripts`。
final class AppLogger: @unchecked Sendable {
    static let shared = AppLogger()

    /// 是否把转写文本写进日志。**默认关闭**，符合 spec 的隐私要求。
    ///
    /// 可用 `VINPUT_LOG_TRANSCRIPTS=1` 启动应用来开启，用于排查识别与
    /// 校正质量——不然日志里只有「注入成功 文本长度 8 字」，看不出
    /// 校正到底改对了没有。
    var logsTranscripts =
        ProcessInfo.processInfo.environment["VINPUT_LOG_TRANSCRIPTS"] == "1"

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.vinput.logger")
    private let formatter: DateFormatter

    private init() {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/vInput", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("vInput.log")

        formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
    }

    var path: String { fileURL.path }

    func log(_ message: String) {
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

    /// 记录转写结果。默认只记录长度，开启 `logsTranscripts` 后才记内容。
    func logTranscript(_ text: String, context: String) {
        if logsTranscripts {
            log("\(context) 文本(\(text.count)字): \(text)")
        } else {
            log("\(context) 文本长度 \(text.count) 字")
        }
    }
}
