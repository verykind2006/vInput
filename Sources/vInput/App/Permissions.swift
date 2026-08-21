import AVFoundation
import AppKit
import ApplicationServices
import Foundation

/// 应用运行所需的两项系统权限。
///
/// 不需要「输入监控」——全局快捷键走 Carbon RegisterEventHotKey，
/// 该 API 无隐私授权要求。
struct Permissions {
    enum Status: Equatable {
        case ready
        case microphoneMissing
        case accessibilityMissing
    }

    var microphoneAuthorized: () -> Bool = {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var accessibilityTrusted: () -> Bool = {
        AXIsProcessTrusted()
    }

    /// 弹系统麦克风授权框这个**动作**本身。
    ///
    /// 与上面两个查询一样做成可注入的闭包（M9 批次二 Task 6 复审 I-3）：
    /// 不注入的话，「授权之后向导会不会自己翻页」只能靠真机点一次才知道，
    /// 而那是新用户接触到的第二样东西——本该被测试守住。
    var requestMicrophoneAccess: @Sendable () async -> Bool = {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// 打开系统设置这个**动作**本身。理由同上：注入之后才测得到
    /// 「点这个按钮时轮询确实在跑」。
    var openAccessibilitySettingsAction: @MainActor () -> Void = {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }

    func status() -> Status {
        // 麦克风优先：没有它连录音都开始不了。
        guard microphoneAuthorized() else { return .microphoneMissing }
        guard accessibilityTrusted() else { return .accessibilityMissing }
        return .ready
    }

    /// 弹出系统麦克风授权对话框。
    func requestMicrophone() async -> Bool {
        await requestMicrophoneAccess()
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」。
    ///
    /// 辅助功能无法通过 API 申请，只能引导用户手动勾选。
    @MainActor
    func openAccessibilitySettings() {
        openAccessibilitySettingsAction()
    }
}
