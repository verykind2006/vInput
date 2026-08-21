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
        for state in StatusIcon.State.allCases {
            let image = StatusIcon.image(for: state)
            #expect(image.size == NSSize(width: 18, height: 18))
            #expect(image.isTemplate == StatusIcon.isTemplate(state))
        }
    }

    // MARK: - 每一档真的画出了它该画的东西（Task 9 QA 复核补）

    // 上面那条只钉了尺寸与模板标志——**画布上是什么，一个字都没测。**
    // QA 复核亲手做的两次变异都全绿（全仓 1135 条一条没红）：
    //
    // - 删掉 `if state == .error { drawBadge(...) }`：出错时那个红点角标消失，
    //   而红点是「出错了」在菜单栏上唯一的信号；
    // - 把 `state == .working ? VMark.workingBars : VMark.bars` 改成恒取
    //   `VMark.bars`：「处理中」画得和「空闲」一模一样，转写那几十秒里菜单栏
    //   完全没有反馈。
    //
    // `ThemeTests` 钉的是 `VMark.workingBars` 这组数**本身**对不对，钉不住
    // `StatusIcon` 有没有真的去用它——正是设计定稿「单测钉每档产物」那半句
    // 一直没落地的地方。下面按渲染出的位图取样点断言。
    //
    // 取样点（18×18、flipped: true，故 y 向下）：
    // - `(12, 3)` 右上角标区。x 12 落在 `bars[4]`（x 15.1 起）左侧的空白里，
    //   所以空闲档这里是**全透明**；出错档是红点本体，加载档是半透明角标。
    // - `(9, 7)` / `(9, 12)` 正中那根柱子所在的列。空闲档中间柱最矮且底对齐
    //   （y 9 才开始），处理中档中间柱垂直居中（y 6.4–9.4），两点的明暗正好
    //   互为反相——一次钉住「用的是哪组几何」。
    @MainActor
    private static func pixel(_ state: StatusIcon.State, _ x: Int, _ y: Int) throws -> NSColor {
        let image = StatusIcon.image(for: state)
        let data = try #require(image.tiffRepresentation, "\(state) 的图渲染不出位图")
        let rep = try #require(NSBitmapImageRep(data: data), "\(state) 的位图解不出来")
        return try #require(rep.colorAt(x: x, y: y), "\(state) 取 (\(x), \(y)) 取不到像素")
    }

    /// 出错必须画出红点角标——菜单栏上「出错了」的唯一信号。
    @Test @MainActor func errorStateDrawsRedBadge() throws {
        let idle = try Self.pixel(.idle, 12, 3)
        #expect(
            idle.alphaComponent < 0.01,
            "空闲档的角标区不该有东西（有的话下面那条断言就失去了对照）。")

        let badge = try Self.pixel(.error, 12, 3)
        #expect(
            badge.alphaComponent > 0.9,
            "出错档右上角没画角标——红点是菜单栏上「出错了」的唯一信号。")
        // systemRed 深浅两种外观下分别是 (1.0, 0.231, 0.188) / (1.0, 0.271, 0.227)，
        // 判据放宽到「红得明显」即可，不钉具体色值。
        let isRed = badge.redComponent > 0.8 && badge.greenComponent < 0.4
            && badge.blueComponent < 0.4
        #expect(isRed, "出错角标不是红色：\(badge)")
    }

    /// 加载中的角标是**半透明**的同色（模板图按 alpha 着色），
    /// 且必须先挖空再画——不挖的话它会和柱子融成一片，只剩一小段月牙可见。
    @Test @MainActor func loadingStateDrawsTranslucentBadge() throws {
        let badge = try Self.pixel(.loadingModel, 12, 3)
        let translucent = badge.alphaComponent > 0.3 && badge.alphaComponent < 0.6
        #expect(
            translucent,
            """
            加载档的角标 alpha 是 \(badge.alphaComponent)，不在 0.3–0.6 之间。
            画满（≈1.0）就与出错档的实心角标混淆，没画（≈0）则加载期菜单栏
            毫无反馈——而加载可能持续一两分钟，图标是那段时间唯一的信号。
            """
        )
    }

    /// 处理中必须用波形变体（中-高-低-高-中），不能退回空闲那组几何。
    @Test @MainActor func workingStateUsesWaveformGeometry() throws {
        // 中间那根柱子：空闲档底对齐（上半空、下半实），处理中档垂直居中
        // （上半实、下半空）。两点互为反相，恒取 VMark.bars 会同时压中两条。
        let idleUpper = try Self.pixel(.idle, 9, 7)
        let workingUpper = try Self.pixel(.working, 9, 7)
        #expect(
            idleUpper.alphaComponent < 0.01 && workingUpper.alphaComponent > 0.5,
            """
            (9, 7) 处空闲=\(idleUpper.alphaComponent)、处理中=\(workingUpper.alphaComponent)。
            处理中档没有用 VMark.workingBars——它画得和空闲档一样，
            转写那几十秒里菜单栏完全没有反馈。
            """
        )
        let idleLower = try Self.pixel(.idle, 9, 12)
        let workingLower = try Self.pixel(.working, 9, 12)
        #expect(
            idleLower.alphaComponent > 0.9 && workingLower.alphaComponent < 0.01,
            "(9, 12) 处空闲=\(idleLower.alphaComponent)、处理中=\(workingLower.alphaComponent)，两档的中间柱没有互为反相。"
        )
    }

    /// 听写中整体琥珀橙 `#FF9500`——「正在收音必须一眼可辨」那条的落点。
    ///
    /// 钉十六进制原值而不是 `VITheme.accent`：引用常量的话，把 accent 整个
    /// 改掉这条照样绿，而这里要守的恰恰是「菜单栏上收音的颜色没变过」。
    @Test @MainActor func listeningStateIsAmber() throws {
        let bar = try Self.pixel(.listening, 9, 12)
        #expect(bar.alphaComponent > 0.9, "听写档中间柱没画出来")
        let isAmber = abs(bar.redComponent - 1.0) < 0.02
            && abs(bar.greenComponent - 0.584) < 0.02
            && abs(bar.blueComponent - 0.0) < 0.02
        #expect(
            isAmber,
            "听写档柱子不是琥珀橙 #FF9500（实测 \(bar.redComponent), \(bar.greenComponent), \(bar.blueComponent)）。")
        // 对照：空闲档同一点是模板黑，不是橙——否则上面那条可能只是碰巧。
        let idleBar = try Self.pixel(.idle, 9, 12)
        #expect(idleBar.redComponent < 0.01, "空闲档柱子不该是彩色的（模板图只看 alpha）。")
    }
}
