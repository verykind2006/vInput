import Foundation
import Testing
@testable import vInput

@Suite("HID 报文解析")
struct HIDReportParserTests {
    @Test("解析出按下的 usage 集合")
    func parsesUsages() {
        // 小端 UInt16：0x00F1 = 返回键
        let data = Data([0xF1, 0x00, 0x00, 0x00])
        #expect(HIDReportParser.usages(reportID: 1, data: data) == [0x00F1])
    }

    @Test("同时按下多个键")
    func parsesMultipleUsages() {
        let data = Data([0xF1, 0x00, 0x28, 0x00])
        #expect(HIDReportParser.usages(reportID: 1, data: data) == [0x00F1, 0x0028])
    }

    @Test("长度为 7 且首字节等于 reportID 时去掉首字节")
    func stripsLeadingReportID() {
        // 首字节 0x01 是 reportID，其后 6 字节是三个 usage
        let data = Data([0x01, 0xF1, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(HIDReportParser.usages(reportID: 1, data: data) == [0x00F1])
    }

    @Test("零值不计入")
    func ignoresZeroUsages() {
        #expect(HIDReportParser.usages(reportID: 1, data: Data([0x00, 0x00])) == [])
    }

    @Test("非 1 号报文返回 nil")
    func rejectsOtherReportIDs() {
        #expect(HIDReportParser.usages(reportID: 2, data: Data([0xF1, 0x00])) == nil)
    }

    @Test("奇数长度返回 nil")
    func rejectsOddLength() {
        #expect(HIDReportParser.usages(reportID: 1, data: Data([0xF1, 0x00, 0x28])) == nil)
    }

    @Test("空数据返回 nil")
    func rejectsEmpty() {
        #expect(HIDReportParser.usages(reportID: 1, data: Data()) == nil)
    }

    @Test("返回键的 usage 常量正确")
    func backButtonUsage() {
        // 实测自上游 RemoteButtons.swift；注意它不是标准 Escape(0x29)
        #expect(HIDReportParser.backButtonUsage == 0xF1)
    }

    @Test("设备匹配常量正确")
    func deviceIdentifiers() {
        #expect(HIDReportParser.vendorID == 0x2717)    // 小米
        #expect(HIDReportParser.productID == 0x32B8)
    }
}
