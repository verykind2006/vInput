import Foundation

/// 解析小米遥控器的 HID 输入报文。
///
/// 报文格式实测自上游 `RemoteButtons.swift`：报文 ID 必须为 1；若长度为 7
/// 且首字节等于报文 ID 则去掉首字节；其余按小端 `UInt16` 两两读出，
/// 非零者即为当前按下的 usage。
///
/// 本项目只需识别返回键，因此没有移植上游那套按键映射体系——那 1541 行的
/// 体量全在映射、手势识别、多设备档案上，而解析本身只有这十几行。
enum HIDReportParser {
    /// 遥控器的设备匹配标识。
    static let vendorID = 0x2717   // 小米
    static let productID = 0x32B8

    /// 返回键的 HID usage。
    ///
    /// **注意它不是标准的 Escape（0x29）**，因此系统不会把它变成普通按键，
    /// 本项目已有的 Carbon 全局热键接不住，必须自行监听 HID。
    static let backButtonUsage: UInt16 = 0xF1

    static func usages(reportID: UInt32, data: Data) -> Set<UInt16>? {
        guard reportID == 1 else { return nil }

        var bytes = Array(data)
        if bytes.count == 7, bytes.first == UInt8(reportID) {
            bytes.removeFirst()
        }
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { return nil }

        var result = Set<UInt16>()
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let usage = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            if usage != 0 { result.insert(usage) }
        }
        return result
    }
}
