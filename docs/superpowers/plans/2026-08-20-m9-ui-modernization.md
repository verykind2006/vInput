# M9 第一批 · UI 现代化 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按 `docs/superpowers/specs/2026-08-20-m9-ui-modernization-design.md` 把 HUD、菜单面板、菜单栏图标、App 图标全部换成「C 极简专业 + 琥珀橙 #FF9500 + V 字声波 mark」，并新增 HUD 预览文字 ⌘＋/⌘－/⌘0 缩放。

**Architecture:** 视觉常量集中在新建的 `VITheme`/`VMark`；菜单栏图标的状态映射、HUD 字号逻辑、设备卡显隐全部做成 `nonisolated static` 纯函数（本仓库惯例：视图只画，逻辑可单测）。菜单从原生 `MenuBarExtra` 菜单切 `.window` 自定义面板。⌘± 走 Carbon `HotkeyRegistrar`（仿 `CancelHotkeyController` 的「仅会话期注册」模式）。

**Tech Stack:** Swift 6 / SwiftUI / AppKit / Carbon 热键 / Swift Testing（`#expect`）。测试跑 `./scripts/test.sh`，打包跑 `./scripts/build-app.sh`。

---

## 全局规矩（每个任务都适用）

1. **变异验证是强制的。** 每写一条测试，故意把被测判据改坏、跑一遍、确认对应用例真的红、再改回来。变异被抓到的形态有三种：断言失败、**编译错误**、挂起。提交信息里附变异表（改了哪、红没红）。特别警惕：引用常量写断言会对变异自适应——钉数值要写死字面量。
2. **`swift test --filter X` 按源文件名选，不是按类型选**；被门控跳过时汇总行照样报 passed。判「真跑了」要看逐条 `✓` 结果行。每个任务收尾必须完整跑一次 `./scripts/test.sh`。
3. **`vendor/` 一个字节都不要动**（在 `.gitignore` 里，改了会无声丢失）。
4. **功能与文案零增减**：菜单迁移只换壳。所有面板文案沿用 model 层现有的、被测试钉着的函数（`menuLabel`、`translationBackendMenuTitle` 等），**不许在视图里拼新字符串**。
5. 让用户看效果前：`./scripts/build-app.sh && killall vInput; open dist/vInput.app`（不重启看不到改动）。

## 文件地图

| 文件 | 动作 | 职责 |
|---|---|---|
| `Sources/vInput/UI/Theme.swift` | 创建 | `VITheme` 颜色常量 + `VMark` 品牌图形几何（唯一取值处） |
| `Sources/vInput/UI/StatusIcon.swift` | 创建 | 菜单栏图标：状态映射（穷尽 switch）+ NSImage 渲染 |
| `Sources/vInput/UI/HUDViewModel.swift` | 修改 | 字号状态：钳位/步进/复位/持久化/行高换算 |
| `Sources/vInput/Support/ZoomHotkeyController.swift` | 创建 | ⌘＋/⌘－/⌘0 的注册控制（仅会话期） |
| `Sources/vInput/UI/HUDView.swift` | 修改 | 换皮：纯色深底、琥珀橙、动态字号 |
| `Sources/vInput/UI/WaveformView.swift` | 修改 | 加 `tint` 参数 |
| `Sources/vInput/UI/MenuPanelModel.swift` | 创建 | 面板纯逻辑：设备卡显隐、头部状态行 |
| `Sources/vInput/UI/MenuPanelView.swift` | 创建 | 自定义面板视图 |
| `Sources/vInput/App/ModalPanels.swift` | 创建 | 从 `vInputApp.swift` 平移各 NSOpenPanel/NSAlert 帮助函数（private → internal，面板视图要用） |
| `Sources/vInput/App/vInputApp.swift` | 修改 | `.menuBarExtraStyle(.window)`、label 换 `StatusIcon`、删旧 `MenuContent` |
| `Sources/vInput/App/AppModel.swift` | 修改 | 接线 `ZoomHotkeyController` |
| `scripts/render-icon.swift` | 创建 | CoreGraphics 画 iconset 全档 PNG（无第三方依赖） |
| `scripts/make-icon.sh` | 创建 | PNG → `iconutil` → `Resources/AppIcon.icns` |
| `scripts/build-app.sh` | 修改 | icns 缺失时生成并打包进 app |
| `Resources/Info.plist` | 修改 | `CFBundleIconFile` |
| 测试 | 创建 | `ThemeTests` `StatusIconTests` `HUDFontZoomTests` `ZoomHotkeyTests` `MenuPanelModelTests` |

---

### Task 1: VITheme 颜色 + VMark 几何

**Files:**
- Create: `Sources/vInput/UI/Theme.swift`
- Test: `Tests/vInputTests/ThemeTests.swift`

- [x] **Step 1: 写失败的测试**

```swift
import CoreGraphics
import Testing
@testable import vInput

/// VMark 是三处共用的品牌图形（菜单栏、面板头、App 图标脚本照抄同组数）。
/// 这些测试钉的是「V 剪影」这个形状本身：对称、中间最矮、往两边递增。
struct ThemeTests {
    @Test func vMarkHasFiveBars() {
        #expect(VMark.bars.count == 5)
    }

    /// V 形：两端最高、中间最矮，高度向中间单调递减。
    /// 钉字面量而非互相比较——互相比较的断言对「整体等比改错」不敏感。
    @Test func vMarkHeightsFormV() {
        let h = VMark.bars.map(\.height)
        #expect(abs(h[0] - 0.857) < 0.001)
        #expect(abs(h[1] - 0.643) < 0.001)
        #expect(abs(h[2] - 0.429) < 0.001)
        #expect(h[0] > h[1] && h[1] > h[2])
    }

    /// 左右镜像：第 i 根与第 4-i 根同高同宽，x 关于 0.5 对称。
    @Test func vMarkIsSymmetric() {
        let b = VMark.bars
        for i in 0..<2 {
            let j = 4 - i
            #expect(abs(b[i].height - b[j].height) < 0.001)
            #expect(abs(b[i].width - b[j].width) < 0.001)
            #expect(abs((b[i].midX + b[j].midX) - 1.0) < 0.001)
        }
    }

    /// 底边对齐（V 是站在同一条基线上的）：maxY 全相等。
    @Test func vMarkBarsShareBaseline() {
        let maxYs = VMark.bars.map(\.maxY)
        for y in maxYs { #expect(abs(y - maxYs[0]) < 0.001) }
    }

    /// 缩放到目标矩形：归一化几何 × 边长 + 原点偏移。
    @Test func vMarkScalesToRect() {
        let rects = VMark.rects(in: CGRect(x: 10, y: 20, width: 100, height: 100))
        #expect(rects.count == 5)
        #expect(abs(rects[0].origin.x - (10 + 0.0357 * 100)) < 0.1)
        #expect(abs(rects[0].height - 85.7) < 0.1)
    }
}
```

- [x] **Step 2: 跑测试确认失败**

Run: `swift test --filter ThemeTests`
Expected: 编译错误（`VMark` 不存在）——这也是变异形态之一，算「红」。

- [x] **Step 3: 实现**

```swift
import SwiftUI

/// M9 视觉系统的唯一取值处。
/// 设计定稿：docs/superpowers/specs/2026-08-20-m9-ui-modernization-design.md。
/// 改任何颜色只改这里，四块资产（HUD、面板、菜单栏图标、App 图标脚本）跟着走。
enum VITheme {
    /// 琥珀橙 #FF9500——唯一强调色。
    static let accent = Color(red: 1.0, green: 0.584, blue: 0.0)
    /// 大面积渐变的两端 #FFB340 → #FF8A00。
    static let accentGradientTop = Color(red: 1.0, green: 0.702, blue: 0.251)
    static let accentGradientBottom = Color(red: 1.0, green: 0.541, blue: 0.0)
    /// 面板底 #1D1D1F。
    static let panelBackground = Color(red: 0.114, green: 0.114, blue: 0.122)
    /// 内容块 #2A2A2D。
    static let contentBackground = Color(red: 0.165, green: 0.165, blue: 0.176)
    /// 发丝线描边。
    static let hairline = Color.white.opacity(0.09)
}

/// V 字声波：五根圆角柱排成 V 剪影（V=vInput，声柱=语音）。
///
/// 几何是归一化的（0…1 正方形内的分数坐标），来自设计定稿的 56 单位 SVG
/// （x 2/13/24.5/36/47，宽 7，高 48/36/24/36/48，底对齐 y+h=52）。
/// `scripts/render-icon.swift` **照抄这组数**，两处不共享代码（脚本独立运行），
/// 改这里必须同步改脚本——ThemeTests 与脚本内注释互相指认。
enum VMark {
    /// 归一化 (x, y, w, h)。y 向下为正（与 CGRect 绘制约定一致，绘制时按需翻转）。
    nonisolated static let bars: [CGRect] = [
        CGRect(x: 2.0 / 56, y: 4.0 / 56, width: 7.0 / 56, height: 48.0 / 56),
        CGRect(x: 13.0 / 56, y: 16.0 / 56, width: 7.0 / 56, height: 36.0 / 56),
        CGRect(x: 24.5 / 56, y: 28.0 / 56, width: 7.0 / 56, height: 24.0 / 56),
        CGRect(x: 36.0 / 56, y: 16.0 / 56, width: 7.0 / 56, height: 36.0 / 56),
        CGRect(x: 47.0 / 56, y: 4.0 / 56, width: 7.0 / 56, height: 48.0 / 56),
    ]

    /// 「处理中」的波形化变体（中-高-低-高-中），垂直居中。
    nonisolated static let workingBars: [CGRect] = [
        CGRect(x: 2.0 / 56, y: 17.0 / 56, width: 7.0 / 56, height: 22.0 / 56),
        CGRect(x: 13.0 / 56, y: 9.0 / 56, width: 7.0 / 56, height: 38.0 / 56),
        CGRect(x: 24.5 / 56, y: 20.0 / 56, width: 7.0 / 56, height: 16.0 / 56),
        CGRect(x: 36.0 / 56, y: 9.0 / 56, width: 7.0 / 56, height: 38.0 / 56),
        CGRect(x: 47.0 / 56, y: 17.0 / 56, width: 7.0 / 56, height: 22.0 / 56),
    ]

    /// 把归一化几何放进目标矩形。**各向异性拉伸，不保持纵横比**——
    /// 调用方必须传正方形（本批调用处全是）。
    /// （Task 1 QA 复核后泛化：接受 bar 数组参数，默认 `bars`，
    /// 让 workingBars 与 VMarkShape 复用同一段变换。）
    nonisolated static func rects(_ bars: [CGRect] = VMark.bars, in rect: CGRect) -> [CGRect] {
        bars.map { bar in
            CGRect(
                x: rect.origin.x + bar.origin.x * rect.width,
                y: rect.origin.y + bar.origin.y * rect.height,
                width: bar.width * rect.width,
                height: bar.height * rect.height
            )
        }
    }
}
```

- [x] **Step 4: 跑测试确认通过**

Run: `swift test --filter ThemeTests` → 逐条 `✓`（5 条）。

- [x] **Step 5: 变异验证**

逐个做、每个都要看到对应用例红、改回：
1. `bars[2]` 高度 `24.0/56` 改 `40.0/56` → `vMarkHeightsFormV` 红。
2. `bars[4]` 的 x 改 `46.0/56` → `vMarkIsSymmetric` 红。
3. `bars[1]` 的 y 改 `10.0/56` → `vMarkBarsShareBaseline` 红。
4. `rects(in:)` 里 `* rect.width` 改 `* 56` → `vMarkScalesToRect` 红。

- [x] **Step 6: Commit**

```bash
git add Sources/vInput/UI/Theme.swift Tests/vInputTests/ThemeTests.swift
git commit -m "feat: VITheme 视觉常量 + VMark 品牌图形几何（M9 UI 第一块）"
```

---

### Task 2: 菜单栏图标 StatusIcon

**Files:**
- Create: `Sources/vInput/UI/StatusIcon.swift`
- Test: `Tests/vInputTests/StatusIconTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter StatusIconTests` → 编译错误（`StatusIcon` 不存在）。

- [ ] **Step 3: 实现**

```swift
import AppKit

/// 菜单栏图标：V 字声波 mark 的五种状态形态。
enum StatusIcon {
    /// 与 `AppModel` 解耦的图标档位。**穷尽 switch 映射，加档必过编译。**
    enum State: Equatable, CaseIterable {
        case idle, listening, working, error, loadingModel
    }

    nonisolated static func state(loadingModelName: String?, phase: AppModel.Phase) -> State {
        if loadingModelName != nil { return .loadingModel }
        return switch phase {
        case .idle: .idle
        case .listening: .listening
        case .working: .working
        case .error: .error
        }
    }

    /// 模板图交给系统着色（自动适应深浅菜单栏）；听写中的琥珀橙与出错的
    /// 红点是「必须一眼可辨」的信号色，只能用非模板彩图。
    /// 非模板图的已知代价：菜单栏深浅切换时不重绘——下一次状态变化会刷新，
    /// 而听写/出错本身就是短暂状态，可接受。
    nonisolated static func isTemplate(_ state: State) -> Bool {
        switch state {
        case .idle, .working, .loadingModel: true
        case .listening, .error: false
        }
    }

    @MainActor
    static func image(for state: State) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            // 缩放走 VMark.rects(_:in:)，不各写一遍（Task 1 QA 复核后泛化的初衷）。
            let bars = VMark.rects(
                state == .working ? VMark.workingBars : VMark.bars, in: rect)
            let barColor: NSColor = switch state {
            case .listening: NSColor(red: 1.0, green: 0.584, blue: 0.0, alpha: 1)  // #FF9500
            // 出错是彩图，柱子按当前外观取实色（见 isTemplate 注释）。
            case .error: NSColor.secondaryLabelColor
            case .idle, .working, .loadingModel: NSColor.black  // 模板图只看 alpha
            }
            barColor.setFill()
            for bar in bars {
                NSBezierPath(roundedRect: bar, xRadius: bar.width / 2, yRadius: bar.width / 2).fill()
            }
            if state == .error {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: CGRect(x: rect.maxX - 7.5, y: rect.minY, width: 7, height: 7)).fill()
            }
            if state == .loadingModel {
                // 模板图里半透明角标 = 淡一档的同色（模板按 alpha 着色）。
                NSColor.black.withAlphaComponent(0.45).setFill()
                NSBezierPath(ovalIn: CGRect(x: rect.maxX - 6.5, y: rect.minY, width: 6, height: 6)).fill()
            }
            return true
        }
        image.isTemplate = isTemplate(state)
        return image
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter StatusIconTests` → 逐条 `✓`（4 条）。

- [ ] **Step 5: 变异验证**

1. `state(...)` 里删掉 `if loadingModelName != nil` → `loadingOverridesEverything` 红。
2. `isTemplate` 把 `.listening` 挪进模板组 → `templateFlags` 红。
3. `image(for:)` 的 `side` 改 22 → `imagesAreMenuBarSizedAndFlagged` 红。
4. `State` 加一个临时 case → `state(...)` 的 switch **编译错误**（确认穷尽性护栏活着），删掉。

- [ ] **Step 6: Commit**

```bash
git add Sources/vInput/UI/StatusIcon.swift Tests/vInputTests/StatusIconTests.swift
git commit -m "feat: 菜单栏 V 字声波图标——五档状态映射 + 模板/彩图渲染"
```

---

### Task 3: HUDViewModel 字号逻辑

**Files:**
- Modify: `Sources/vInput/UI/HUDViewModel.swift`
- Test: `Tests/vInputTests/HUDFontZoomTests.swift`（新文件，不动现有 `HUDViewModelTests.swift`）

- [ ] **Step 1: 写失败的测试**

```swift
import Foundation
import Testing
@testable import vInput

/// 字号缩放：范围 12–24、步进 1、默认 15、持久化、行高/行宽估算等比换算。
@MainActor
struct HUDFontZoomTests {
    /// 每条用例独立的 UserDefaults，互不污染、不碰真实偏好。
    private func makeDefaults() -> UserDefaults {
        let name = "hud-font-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaultsToFifteen() {
        #expect(HUDViewModel(defaults: makeDefaults()).fontSize == 15)
    }

    @Test func clampStopsAtBounds() {
        // 钉字面量：12/24 是设计定稿里的数，不引用常量（会对变异自适应）。
        #expect(HUDViewModel.clampFontSize(11) == 12)
        #expect(HUDViewModel.clampFontSize(25) == 24)
        #expect(HUDViewModel.clampFontSize(18) == 18)
    }

    @Test func stepAndReset() {
        let model = HUDViewModel(defaults: makeDefaults())
        model.increaseFontSize()
        #expect(model.fontSize == 16)
        model.resetFontSize()
        #expect(model.fontSize == 15)
        for _ in 0..<20 { model.decreaseFontSize() }
        #expect(model.fontSize == 12)
    }

    @Test func persistsAcrossInstances() {
        let defaults = makeDefaults()
        let first = HUDViewModel(defaults: defaults)
        first.increaseFontSize()
        first.increaseFontSize()   // 17
        let second = HUDViewModel(defaults: defaults)
        #expect(second.fontSize == 17)
    }

    /// 存储里被写坏成越界值时，读回来要钳位而不是照单全收。
    @Test func clampsCorruptStoredValue() {
        let defaults = makeDefaults()
        defaults.set(99.0, forKey: HUDViewModel.fontSizeDefaultsKey)
        #expect(HUDViewModel(defaults: defaults).fontSize == 24)
    }

    /// 行高等比：现值 15pt→26pt，两端取整。钉三个字面量点。
    @Test func lineHeightScales() {
        #expect(HUDViewModel.lineHeight(forFontSize: 15) == 26)
        #expect(HUDViewModel.lineHeight(forFontSize: 12) == 21)
        #expect(HUDViewModel.lineHeight(forFontSize: 24) == 42)
    }

    /// 行宽估算等比：现值 15pt→22 字（15×22=330 恒定积）。字号大→每行字少。
    @Test func charsPerLineScales() {
        #expect(HUDViewModel.charsPerLine(forFontSize: 15) == 22)
        #expect(HUDViewModel.charsPerLine(forFontSize: 24) == 13)
        #expect(HUDViewModel.charsPerLine(forFontSize: 12) == 27)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter HUDFontZoomTests` → 编译错误（新成员不存在）。

- [ ] **Step 3: 实现（对 HUDViewModel.swift 的增量）**

在类头部常量区加：

```swift
    // MARK: - 字号缩放（M9，用户要求 ⌘＋/⌘－ 可调）

    static let minFontSize: CGFloat = 12
    static let maxFontSize: CGFloat = 24
    static let defaultFontSize: CGFloat = 15
    static let fontSizeDefaultsKey = "hud.previewFontSize"

    private let defaults: UserDefaults
    var fontSize: CGFloat

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.fontSizeDefaultsKey)
        self.fontSize = stored == 0 ? Self.defaultFontSize : Self.clampFontSize(CGFloat(stored))
    }

    func increaseFontSize() { setFontSize(fontSize + 1) }
    func decreaseFontSize() { setFontSize(fontSize - 1) }
    func resetFontSize() { setFontSize(Self.defaultFontSize) }

    private func setFontSize(_ raw: CGFloat) {
        fontSize = Self.clampFontSize(raw)
        defaults.set(Double(fontSize), forKey: Self.fontSizeDefaultsKey)
    }
```

纯函数区加（`nonisolated static`，与既有风格一致）：

```swift
    nonisolated static func clampFontSize(_ size: CGFloat) -> CGFloat {
        min(maxFontSize, max(minFontSize, size))
    }

    /// 行高随字号等比（现值 15→26），文本框高度由它 × maxLines 得出。
    nonisolated static func lineHeight(forFontSize size: CGFloat) -> CGFloat {
        (size * 26 / 15).rounded()
    }

    /// 每行字数估算随字号反比（现值 15→22，恒定积 330）。**刻意向下取整**：
    /// 低估每行字数 → 提前折行 → 永远不会溢出文本框；四舍五入会在 24pt 时
    /// 估出 14 字（13.75），与钉死的测试值 13 矛盾（派工时订正）。
    nonisolated static func charsPerLine(forFontSize size: CGFloat) -> Int {
        max(1, Int(330 / size))
    }
```

同时改两处既有代码：
1. `confirmedLines` 改用动态行宽：

```swift
    var confirmedLines: [String] {
        Self.tailLines(
            preview.confirmed,
            maxLines: Self.maxLines,
            charsPerLine: Self.charsPerLine(forFontSize: fontSize)
        )
    }
```

2. 静态 `charsPerLine = 22` 常量**保留**（`charsPerLine(forFontSize: 15)` 的锚点写在注释里即可，别的调用方若引用它不受影响；全仓 grep 确认引用处）。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter HUDFontZoomTests` → 逐条 `✓`（7 条）。
再跑 `swift test --filter HUDViewModelTests` 确认旧用例不回归（`HUDViewModel()` 无参构造仍可用）。

- [ ] **Step 5: 变异验证**

1. `clampFontSize` 上限 24 改 30 → `clampStopsAtBounds`、`clampsCorruptStoredValue` 红。
2. `setFontSize` 删掉 `defaults.set` → `persistsAcrossInstances` 红。
3. `lineHeight` 的 `/15` 改 `/16` → `lineHeightScales` 红。
4. `charsPerLine` 的 330 改 360 → `charsPerLineScales` 红。
5. `confirmedLines` 改回静态 `Self.charsPerLine` → 若无红，**说明缺「接上了」的守卫**：在 `HUDFontZoomTests` 里补一条（字号 24 时喂 20 个字，断言折成 2 行；字号 15 时同文本 1 行），确认红后改回。

- [ ] **Step 6: Commit**

```bash
git add Sources/vInput/UI/HUDViewModel.swift Tests/vInputTests/HUDFontZoomTests.swift
git commit -m "feat: HUD 预览字号状态——12–24pt 钳位、持久化、行高/行宽等比换算"
```

---

### Task 4: ZoomHotkeyController + AppModel 接线

**Files:**
- Create: `Sources/vInput/Support/ZoomHotkeyController.swift`
- Modify: `Sources/vInput/App/AppModel.swift`
- Test: `Tests/vInputTests/ZoomHotkeyTests.swift`

- [ ] **Step 1: 写失败的测试**

先读 `Tests/vInputTests/CancelHotkeyTests.swift` 与 `AppModelWiringTests.swift`，测试结构照它们的模式写（假注册器 + 状态驱动）：

```swift
import Testing
@testable import vInput

@MainActor
private final class FakeZoomRegistrar: ZoomHotkeyRegistering {
    var registered = false
    var registerCount = 0
    var increase: (() -> Void)?
    var decrease: (() -> Void)?
    var reset: (() -> Void)?

    func registerZoomKeys(
        increase: @escaping () -> Void,
        decrease: @escaping () -> Void,
        reset: @escaping () -> Void
    ) throws {
        registered = true
        registerCount += 1
        self.increase = increase
        self.decrease = decrease
        self.reset = reset
    }

    func unregisterZoomKeys() { registered = false }
}

/// ⌘±/⌘0 仅在 HUD 可见（会话非 idle）时注册——平时不碰别的应用的缩放键。
@MainActor
struct ZoomHotkeyTests {
    @Test func registersWhenSessionActiveOnly() {
        let registrar = FakeZoomRegistrar()
        let controller = ZoomHotkeyController(registrar: registrar)
        #expect(!registrar.registered)

        controller.update(for: .listening)
        #expect(registrar.registered)

        // 会话中段的状态推进不反复注册。
        controller.update(for: .transcribing)
        controller.update(for: .injecting)
        #expect(registrar.registerCount == 1)

        controller.update(for: .idle)
        #expect(!registrar.registered)
    }

    @Test func forwardsAllThreeKeys() {
        let registrar = FakeZoomRegistrar()
        let controller = ZoomHotkeyController(registrar: registrar)
        var log: [String] = []
        controller.onIncrease = { log.append("+") }
        controller.onDecrease = { log.append("-") }
        controller.onReset = { log.append("0") }

        controller.update(for: .listening)
        registrar.increase?()
        registrar.decrease?()
        registrar.reset?()
        #expect(log == ["+", "-", "0"])
    }

    /// 注册失败不阻断录音（与 Esc 同一条哲学）：不抛、只失去缩放。
    @Test func registrationFailureIsSwallowed() {
        @MainActor
        final class ThrowingRegistrar: ZoomHotkeyRegistering {
            func registerZoomKeys(
                increase: @escaping () -> Void,
                decrease: @escaping () -> Void,
                reset: @escaping () -> Void
            ) throws { throw HotkeyError.registrationFailed(-1) }
            func unregisterZoomKeys() {}
        }
        let controller = ZoomHotkeyController(registrar: ThrowingRegistrar())
        controller.update(for: .listening)   // 不 crash 即可
        controller.update(for: .idle)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter ZoomHotkeyTests` → 编译错误。

- [ ] **Step 3: 实现**

```swift
import Carbon.HIToolbox
import Foundation

/// 缩放热键的注册能力。抽协议以便测试注册时机（与 CancelHotkeyRegistering 同型）。
@MainActor
protocol ZoomHotkeyRegistering: AnyObject {
    func registerZoomKeys(
        increase: @escaping () -> Void,
        decrease: @escaping () -> Void,
        reset: @escaping () -> Void
    ) throws
    func unregisterZoomKeys()
}

/// 用 Carbon 注册 ⌘=（键帽上的 ⌘＋，不带 shift）、⌘-、⌘0。
@MainActor
final class CarbonZoomHotkeyRegistrar: ZoomHotkeyRegistering {
    private let increaseRegistrar = HotkeyRegistrar()
    private let decreaseRegistrar = HotkeyRegistrar()
    private let resetRegistrar = HotkeyRegistrar()

    func registerZoomKeys(
        increase: @escaping () -> Void,
        decrease: @escaping () -> Void,
        reset: @escaping () -> Void
    ) throws {
        // 三个一起成、一起败：部分注册会造成「＋能用－不能用」这种没法解释的状态。
        do {
            try increaseRegistrar.register(
                keyCode: UInt32(kVK_ANSI_Equal), modifiers: UInt32(cmdKey), handler: increase)
            try decreaseRegistrar.register(
                keyCode: UInt32(kVK_ANSI_Minus), modifiers: UInt32(cmdKey), handler: decrease)
            try resetRegistrar.register(
                keyCode: UInt32(kVK_ANSI_0), modifiers: UInt32(cmdKey), handler: reset)
        } catch {
            unregisterZoomKeys()
            throw error
        }
    }

    func unregisterZoomKeys() {
        increaseRegistrar.unregister()
        decreaseRegistrar.unregister()
        resetRegistrar.unregister()
    }
}

/// 按会话状态管理缩放热键：**仅 HUD 可见（非 idle）时注册**。
/// ⌘＋/⌘－ 是各应用的高频缩放键，长期占用等于劫持——注册窗口必须
/// 收窄到用户正对着 HUD 的那几秒（与 CancelHotkeyController 同一条哲学，
/// 只是窗口从 .listening 放宽到整个会话：转写/翻译阶段用户也在看预览文字）。
@MainActor
final class ZoomHotkeyController {
    var onIncrease: (() -> Void)?
    var onDecrease: (() -> Void)?
    var onReset: (() -> Void)?

    private let registrar: ZoomHotkeyRegistering
    private var isRegistered = false

    init(registrar: ZoomHotkeyRegistering) {
        self.registrar = registrar
    }

    func update(for state: DictationSession.State) {
        if state != .idle {
            guard !isRegistered else { return }
            do {
                try registrar.registerZoomKeys(
                    increase: { [weak self] in self?.onIncrease?() },
                    decrease: { [weak self] in self?.onDecrease?() },
                    reset: { [weak self] in self?.onReset?() }
                )
            } catch {
                AppLogger.shared.log("缩放热键注册失败，本次会话无法用 ⌘± 调字号：\(error)")
            }
            // 失败也置位：避免每次状态推进都重试刷屏。离开会话时注销是幂等的。
            isRegistered = true
        } else {
            guard isRegistered else { return }
            registrar.unregisterZoomKeys()
            isRegistered = false
        }
    }
}
```

**AppModel 接线**（找到 `CancelHotkeyController` 的创建、update、注销三处，逐处并排加同款）：

1. 属性区：`private let zoomHotkeys = ZoomHotkeyController(registrar: CarbonZoomHotkeyRegistrar())`
2. bootstrap（cancel 的 onCancel 接线旁）：

```swift
        zoomHotkeys.onIncrease = { [weak self] in self?.hudModel.increaseFontSize() }
        zoomHotkeys.onDecrease = { [weak self] in self?.hudModel.decreaseFontSize() }
        zoomHotkeys.onReset = { [weak self] in self?.hudModel.resetFontSize() }
```

3. 会话状态回调（`AppModel.swift` 约 490 行，`self.hudModel.phase = state` 与 cancel 的 `update(for:)` 处）：`self.zoomHotkeys.update(for: state)`
4. `shutdown()`：cancel 注销旁加 `zoomHotkeys.update(for: .idle)`。

**接线守卫**（「值对了」≠「接上了」）：照 `AppModelWiringTests.swift` 现有模式加一条——构造 AppModel（或其可测替身），驱动会话状态到 `.listening`，断言 zoom 控制器的回调非 nil 且调用后 `hudModel.fontSize` 变化。若该文件的模式不允许（AppModel 构造依赖过重），改为在 `ZoomHotkeyTests` 里注明「接线由 Task 9 真机 QA 项 #4 覆盖」，**不许无声跳过**。

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter ZoomHotkeyTests` → 逐条 `✓`（3 条）。

- [ ] **Step 5: 变异验证**

1. `update(for:)` 的 `state != .idle` 改 `state == .listening` → `registersWhenSessionActiveOnly` 里 `.transcribing` 段…**不红**（registerCount 仍 1）——换 `.idle` 分支注掉 `unregisterZoomKeys()` → 红。两处都试，记进变异表。
2. `registerZoomKeys` 转发闭包里 increase/decrease 对调 → `forwardsAllThreeKeys` 红。
3. catch 分支改成 `throw`（向上抛）→ `registrationFailureIsSwallowed` 崩/红。

- [ ] **Step 6: Commit**

```bash
git add Sources/vInput/Support/ZoomHotkeyController.swift Tests/vInputTests/ZoomHotkeyTests.swift Sources/vInput/App/AppModel.swift
git commit -m "feat: ⌘＋/⌘－/⌘0 调 HUD 字号——仅会话期注册，注册失败不阻断录音"
```

---

### Task 5: HUD 换皮

**Files:**
- Modify: `Sources/vInput/UI/HUDView.swift`
- Modify: `Sources/vInput/UI/WaveformView.swift`

视图无逻辑可测（本仓库惯例：逻辑全在 Task 3 的纯函数里），本任务只有实现步。

- [ ] **Step 1: WaveformView 加 tint**

```swift
struct WaveformView: View {
    let bars: [Float]
    /// 听写中琥珀橙、其余次要色。由调用方按 phase 决定——本视图不认识 phase。
    var tint: Color = .secondary
```

`.fill(.secondary)` 改 `.fill(tint)`。

- [ ] **Step 2: HUDView 换皮（逐处）**

1. 外框（`body` 的 background/overlay）：

```swift
        .background(VITheme.panelBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(VITheme.hairline, lineWidth: 1)
        )
```

2. `transcriptHeight` 与 `lineHeight` 改为动态（**删掉** `private let lineHeight: CGFloat = 26`）：

```swift
    private var lineHeight: CGFloat {
        HUDViewModel.lineHeight(forFontSize: model.fontSize)
    }
    private var transcriptHeight: CGFloat {
        lineHeight * CGFloat(HUDViewModel.maxLines) + 20
    }
```

3. `transcriptBox` 填充：`Color(nsColor: .textBackgroundColor).opacity(0.55)` → `VITheme.contentBackground`；描边 → `VITheme.hairline`。
4. `transcriptText` 与占位文字的字号：`.font(.system(size: 15))` → `.font(.system(size: model.fontSize))`；`lineSpacing(5)` → `.lineSpacing(max(0, lineHeight - model.fontSize - 6))`（15pt 时 = 5，即现值）。
5. `statusColor`：

```swift
    private var statusColor: Color {
        switch model.phase {
        case .idle: .secondary
        case .listening: VITheme.accent
        case .transcribing, .correcting, .translating, .injecting: .secondary
        }
    }
```

6. `header` 里波形：`WaveformView(bars: model.bars, tint: model.phase == .listening ? VITheme.accent : .secondary)`。
7. `footer` 加字号提示（Spacer 之前排在右侧）：

```swift
    private var footer: some View {
        HStack(spacing: 16) {
            keyHint("⌥D", "完成")
            keyHint("esc", "取消")
            Spacer(minLength: 0)
            keyHint("⌘＋/－", "字号")
        }
    }
```

8. 正文/占位颜色维持语义色（`.primary`/`.secondary`/`.tertiary`——深底纯色面板上系统语义色依旧成立，不硬编码白色）。

- [ ] **Step 3: 全量测试 + 真机目检**

Run: `./scripts/test.sh` → 与基线同绿。
Run: `./scripts/build-app.sh && killall vInput; open dist/vInput.app`
目检：⌥D 说一句话——深底面板、橙点、橙波形；⌘＋两下字变大、面板变高不跳动；⌘0 复位；esc 取消后在别的应用里按 ⌘＋ 不被拦截。

- [ ] **Step 4: Commit**

```bash
git add Sources/vInput/UI/HUDView.swift Sources/vInput/UI/WaveformView.swift
git commit -m "feat: HUD 换皮——纯色深底 + 琥珀橙 + 动态字号（C 极简专业）"
```

---

### Task 6: MenuPanelModel 纯逻辑

> **本节片段已过时，以源码为准**（QA 复核后的落地形态，提交 `61e9d0c`）：
> `DeviceCard` 的 `warning: Bool` 改成了 `tone: Tone`（视图直接复用
> `toneColor`，不再手写颜色判断），并加了 `kind: Kind` 做身份
> （`Identifiable`，`ForEach` 不再拿中文标题当 id）；鼠标 `.muted` 的
> 文案改用新拆出的 `MouseBridgeState.detailLabel(battery:)`——
> `menuLabel` = 「鼠标：」+ 它，卡片标题已经是「鼠标」，不该再重复一遍。
> 复核实测：拆分前后 `menuLabel` 的输出逐字节不变。

**Files:**
- Create: `Sources/vInput/UI/MenuPanelModel.swift`
- Test: `Tests/vInputTests/MenuPanelModelTests.swift`

- [ ] **Step 1: 写失败的测试**

```swift
import Testing
@testable import vInput

struct MenuPanelModelTests {
    // MARK: 设备卡：连谁显示谁

    @Test func noDevicesMeansNoCards() {
        let cards = MenuPanelModel.deviceCards(
            remote: .disconnected, remoteBattery: nil,
            mouseEnabled: true, mouse: .stopped, mouseBattery: nil)
        #expect(cards.isEmpty)
    }

    /// 搜索中/连接中等过渡态不出卡——「连谁显示谁」，没连上就不算。
    @Test func transientStatesShowNothing() {
        #expect(MenuPanelModel.deviceCards(
            remote: .scanning, remoteBattery: nil,
            mouseEnabled: true, mouse: .searching, mouseBattery: nil).isEmpty)
    }

    @Test func remoteOnlyShowsOneCard() {
        let cards = MenuPanelModel.deviceCards(
            remote: .connected, remoteBattery: 78,
            mouseEnabled: true, mouse: .stopped, mouseBattery: nil)
        #expect(cards.count == 1)
        #expect(cards[0].title == "遥控器")
        #expect(cards[0].detail.contains("78"))
        #expect(!cards[0].warning)
    }

    @Test func bothConnectedShowsTwoCardsRemoteFirst() {
        let cards = MenuPanelModel.deviceCards(
            remote: .connected, remoteBattery: 78,
            mouseEnabled: true, mouse: .ready("iMouse"), mouseBattery: 65)
        #expect(cards.count == 2)
        #expect(cards[0].title == "遥控器")
        #expect(cards[1].title == "鼠标")
    }

    @Test func mouseDisabledNeverShowsMouseCard() {
        let cards = MenuPanelModel.deviceCards(
            remote: .disconnected, remoteBattery: nil,
            mouseEnabled: false, mouse: .ready("iMouse"), mouseBattery: 65)
        #expect(cards.isEmpty)
    }

    /// **`.muted` 必须出卡且带警示**——2026-08-18 那次 11 分钟环境音事故
    /// 正是靠菜单栏可见性发现的，隐藏它等于把那个教训删了。
    @Test func mutedMouseStaysVisibleAsWarning() {
        let cards = MenuPanelModel.deviceCards(
            remote: .disconnected, remoteBattery: nil,
            mouseEnabled: true, mouse: .muted(30), mouseBattery: nil)
        #expect(cards.count == 1)
        #expect(cards[0].title == "鼠标")
        #expect(cards[0].warning)
    }

    // MARK: 头部状态行（文案零增减：与旧 MenuContent.statusText 逐字相同）

    @Test func headerCopiesAreUnchanged() {
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: "qwen", phase: .idle, permission: .ready
        ) == .init(text: "正在加载模型 qwen…首次可能需要一两分钟", tone: .busy))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .idle, permission: .ready
        ) == .init(text: "就绪", tone: .ok))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .idle, permission: .microphoneMissing
        ) == .init(text: "需要麦克风权限", tone: .error))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .listening, permission: .ready
        ) == .init(text: "正在聆听…", tone: .recording))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .working, permission: .ready
        ) == .init(text: "正在转写…", tone: .busy))
        #expect(MenuPanelModel.headerStatus(
            loadingModelName: nil, phase: .error("坏了"), permission: .ready
        ) == .init(text: "出错：坏了", tone: .error))
    }
}
```

注意：`permission` 参数的类型名以 `AppModel.permissionStatus` 的实际类型为准（写测试前 grep 一下，`accessibilityMissing` 那档也要一条用例）。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter MenuPanelModelTests` → 编译错误。

- [ ] **Step 3: 实现**

```swift
import Foundation

/// 菜单面板的展示逻辑。全部纯函数，视图只画（与 HUDViewModel 同一条分工）。
enum MenuPanelModel {
    // MARK: - 设备卡

    struct DeviceCard: Equatable {
        let title: String
        let detail: String
        /// 警示卡（目前只有鼠标 .muted）：撞时长上限被强制退订，必须可见。
        let warning: Bool
    }

    /// 连谁显示谁（用户 2026-08-20 定的：不是每台机器都同时连着两个设备）。
    /// 全断开 → 空数组，面板整块隐藏；内置麦是默认路径，不占卡。
    ///
    /// 例外：鼠标 `.muted` 出警示卡。2026-08-18 的 11 分钟环境音事故靠的
    /// 就是菜单栏可见性，「没连上就不显示」不适用于「被我们主动踢掉」。
    nonisolated static func deviceCards(
        remote: RemoteConnectionState,
        remoteBattery: Int?,
        mouseEnabled: Bool,
        mouse: MouseBridgeState,
        mouseBattery: Int?
    ) -> [DeviceCard] {
        var cards: [DeviceCard] = []
        if remote == .connected {
            cards.append(DeviceCard(
                title: "遥控器", detail: batteryDetail(remoteBattery), warning: false))
        }
        if mouseEnabled {
            switch mouse {
            case .ready:
                cards.append(DeviceCard(
                    title: "鼠标", detail: batteryDetail(mouseBattery), warning: false))
            case .muted:
                // 文案复用 model 层现成的（被测试钉着的）menuLabel，不新拼。
                cards.append(DeviceCard(
                    title: "鼠标", detail: mouse.menuLabel(battery: mouseBattery), warning: true))
            case .stopped, .bluetoothUnavailable, .searching, .connecting,
                 .discovering, .reconnecting:
                break
            }
        }
        return cards
    }

    private nonisolated static func batteryDetail(_ battery: Int?) -> String {
        battery.map { "电量 \($0)%" } ?? "已连接"
    }

    // MARK: - 头部状态行

    enum Tone: Equatable { case ok, recording, busy, error }

    struct HeaderStatus: Equatable {
        let text: String
        let tone: Tone
    }

    /// 文案与旧 MenuContent.statusText **逐字相同**（迁移守则：零增减），
    /// 搬到 model 层是为了让测试钉得住它。
    nonisolated static func headerStatus(
        loadingModelName: String?,
        phase: AppModel.Phase,
        permission: PermissionStatus
    ) -> HeaderStatus {
        if let loading = loadingModelName {
            return HeaderStatus(text: "正在加载模型 \(loading)…首次可能需要一两分钟", tone: .busy)
        }
        switch phase {
        case .idle:
            switch permission {
            case .ready: return HeaderStatus(text: "就绪", tone: .ok)
            case .microphoneMissing: return HeaderStatus(text: "需要麦克风权限", tone: .error)
            case .accessibilityMissing: return HeaderStatus(text: "需要辅助功能权限", tone: .error)
            }
        case .listening: return HeaderStatus(text: "正在聆听…", tone: .recording)
        case .working: return HeaderStatus(text: "正在转写…", tone: .busy)
        case .error(let message): return HeaderStatus(text: "出错：\(message)", tone: .error)
        }
    }
}
```

（`PermissionStatus` 用 `AppModel.permissionStatus` 的实际类型名；`mouse.menuLabel(battery:)` 签名以 `MouseBluetoothBridge.swift` 的扩展为准。）

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter MenuPanelModelTests` → 逐条 `✓`（7+ 条）。

- [ ] **Step 5: 变异验证**

1. `remote == .connected` 改 `remote != .disconnected` → `transientStatesShowNothing` 红。
2. `.muted` 分支并进 `break` 组 → `mutedMouseStaysVisibleAsWarning` 红。
3. `mouseEnabled` guard 删掉 → `mouseDisabledNeverShowsMouseCard` 红。
4. `headerStatus` 加载分支挪到 phase 判断之后 → `headerCopiesAreUnchanged` 第一条红。
5. `MouseBridgeState` 临时加一个 case → `deviceCards` 的 switch **编译错误**（穷尽性护栏），删掉。

- [ ] **Step 6: Commit**

```bash
git add Sources/vInput/UI/MenuPanelModel.swift Tests/vInputTests/MenuPanelModelTests.swift
git commit -m "feat: 菜单面板纯逻辑——设备卡连谁显示谁（muted 必须可见）+ 头部状态行"
```

---

### Task 7: 自定义面板视图 + 切 .window

**Files:**
- Create: `Sources/vInput/App/ModalPanels.swift`（平移，不改内容）
- Create: `Sources/vInput/UI/MenuPanelView.swift`
- Modify: `Sources/vInput/App/vInputApp.swift`

这是最大的一个任务，纯迁移 + 布壳，无新逻辑（逻辑都在 Task 6）。**迁移守则：功能与文案零增减。** 动手前把旧 `MenuContent` 全文读一遍，列出全部交互项（按钮/子菜单/禁用条件/门控），迁移后逐项对照打勾。

- [ ] **Step 1: 平移弹窗帮助函数**

把 `vInputApp.swift` 里五个 file-private 帮助函数原样搬进新文件 `Sources/vInput/App/ModalPanels.swift`，`private` 改 `internal`（面板视图在别的文件里要调）：`presentCorrectionModelFolderPanel` / `presentCloudBackendConfirmation` / `presentCloudAPIKeyPanel` / `presentCloudModelPanel` / （以及 `MenuContent.chooseModelFolder` 里那段 NSOpenPanel，抽成 `presentWhisperModelFolderPanel() -> URL?`）。**注释一行不删**（`activate` 不能去掉等注释全是真机踩坑记录）。

Run: `swift test --filter PackageSmokeTests`（编译通过即可）。

- [ ] **Step 2: 写 MenuPanelView**

宽 300。结构自上而下（对应设计定稿 ② 的 1–7 项）。骨架：

```swift
import AppKit
import SwiftUI

/// 菜单栏面板（MenuBarExtra .window 样式的内容视图）。
/// 布局与视觉见设计定稿 ②；一切文案与动作复用 model 层现有函数，零增减。
struct MenuPanelView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            primaryButton
            deviceCards
            lastTranscriptCard
            settingsList
            devTools
            footer
        }
        .frame(width: 300)
        .background(VITheme.panelBackground)
        .onAppear { model.refreshAvailableModels() }
    }

    // MARK: 头部：VMark + 名字 + 状态

    private var header: some View {
        let status = MenuPanelModel.headerStatus(
            loadingModelName: model.loadingModelName,
            phase: model.phase,
            permission: model.permissionStatus
        )
        return HStack(spacing: 8) {
            VMarkShape(bars: VMark.bars)
                .fill(VITheme.accent)
                .frame(width: 15, height: 15)
            Text("vInput").font(.system(size: 13, weight: .semibold))
            Spacer()
            Circle().fill(toneColor(status.tone)).frame(width: 6, height: 6)
            Text(status.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.init(top: 12, leading: 14, bottom: 10, trailing: 14))
    }

    private func toneColor(_ tone: MenuPanelModel.Tone) -> Color {
        switch tone {
        case .ok: .green
        case .recording: VITheme.accent
        case .busy: .secondary
        case .error: .red
        }
    }

    // MARK: 主按钮

    private var primaryButton: some View {
        Button {
            model.toggle()
        } label: {
            HStack {
                Text(model.phase == .listening ? "结束听写" : "开始听写")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("⌥D")
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            }
            .foregroundStyle(Color(red: 0.10, green: 0.07, blue: 0.02))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(
                LinearGradient(
                    colors: [VITheme.accentGradientTop, VITheme.accentGradientBottom],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(model.loadingModelName != nil)
        .padding(.horizontal, 12).padding(.bottom, 10)
    }
    // …（后续小节见 Step 3–5）
}

/// 归一化 VMark 几何 → SwiftUI Shape（面板头部用；菜单栏走 NSImage）。
struct VMarkShape: Shape {
    let bars: [CGRect]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // 缩放走 VMark.rects(_:in:)，不各写一遍（Task 1 QA 复核后泛化的初衷）。
        for r in VMark.rects(bars, in: rect) {
            path.addRoundedRect(in: r, cornerSize: CGSize(width: r.width / 2, height: r.width / 2))
        }
        return path
    }
}
```

- [ ] **Step 3: 设备卡 + 上次转写卡**

```swift
    @ViewBuilder
    private var deviceCards: some View {
        let cards = MenuPanelModel.deviceCards(
            remote: model.remoteState, remoteBattery: model.remoteBattery,
            mouseEnabled: AppModel.mouseEnabled,
            mouse: model.mouseState, mouseBattery: model.mouseBattery)
        if !cards.isEmpty {
            // alignment: .top —— .muted 那张卡的文案会折成两行，不对齐顶部
            // 会把兄弟卡一起撑歪（Task 6 QA 复核实测）。
            HStack(alignment: .top, spacing: 8) {
                // id 用 kind 不用 title：拿中文文案当身份是个坑
                // （Task 6 QA 复核，DeviceCard 已 Identifiable）。
                ForEach(cards) { card in
                    HStack(spacing: 5) {
                        // 复用头部那只 toneColor，不在视图里再手写一遍颜色判断。
                        Circle().fill(toneColor(card.tone))
                            .frame(width: 5, height: 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(card.title).font(.system(size: 11))
                            Text(card.detail)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(VITheme.contentBackground, in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var lastTranscriptCard: some View {
        if !model.lastText.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("上次转写").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("重试 ↻") { model.retryLastTranscription() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(model.canRetry ? VITheme.accent : Color.secondary)
                        .disabled(!model.canRetry)   // 禁用而不隐藏，理由见旧 MenuContent 注释
                }
                Text(model.lastText.prefix(60))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VITheme.contentBackground, in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }
```

- [ ] **Step 4: 设置四行（面板内展开）**

用 `DisclosureGroup` 把旧的四个子菜单一比一搬进来。**内容一律照抄旧 `MenuContent` 的 `modelMenu` / `correctionMenu` / `outputLanguageMenu` / `translationBackendMenu`**——每个 `Menu` → `DisclosureGroup`，每个 `Button`/`Text`/`Divider` 原样保留（含禁用条件、勾选标记、互斥显示、`guard model.translationBackend == .local` 这类防重复确认的细节）。行样式：

```swift
    private var settingsList: some View {
        VStack(spacing: 0) {
            settingRow(title: "模型", value: modelValueLabel) { /* 旧 modelMenu 的展开内容 */ }
            settingRow(title: "校正", value: model.correctionEnabled ? "开" : "关") { /* 旧 correctionMenu */ }
            settingRow(title: "输出语言", value: outputLanguageValueLabel) { /* 旧 outputLanguageMenu */ }
            settingRow(title: "翻译后端", value: backendValueLabel) { /* 旧 translationBackendMenu */ }
        }
        .background(VITheme.contentBackground, in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 12).padding(.bottom, 10)
    }
```

其中 `settingRow` 是一个带琥珀橙当前值 + `›`（展开时旋转 90°）的 DisclosureGroup 包装；三个 `…ValueLabel` **只做取值转发**（`modelValueLabel` 转发旧 `modelMenuTitle` 的取值逻辑但去掉「模型：」前缀——前缀成了行标题；标题+值合起来的信息量与旧文案一致，这是本任务唯一允许的文案改动，其余零增减）。`outputLanguageValueLabel` 用 `AppModel.outputLanguageMenuTitle(...)` 同样去前缀；缺模型目录的「（缺模型目录）」后缀**必须保留**。

- [ ] **Step 5: 开发期工具 + 底栏 + 切 .window**

devTools：`AppModel.benchEnabled` / `AppModel.bleScanEnabled` 门控，照抄旧 `benchMenu` / `bleScanMenu` 的按钮，收在一个「开发工具」DisclosureGroup 里。

footer：

```swift
    private var footer: some View {
        HStack {
            Button("打开日志") {
                NSWorkspace.shared.selectFile(
                    AppLogger.shared.path, inFileViewerRootedAtPath: "")
            }
            Spacer()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.init(top: 8, leading: 14, bottom: 10, trailing: 14))
    }
```

`vInputApp.swift`：

```swift
    var body: some Scene {
        MenuBarExtra {
            MenuPanelView(model: delegate.model)
        } label: {
            Image(nsImage: StatusIcon.image(for: StatusIcon.state(
                loadingModelName: delegate.model.loadingModelName,
                phase: delegate.model.phase)))
        }
        .menuBarExtraStyle(.window)
    }
```

删除 `MenuContent` 整个 struct 与 `iconName`（其状态文案已被 Task 6 的 `headerStatus` 接管、图标已被 StatusIcon 接管——删除前 grep 确认无他处引用）。

- [ ] **Step 6: 迁移对照清单（逐项打勾进提交信息）**

旧菜单全部交互项：状态行 / 遥控器行 / 鼠标行（门控）/ 上次文本 / 开始结束听写 ⌥D / 重试（禁用态）/ 模型子菜单（列表+勾选+禁用+「其他目录…」+空列表提示）/ 校正（开关+模型行+指定）/ 输出语言（六项+勾选+缺目录后缀）/ 翻译后端（二选一+说明行+本机指定/改回跟随+云端选模型/自定义/API Key 四操作+重新检查）/ bench 门控 / BLE 两按钮门控 / 打开日志 / 退出 ⌘Q。

- [ ] **Step 7: 全量测试 + 真机目检**

Run: `./scripts/test.sh` → 同绿。
Run: `./scripts/build-app.sh && killall vInput; open dist/vInput.app`
目检：点图标出面板；点外面关；逐个展开四行设置动一遍（换模型、开关校正、切语言、后端二选一）；断开/连上设备看卡片增减；⌘Q 退出。

- [ ] **Step 8: Commit**

```bash
git add Sources/vInput/UI/MenuPanelView.swift Sources/vInput/App/ModalPanels.swift Sources/vInput/App/vInputApp.swift
git commit -m "feat: 菜单切自定义面板（.window）——功能文案零增减，壳换成 C 风格"
```

---

### Task 8: App 图标管线

**Files:**
- Create: `scripts/render-icon.swift`
- Create: `scripts/make-icon.sh`
- Modify: `scripts/build-app.sh`、`Resources/Info.plist`、`.gitignore`

- [ ] **Step 1: render-icon.swift**

独立 CoreGraphics 脚本（`swift scripts/render-icon.swift <输出目录>` 运行，无第三方依赖）。**几何数照抄 `Theme.swift` 的 `VMark.bars`**（56 单位：x 2/13/24.5/36/47，宽 7，高 48/36/24/36/48）——两处不共享代码，改一处必须同步另一处：

```swift
#!/usr/bin/env swift
// App 图标渲染。几何与配色照抄 Sources/vInput/UI/Theme.swift（VMark/VITheme），
// 改那边必须同步这里。用法：swift scripts/render-icon.swift <iconset 目录>
import AppKit

let barsIn56: [CGRect] = [
    CGRect(x: 2, y: 4, width: 7, height: 48),
    CGRect(x: 13, y: 16, width: 7, height: 36),
    CGRect(x: 24.5, y: 28, width: 7, height: 24),
    CGRect(x: 36, y: 16, width: 7, height: 36),
    CGRect(x: 47, y: 4, width: 7, height: 48),
]

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let side = CGFloat(pixels)
    // macOS 图标习惯：内容占画布约 80%，四周留安全边距。
    let tile = CGRect(x: side * 0.1, y: side * 0.1, width: side * 0.8, height: side * 0.8)
    let radius = tile.width * 0.2246
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    // 深色渐变底 #2A2A2E → #131315（160°，近似为垂直即可）。
    NSGradient(
        starting: NSColor(red: 0.165, green: 0.165, blue: 0.180, alpha: 1),
        ending: NSColor(red: 0.075, green: 0.075, blue: 0.082, alpha: 1)
    )!.draw(in: tilePath, angle: -70)
    // V mark：占 tile 宽 60%，居中；琥珀橙渐变 #FFB340 → #FF8A00。
    let markSide = tile.width * 0.60
    let mark = CGRect(
        x: tile.midX - markSide / 2, y: tile.midY - markSide / 2,
        width: markSide, height: markSide)
    let markPath = NSBezierPath()
    for b in barsIn56 {
        // 图标坐标系 y 向上，56 单位几何 y 向下：翻转 y。
        let r = CGRect(
            x: mark.minX + b.minX / 56 * mark.width,
            y: mark.minY + (56 - b.maxY) / 56 * mark.height,
            width: b.width / 56 * mark.width,
            height: b.height / 56 * mark.height)
        markPath.append(NSBezierPath(roundedRect: r, xRadius: r.width / 2, yRadius: r.width / 2))
    }
    NSGradient(
        starting: NSColor(red: 1.0, green: 0.702, blue: 0.251, alpha: 1),
        ending: NSColor(red: 1.0, green: 0.541, blue: 0.0, alpha: 1)
    )!.draw(in: markPath, angle: -70)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("用法: swift scripts/render-icon.swift <iconset 目录>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
// iconutil 要求的十个档位。
let specs: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for spec in specs {
    let rep = render(pixels: spec.pixels)
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: outDir.appendingPathComponent("\(spec.name).png"))
}
print("已渲染 \(specs.count) 档 → \(outDir.path)")
```

- [ ] **Step 2: make-icon.sh**

```zsh
#!/bin/zsh
# 生成 Resources/AppIcon.icns（生成物不进版本库，母版是 render-icon.swift）。
set -euo pipefail
ROOT="${0:A:h:h}"
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift "$ROOT/scripts/render-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
print "已生成 $ROOT/Resources/AppIcon.icns"
```

`chmod +x scripts/make-icon.sh`，跑一次确认出 icns（`file Resources/AppIcon.icns` 应报 `Mac OS X icon`），`open Resources/AppIcon.icns` 目检。

- [ ] **Step 3: 接进 Info.plist 与 build-app.sh，gitignore 生成物**

`Resources/Info.plist` 加：

```xml
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
```

`scripts/build-app.sh` 在 `ditto …Info.plist` 那行之后加：

```zsh
# App 图标：icns 是生成物（.gitignore），缺了就现做——换机器 clone 下来第一次
# 构建也能出对的图标，而不是无声地打出一个白图标包。
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  "$ROOT/scripts/make-icon.sh"
fi
ditto --norsrc --noextattr --noqtn --noacl \
    "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
```

`.gitignore` 加一行 `Resources/AppIcon.icns`。

- [ ] **Step 4: 验证**

Run: `rm -f Resources/AppIcon.icns && ./scripts/build-app.sh`
Expected: 脚本自动生成 icns、打包成功。`open dist/` 里 vInput.app 显示新图标（Finder 缓存旧图标时 `touch dist/vInput.app` 或重登 Finder）。系统设置 → 隐私与安全性 → 辅助功能列表里的图标也换新（可能需重授权一次——固定签名身份在的话不需要）。

- [ ] **Step 5: Commit**

```bash
git add scripts/render-icon.swift scripts/make-icon.sh scripts/build-app.sh Resources/Info.plist .gitignore
git commit -m "feat: App 图标管线——CoreGraphics 母版脚本生成 icns，构建时自动补"
```

---

### Task 9: 收尾——全量验证 + QA 代理 + 真机验收

- [ ] **Step 1: 全量**

```bash
./scripts/test.sh && ./scripts/build-app.sh
```

Expected: 与基线同绿（基线条数看 Roadmap；新增 5 个测试文件的条数计入）。

- [ ] **Step 2: 派专门 QA 代理**（按 `final-qa-agent-before-handoff` 惯例）

QA 任务书要点：不复述测试结果；查**跨任务接缝**——① 图标状态与面板头部状态是否会说两套话（同一 `AppModel` 状态两条映射）；② `MenuContent` 删除后有没有孤儿引用/丢失的交互项（对照 Task 7 Step 6 清单逐项核）；③ ⌘± 在「HUD 因 notice 延迟关闭」的窗口里行为是否自洽；④ ZoomHotkeyController 的 AppModel 接线是否真的接上（亲手变异：注掉一行接线，看有没有测试红；没有就把这一条补进真机清单并在报告里明说）；⑤ 字号 24 时 HUD 面板是否超屏（480 宽固定、高度变大，`HUDPanel.originFor` 底边距 120）。**QA 自己重新选变异点，不照抄各任务的变异表。** QA 报出的问题修完再进 Step 3。

> **Task 7 QA 复核补充的验收要点**（2026-08-21，按发现顺序记，别丢）：
>
> 1. **头号项：从面板点「开始听写」，文字注进了哪里。** 旧原生菜单点一下
>    自动关闭、焦点回到原应用；`.window` 面板不会。`TargetAppGuard.capture()`
>    在会话开始时记前台应用，所以这条链一旦断，要么注给 vInput 自己（文字
>    等于没了），要么报「焦点已切到别的应用」。**用日志核，不要靠眼睛**：
>    开面板 → 点开始听写 → 说一句 → 查 `~/Library/Logs/vInput/vInput.log`，
>    看目标应用守卫记的 bundle id 是不是 vInput 自己、有没有
>    `targetApplicationChanged`。
> 1b. **同一次操作里顺带看 HUD 出没出来。** 复核推出的新风险：修 C1 用的是
>    `NSApp.hide(nil)`，它把应用置为 hidden，而 HUD 面板整套设计
>    （`.nonactivatingPanel` + `hidesOnDeactivate = false` +
>    `orderFrontRegardless()`，`HUDPanel.swift:98-114`）建立在「应用从不被
>    隐藏」这个前提上。**从面板启动听写时 HUD 可能根本不出现**，而 ⌥D 那条
>    路一切正常——最容易漏测的形状。日志里现在有「目标应用已记录：…」，
>    三种读法：记的是 vInput 自己 → 一个 runloop turn 不够，让位没完成；
>    记的是编辑器但 HUD 没出现 → 就是这条风险，得换机制（`NSApp.deactivate()`
>    或事件驱动等 `didActivateApplicationNotification`）；记的是编辑器且
>    HUD 正常 → 两条都过。
> 2. **开三次面板数三行「重扫模型目录」日志**：一次回答两个问题——刷新是否
>    每次都跑、DisclosureGroup 状态是否每次重置（这两件事是同一个事实：
>    视图重建则两者都成立）。
> 3. **浅色系统下开面板看四个圆角**：面板内容强制暗色，但宿主窗口的材质
>    仍随系统，浅色下圆角处可能露出浅色边。
> 4. **⌘Q**：`.window` 里系统不再自动画 ⌘Q 字形，且这是 LSUIElement 应用、
>    没有主菜单——先确认它还能退出，再谈要不要补一个可见提示。
> 5. 三条只能靠眼睛的图形盲区（各任务变异表如实记录在案）：菜单栏图标
>    「处理中」的波形形态与 V 形有没有搞反、加载角标挖空后是否可辨、
>    强调色是否真的是琥珀橙。
>
> 另有一条工程债留给后续批次（不阻塞本批）：`HUDPanelTests` 那两条源码
> 扫描测试可以换成真行为测试——Task 5 复核已证明 `NSPanel` 能在测试里
> 无头驱动，直接断言 `bottomGap == 120` 比扫源码结实得多。

- [ ] **Step 3: 请用户真机验收**（唯一需要用户动手的一步）

```bash
./scripts/build-app.sh && killall vInput; open dist/vInput.app
```

请用户过一遍（结果按惯例拿 `~/Library/Logs/vInput/vInput.log` 核对）：
1. 菜单栏新图标；说话时变琥珀橙、处理中变波形。
2. 面板观感 + 设备卡（拔/连设备）。
3. HUD 观感；⌘＋/⌘－/⌘0；重启后字号仍在。
4. esc 取消后、以及完全空闲时，浏览器里 ⌘＋ 正常缩放页面（没被劫持）。
5. 深浅两种菜单栏外观下图标可辨（切系统外观）。

- [ ] **Step 4: 更新 Roadmap + 收尾提交**

`docs/Roadmap.md` 的 M9 行改为分批表述（第一批 UI 现代化 ✅ + 后续批次 设置界面/onboarding ⬜），验收记录写进本节。

```bash
git add docs/Roadmap.md
git commit -m "docs: M9 第一批（UI 现代化）验收记录"
```

---

## Self-review 已做的三项检查

1. **规格覆盖**：定稿 ①→Task 3/4/5，②→Task 6/7，③→Task 1/2/7，④→Task 8，测试与验收→各任务 Step 5 + Task 9。「不做什么」清单没有任务与之冲突。
2. **无占位**：每个代码步都有完整代码；Task 7 的设置四行标注了「照抄旧 MenuContent 对应子菜单」并给了对照清单——那是迁移（源码就在同一文件里），不是占位。
3. **类型一致性**：`VMark.bars/rects(in:)`（T1）↔ StatusIcon（T2）↔ VMarkShape（T7）；`HUDViewModel.fontSize/lineHeight(forFontSize:)/charsPerLine(forFontSize:)`（T3）↔ HUDView（T5）；`MenuPanelModel.deviceCards/headerStatus`（T6）↔ MenuPanelView（T7）。两处待实施时核实的真实签名已标注：`AppModel.permissionStatus` 的类型名、`MouseBridgeState.menuLabel(battery:)`。

## 真机验收发现（2026-08-21，用户实测）

### R-1（阻塞）从面板点「开始听写」后菜单栏图标消失，无法点「结束听写」

用户实测。`dismissMenuPanel()` 结尾的 `NSApp.hide(nil)` 把**整个应用**藏了，
LSUIElement 应用的菜单栏状态项跟着一起消失——于是从面板起的听写变成
**单向路**：图标没了，点不到「结束听写」，只能靠 ⌥D 或遥控器收尾。

此前只推演到它会藏掉 HUD（B-2，已用 `panel.canHide = false` 修），
**没想到它连状态项一起藏掉**——`canHide` 是单窗口属性，管不到状态项。

日志佐证（同一轮实测，第 2 条验收项）：目标捕获与注入本身是好的——
`目标应用已记录：com.apple.Terminal` → `注入成功 文本长度 11 字`。
所以问题单独出在「藏应用」这个动作的副作用上，不在焦点交还的正确性上。

**这说明 `NSApp.hide(nil)` 这条路本身选错了**，不是参数没调好：它要的是
「把前台让给别人」，而 `hide` 给的是「把自己整个藏起来」，后者顺带带走了
状态项与浮层。候选替代：`NSApp.deactivate()`；或记住面板打开前的前台应用
并显式 `activate` 回去。修法要连同 B-2 的 `canHide` 一起复核——若不再用
`hide`，那条可能就不需要了。
