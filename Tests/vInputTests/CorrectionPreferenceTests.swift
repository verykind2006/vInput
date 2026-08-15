import Foundation
import Testing

@testable import vInput

@Suite("校正开关偏好")
struct CorrectionPreferenceTests {
    /// 每个测试用独立的 suite，否则测试之间会通过 UserDefaults 互相污染。
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "vinput.correction.tests.\(UUID().uuidString)")!
    }

    /// 默认关闭。校正需要额外下载一个 2 GB 级的模型并带来额外延迟，
    /// 用户没主动开启前不该承担这些成本。
    @Test("默认关闭")
    func defaultsToDisabled() {
        #expect(!CorrectionPreference(defaults: makeDefaults()).isEnabled)
    }

    @Test("开关状态持久化")
    func persistsToggle() {
        let defaults = makeDefaults()
        CorrectionPreference(defaults: defaults).isEnabled = true
        #expect(CorrectionPreference(defaults: defaults).isEnabled)
    }

    @Test("模型目录持久化")
    func persistsModelDirectory() {
        let defaults = makeDefaults()
        let url = URL(fileURLWithPath: "/tmp/qwen3-4b")
        CorrectionPreference(defaults: defaults).modelDirectory = url
        #expect(CorrectionPreference(defaults: defaults).modelDirectory == url)
    }

    @Test("未设置模型目录时为 nil")
    func modelDirectoryDefaultsToNil() {
        #expect(CorrectionPreference(defaults: makeDefaults()).modelDirectory == nil)
    }
}
