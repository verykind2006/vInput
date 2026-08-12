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

    func status() -> Status {
        // 麦克风优先：没有它连录音都开始不了。
        guard microphoneAuthorized() else { return .microphoneMissing }
        guard accessibilityTrusted() else { return .accessibilityMissing }
        return .ready
    }

    /// 弹出系统麦克风授权对话框。
    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」。
    ///
    /// 辅助功能无法通过 API 申请，只能引导用户手动勾选。
    @MainActor
    func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }
}
