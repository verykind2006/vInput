import Foundation
import Testing

@testable import vInput

/// 没有输入设备时，`SystemMicSource` 必须在碰 `installTap` 之前就报错。
///
/// # 为什么这条值得单独守
///
/// 2026-11-08 Mac mini（没有内置麦克风）上 ⌥D 必崩：`installTap` 抛的是
/// **ObjC 异常**，Swift 的 `do/catch` 接不住，它穿过 async 帧被 AppKit 吞掉，
/// 进程还活着、什么提示都没有，下一个键盘事件才在 event tap 回调里 SIGSEGV。
/// 崩溃报告的栈顶指向 `RemoteEchoSwallower`，**和真正的原因隔了好几层**，
/// 为此误判过一次「旧包与 macOS 27 不兼容」。
///
/// 这些测试一律注入探测结果，不碰真硬件：测试机有没有麦克风不该影响结果。
@Suite("SystemMicSource 无输入设备")
struct SystemMicSourceInputDeviceTests {
    @Test("探测到没有输入设备时，start 抛 noInputDevice")
    @MainActor
    func startThrowsWhenNoDevice() {
        let source = SystemMicSource(inputDeviceAvailable: { false })
        #expect(throws: AudioSourceError.noInputDevice) {
            try source.start()
        }
    }

    @Test("探测失败后可以再试：设备接上后不能被上一次失败卡住")
    @MainActor
    func failureDoesNotLatchRunning() {
        var probes = 0
        let source = SystemMicSource(inputDeviceAvailable: {
            probes += 1
            return false
        })
        #expect(throws: AudioSourceError.noInputDevice) { try source.start() }
        #expect(throws: AudioSourceError.noInputDevice) { try source.start() }
        // 第二次也真的探测了：`isRunning` 被误置的话，第二次会静默返回。
        #expect(probes == 2)
    }

    @Test(
        "格式校验：采样率或声道数为 0 都算没有输入设备",
        arguments: [
            (0.0, AVAudioChannelCountForTest(2)),
            (48_000.0, AVAudioChannelCountForTest(0)),
            (0.0, AVAudioChannelCountForTest(0)),
        ]
    )
    func invalidFormatIsRejected(sampleRate: Double, channels: UInt32) {
        #expect(throws: AudioSourceError.noInputDevice) {
            try SystemMicSource.validateInputFormat(sampleRate: sampleRate, channelCount: channels)
        }
    }

    @Test("格式校验：正常的单声道与双声道都放行")
    func validFormatPasses() throws {
        try SystemMicSource.validateInputFormat(sampleRate: 48_000, channelCount: 1)
        try SystemMicSource.validateInputFormat(sampleRate: 44_100, channelCount: 2)
    }

    /// 单测起不了真麦克风，顺序只能靠扫源码守。
    /// 校验排在 `installTap` 后面的话，上面那些测试照样全绿，线上照样崩。
    @Test("两道检查都排在 installTap 之前")
    func guardsPrecedeInstallTap() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/vInput/Audio/SystemMicSource.swift"),
            encoding: .utf8
        )
        let tap = try #require(source.range(of: "input.installTap(")).lowerBound
        let probe = try #require(source.range(of: "guard inputDeviceAvailable()")).lowerBound
        let format = try #require(source.range(of: "try Self.validateInputFormat(")).lowerBound
        #expect(probe < tap)
        #expect(format < tap)
    }
}

/// `@Test(arguments:)` 里写字面量 `UInt32` 的小帮手，避免元组推断成 Int。
private func AVAudioChannelCountForTest(_ value: UInt32) -> UInt32 { value }

@Suite("录音启动失败的提示")
struct DictationStartFailureMessageTests {
    @Test("没有输入设备：说人话，并告诉用户能怎么办")
    func noInputDeviceMessage() {
        let message = AppModel.startFailureMessage(for: AudioSourceError.noInputDevice)
        #expect(message.contains("麦克风"))
        #expect(message.contains("遥控器"))
        // 枚举名漏给用户就是这条修复没生效。
        #expect(!message.contains("noInputDevice"))
    }

    @Test("其他错误保持原有的描述，不被吞成麦克风提示")
    func otherErrorsKeepDescription() {
        let error = AudioSourceError.engineFailedToStart("device lost")
        let message = AppModel.startFailureMessage(for: error)
        #expect(message.contains("device lost"))
        #expect(!message.contains("遥控器"))
    }

    /// 面板收起时 `phase` 只改菜单栏图标，用户按了 ⌥D 什么都看不到，
    /// 所以 HUD 这一句不能省。
    @Test("toggle 的启动失败分支走提示文案，并亮 HUD")
    func toggleSurfacesFailure() throws {
        let source = try AppModelWiringTests.appModelSource()
        let body = try AppModelWiringTests.memberBody(source, startingAt: "func toggle() {")
        #expect(body.contains("Self.startFailureMessage(for: error)"))
        #expect(body.contains("showHUDNotice(message)"))
        #expect(body.contains("phase = .error(message)"))
    }
}
