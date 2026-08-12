import Testing
@testable import vInput

@Suite("Permissions")
struct PermissionsTests {
    @Test("两项权限都具备时报告 ready")
    func readyWhenAllGranted() {
        var permissions = Permissions()
        permissions.microphoneAuthorized = { true }
        permissions.accessibilityTrusted = { true }

        #expect(permissions.status() == .ready)
    }

    @Test("缺少麦克风权限时报告 microphoneMissing")
    func reportsMissingMicrophone() {
        var permissions = Permissions()
        permissions.microphoneAuthorized = { false }
        permissions.accessibilityTrusted = { true }

        #expect(permissions.status() == .microphoneMissing)
    }

    @Test("缺少辅助功能权限时报告 accessibilityMissing")
    func reportsMissingAccessibility() {
        var permissions = Permissions()
        permissions.microphoneAuthorized = { true }
        permissions.accessibilityTrusted = { false }

        #expect(permissions.status() == .accessibilityMissing)
    }

    @Test("两项都缺失时优先报告麦克风")
    func microphoneTakesPriority() {
        var permissions = Permissions()
        permissions.microphoneAuthorized = { false }
        permissions.accessibilityTrusted = { false }

        // 麦克风是录音的前提，先解决它更符合用户操作顺序
        #expect(permissions.status() == .microphoneMissing)
    }
}
