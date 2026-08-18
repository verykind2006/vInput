import Foundation
import Testing

@testable import vInput

/// 基准集录制与听写的互斥。
///
/// 钉的是**判断**，不是接线。真要走进 `toggleBenchRecording` 得先让
/// `benchIsRecording` 为真，而那需要真启动麦克风——测试进程拿不到麦克风
/// 权限（TCC 绑 app bundle）。所以判断抽成了纯函数，这里测它；
/// **菜单/窗口到这两个函数的接线仍然只能人工验证。**
@MainActor
@Suite("基准集录制的互斥守卫")
struct BenchRecordingGuardTests {
    // MARK: - 停止永远允许

    /// 这是整条 bug 的核心。忙碌 guard 原先挡在停止分支前面，于是听写
    /// 非 idle 时连「结束录音」都点不动——麦克风一直开着、状态卡死、
    /// 而窗口已经关了，没有任何 UI 能清掉它。
    @Test("听写进行中仍然可以停止录制")
    func stopIsAllowedWhileDictating() {
        #expect(
            AppModel.benchToggleAction(isRecording: true, dictationIdle: false) == .stop
        )
    }

    @Test("空闲时停止录制照常")
    func stopIsAllowedWhenIdle() {
        #expect(
            AppModel.benchToggleAction(isRecording: true, dictationIdle: true) == .stop
        )
    }

    // MARK: - 忙碌只拦开始

    @Test("听写进行中不许开始录制")
    func startIsRejectedWhileDictating() {
        #expect(
            AppModel.benchToggleAction(isRecording: false, dictationIdle: false) == .rejectBusy
        )
    }

    @Test("空闲时可以开始录制")
    func startIsAllowedWhenIdle() {
        #expect(
            AppModel.benchToggleAction(isRecording: false, dictationIdle: true) == .start
        )
    }

    /// 用穷举写死这条不变量，免得以后有人「顺手」把忙碌判断挪回前面：
    /// **无论听写在不在跑，正在录音时的答案永远是停止。**
    @Test("正在录音时，听写状态不影响答案")
    func stopNeverDependsOnDictationState() {
        for idle in [true, false] {
            #expect(
                AppModel.benchToggleAction(isRecording: true, dictationIdle: idle) == .stop,
                "dictationIdle=\(idle) 时停止被拒了"
            )
        }
    }

    // MARK: - 蓝牙设备那条路的三个条件

    /// 原先这里只查了模型加载，注释却写着「与 ⌥D 的守卫保持一致」。
    /// ⌥D 有两条 guard，这里只有一条——于是录制中按遥控器语音键会放行，
    /// 两个 AVAudioEngine 抢同一支麦克风，并触发上面那条停止被拦的死锁。
    @Test("基准集录制中，蓝牙设备不许开始听写")
    func remoteRejectedWhileBenchRecording() {
        #expect(
            AppModel.voiceDeviceStartAllowed(
                modelLoading: false, benchRecording: true, dictationIdle: true
            ) == false
        )
    }

    @Test("模型加载中，蓝牙设备不许开始听写")
    func remoteRejectedWhileModelLoading() {
        #expect(
            AppModel.voiceDeviceStartAllowed(
                modelLoading: true, benchRecording: false, dictationIdle: true
            ) == false
        )
    }

    /// M7 加的第三条：音频源从两个变成三个，遥控器正在录时按鼠标语音键
    /// （或反过来）必须被拒。DictationSession 自己有 guard 但它是静默的，
    /// 而这边的按键抑制、路由选择、HUD 都已经按「开始了」走过一遍。
    @Test("听写进行中，另一台蓝牙设备不许再开一次")
    func remoteRejectedWhileDictating() {
        #expect(
            AppModel.voiceDeviceStartAllowed(
                modelLoading: false, benchRecording: false, dictationIdle: false
            ) == false
        )
    }

    @Test("三个条件都不成立时才放行")
    func remoteAllowedOnlyWhenAllClear() {
        #expect(
            AppModel.voiceDeviceStartAllowed(
                modelLoading: false, benchRecording: false, dictationIdle: true
            ) == true
        )
        // 同时成立也必须拒——写出来是因为「或」写成「与」时，
        // 上面几条单独看都还是绿的。
        #expect(
            AppModel.voiceDeviceStartAllowed(
                modelLoading: true, benchRecording: true, dictationIdle: false
            ) == false
        )
    }
}
