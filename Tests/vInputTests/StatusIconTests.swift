import AppKit
import Testing
@testable import vInput

struct StatusIconTests {
    /// 加载中优先级最高：加载期菜单一点即关，图标是唯一反馈（沿用旧逻辑，
    /// 见 vInputApp.swift 原 iconName 注释）。
    @Test func loadingOverridesEverything() {
        #expect(StatusIcon.state(loadingModelName: "qwen", phase: .idle) == .loadingModel)
        #expect(StatusIcon.state(loadingModelName: "qwen", phase: .listening) == .loadingModel)
        #expect(StatusIcon.state(loadingModelName: "qwen", phase: .error("x")) == .loadingModel)
    }

    @Test func phaseMapsToIconState() {
        #expect(StatusIcon.state(loadingModelName: nil, phase: .idle) == .idle)
        #expect(StatusIcon.state(loadingModelName: nil, phase: .listening) == .listening)
        #expect(StatusIcon.state(loadingModelName: nil, phase: .working) == .working)
        #expect(StatusIcon.state(loadingModelName: nil, phase: .error("x")) == .error)
    }

    /// 听写中与出错是彩色图（非模板）：琥珀橙/红点无法用模板表达。
    /// 其余是模板图，自动适应深浅菜单栏。
    @Test func templateFlags() {
        #expect(StatusIcon.isTemplate(.idle))
        #expect(StatusIcon.isTemplate(.working))
        #expect(StatusIcon.isTemplate(.loadingModel))
        #expect(!StatusIcon.isTemplate(.listening))
        #expect(!StatusIcon.isTemplate(.error))
    }

    @Test @MainActor func imagesAreMenuBarSizedAndFlagged() {
        for state in [StatusIcon.State.idle, .listening, .working, .error, .loadingModel] {
            let image = StatusIcon.image(for: state)
            #expect(image.size == NSSize(width: 18, height: 18))
            #expect(image.isTemplate == StatusIcon.isTemplate(state))
        }
    }
}
