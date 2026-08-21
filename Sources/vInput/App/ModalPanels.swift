import AppKit

// 应用级模态面板（NSOpenPanel / NSAlert）集中在这一份文件里。
//
// 从 `vInputApp.swift` 平移过来（M9 Task 7），内容一字未改，只把 `private`
// 放宽成 `internal`：菜单面板视图搬到了 `UI/MenuPanelView.swift`，跨文件要调。
// 每个函数的注释都是真机踩坑记录（`activate` 为什么不能去掉、取消为什么是
// 默认按钮、为什么用 NSSecureTextField），随代码一起搬，一行没删。

/// 关掉菜单栏面板，并把焦点还给用户原来那个应用。
///
/// **旧的原生菜单免费拥有这个行为**：点一下菜单项，菜单自己关闭，前台应用
/// 从来没变过。`.window` 样式的面板不是菜单——点完按钮它还开着，而这个应用
/// 是往别人的输入框里注字的。
///
/// 不关的两种坏结果（`TargetAppGuard.capture()` 在会话开始时记下当时的前台
/// 应用，`DictationSession` 注入前用 `verify` 比对）：
///
/// - 面板开着时前台是 vInput 自己 → 记下的目标是 vInput，转写出来的文字被
///   注进这个面板，等于凭空消失。
/// - 用户点别处关掉面板 → 前台在录音途中变了 → `verify` 抛
///   `targetApplicationChanged`，用户看到「焦点已切到别的应用，文字没有
///   输入」——说了半天，一个字都没进去。
///
/// **不许用 `NSApp.hide(nil)`。** 这是 R-1（2026-08-21 用户真机实测）：
/// `hide` 要的是「把自己整个藏起来」，而这里要的是「把前台让给别人」——前者
/// 顺带把 LSUIElement 应用的菜单栏状态项一起带走，于是从面板起的听写变成
/// **单向路**：图标没了，点不到「结束听写」，只能靠 ⌥D 或遥控器收尾。
/// （`HUDPanel` 的 `canHide = false` 是单窗口属性，管不到状态项。）
///
/// 换成「显式激活面板打开前的那个应用」。三种机制的探针实测
/// （LSUIElement .app 包 + 状态项 + 浮层 + 真实目标应用 TextEdit，
/// 前置条件校验过「执行前自己确实是前台」）：
///
/// | 机制 | 前台还回去了吗 | 应用被藏 | 面板窗口 |
/// | --- | --- | --- | --- |
/// | `NSApp.hide(nil)` | +0.05s 回到 TextEdit | **是** | 被 orderOut |
/// | `NSApp.deactivate()` | **没有**：+0.5s 时自己仍是前台，+1.5s 前台变成了
///   一个无关应用（Terminal），始终没回到 TextEdit | 否 | 留着 |
/// | `previousApp.activate()` | +0.05s 回到 TextEdit，直到 +3.0s 都稳定 | 否 | 留着 |
///
/// 所以 `deactivate()` 被实测排除：它不交还前台，而不交还前台恰好会打掉
/// 日志里已经验证是好的那条链（`目标应用已记录：com.apple.Terminal`）——
/// `TargetAppGuard.capture()` 会记成 vInput 自己，文字注进面板等于消失。
///
/// **调用方必须把真正的动作推到下一个 runloop turn**（见
/// `MenuPanelView.primaryButton`）——焦点交还是异步的（探针实测 +0.05s 才
/// 生效），同一轮里紧接着 `capture()` 拿到的还是旧值。
/// **不认「谁是 key 就关谁」。** 面板若压根没成为 key window，
/// `NSApp.keyWindow` 就是当时碰巧是 key 的那个，而 `VINPUT_BENCH=1` 下那
/// 可能是基准集录制窗口（`BenchRecordingWindow.swift:83`，`.titled`）。
/// 关掉它会走 `windowWillClose` → `onClose?()`，**把正在进行的录制一起
/// 结束掉**——开发期工具被静默中断是很难查的那种事故。
///
/// 判据用 `.titled`：本应用自己拉起的有标题栏的窗口只有基准集录制窗，
/// 而 MenuBarExtra 的宿主窗口没有标题栏。宁可少关一个（让位那步兜底），
/// 不可错关一个。
@MainActor
func dismissMenuPanel() {
    if let key = NSApp.keyWindow, !key.styleMask.contains(.titled) {
        key.close()
    }
    if !ForegroundAppTracker.shared.handBackForeground() {
        // 兜底：不知道该还给谁（或系统拒绝了这次 activate）。探针实测
        // `deactivate()` 交还前台并不可靠，所以这只是「至少别赖在前台」的
        // 尽力而为——但它绝不会藏掉状态项，那才是 R-1 的要害。
        // 正常情况走不到这里：`ForegroundAppTracker` 在启动时就播了种，
        // 而 LSUIElement 应用启动时不激活，那一刻的前台必然是别人。
        NSApp.deactivate()
    }
}

/// 记住「vInput 抢到前台之前，用户在用的是哪个应用」，供 `dismissMenuPanel()`
/// 把前台还回去。
///
/// **为什么不是「面板打开时问一次 `NSWorkspace.frontmostApplication`」**：
/// 点状态项的那一下已经把 vInput 激活了，`MenuPanelView.onAppear` 跑的时候
/// 前台很可能已经是 vInput 自己——问到自己等于没记，而「把前台让给自己」是
/// 空操作，坏结果与不让位完全一样（文字注进面板）。
///
/// 那个时序在本仓库里**测不出来**（`MenuBarExtra` 要真 App 生命周期加一次
/// 真鼠标点击），所以这里挑了一条与时序无关的路：订阅激活通知，只记最后
/// 一个不是自己的应用。什么时候记的不重要，记的一定不是自己。
@MainActor
final class ForegroundAppTracker {
    static let shared = ForegroundAppTracker()

    /// 最后一个成为前台的、不是 vInput 自己的应用。
    private(set) var previousApp: NSRunningApplication?

    private var observer: NSObjectProtocol?

    /// 「自己」的进程号。**两个来源都收**：真机上两者相同，而在没有应用包的
    /// 进程里（比如 `swift test` 的宿主）`NSRunningApplication.current` 的
    /// `processIdentifier` 是 -1——只认其中一个的话，要么真机漏过滤、要么
    /// 测试里根本验不到这条过滤。多收一个 -1 不会误伤：没有应用的 pid 是 -1。
    private let selfProcessIdentifiers: Set<pid_t> = [
        NSRunningApplication.current.processIdentifier,
        ProcessInfo.processInfo.processIdentifier,
    ]

    /// 启动时调用一次（`AppDelegate.applicationDidFinishLaunching`）。
    ///
    /// 先播种再订阅：LSUIElement 应用启动时不激活自己，此刻的前台就是用户
    /// 正在用的那个应用；只订阅不播种的话，用户从启动到第一次切换应用之间
    /// 点开面板，`previousApp` 是 nil。
    func start(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        record(NSWorkspace.shared.frontmostApplication)
        guard observer == nil else { return }
        observer = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                ForegroundAppTracker.shared.record(
                    note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            }
        }
    }

    /// **过滤掉自己是这个类存在的全部理由。**
    ///
    /// 比 `processIdentifier` 而不是比对象：`NSRunningApplication` 没有重写
    /// `isEqual`，同一个应用在不同通知里可能是两个不同的对象，`==` 会漏判。
    ///
    /// `nil` 也直接返回：通知的 userInfo 取不到应用时（系统偶发，或 key 改名）
    /// 不能把已经记住的那个抹掉，抹掉的后果与记成自己一样——让位无处可还。
    func record(_ app: NSRunningApplication?) {
        guard let app, !selfProcessIdentifiers.contains(app.processIdentifier) else { return }
        previousApp = app
    }

    /// 把前台还给 `previousApp`。返回是否真的发出了这次让位。
    @discardableResult
    func handBackForeground() -> Bool {
        guard let previousApp else { return false }
        return previousApp.activate()
    }
}

/// 弹出校正模型目录选择器，返回用户选中的目录（取消时为 nil）。
///
/// 提到文件作用域而不是留在菜单视图里：两个调用方（菜单里的「指定校正
/// 模型…」，以及 `AppModel` 在开启校正却没有合法模型时的追问）需要同一个
/// 面板，而后者与视图的生命周期无关。
///
/// **`activate` 不能去掉**：LSUIElement 应用默认不激活，不先 activate 的话
/// 面板会出现在其他窗口后面且不接受键盘输入。这里是设置类操作，抢焦点无妨
/// ——听写路径上的 HUD 才必须避免抢焦点。
@MainActor
func presentCorrectionModelFolderPanel() -> URL? {
    NSApplication.shared.activate(ignoringOtherApps: true)

    let panel = NSOpenPanel()
    panel.title = "选择校正模型目录"
    panel.message = "选择本地 MLX 模型目录（含 config.json、tokenizer_config.json 与 .safetensors 权重文件）"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false

    guard panel.runModal() == .OK else { return nil }
    return panel.url
}

/// 打开 Whisper 模型目录选择器，返回用户选中的目录（取消时为 nil）。
///
/// 从旧 `MenuContent.chooseModelFolder()` 里抽出来的那段 NSOpenPanel，
/// 标题/说明/开关逐字未动；「选完做什么」留在调用方
/// （旧版是 `model.selectModelFromFolder(url.path)`）。
///
/// LSUIElement 应用默认不激活，不先 activate 的话面板会出现在
/// 其他窗口后面且不接受键盘输入。这里是设置类操作，抢焦点无妨——
/// 听写路径上的 HUD 才必须避免抢焦点。
@MainActor
func presentWhisperModelFolderPanel() -> URL? {
    NSApplication.shared.activate(ignoringOtherApps: true)

    let panel = NSOpenPanel()
    panel.title = "选择 Whisper 模型目录"
    panel.message = "选择包含 AudioEncoder.mlmodelc、TextDecoder.mlmodelc、MelSpectrogram.mlmodelc 的目录"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false

    guard panel.runModal() == .OK else { return nil }
    return panel.url
}

/// 弹出「开启云端翻译」的确认框，返回用户是否确认。
///
/// **不是普通的开关切换**：一开，用户说的每一句话都会发到 Google，而这个
/// 工具会用在含报价的场合。文案（含「输出语言是中文时零出站」那一条）在
/// `AppModel.cloudBackendConfirmation` 里，由测试钉着。
///
/// 两处细节：
///
/// - **取消是默认按钮**。`NSAlert` 里先加的那个是默认按钮（回车触发），
///   所以取消先加、开启后加，判 `alertSecondButtonReturn`。一路回车不该把
///   出站开关按开。
/// - `.critical` 而不是 `.warning`：这是不可逆地把内容发给第三方的动作。
/// - `activate` 不能去掉，理由同 `presentCorrectionModelFolderPanel`。
@MainActor
func presentCloudBackendConfirmation() -> Bool {
    NSApplication.shared.activate(ignoringOtherApps: true)

    let copy = AppModel.cloudBackendConfirmation
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = copy.title
    alert.informativeText = copy.message
    alert.addButton(withTitle: copy.cancelButton)
    alert.addButton(withTitle: copy.confirmButton)
    return alert.runModal() == .alertSecondButtonReturn
}

/// 输入云端 API key。
///
/// **用 `NSSecureTextField`**：key 会出现在屏幕上，而用户很可能在会议里
/// 共享着屏幕——这个工具的用户就是拿它口述报价的人。
///
/// - 返回的字符串是密钥本身，**调用方绝不可以把它写进日志**。
/// - `activate` 不能去掉，理由同 `presentCorrectionModelFolderPanel`：
///   菜单栏应用不激活的话面板会出现在别的窗口后面。
@MainActor
func presentCloudAPIKeyPanel() -> String? {
    NSApplication.shared.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = "输入 Gemini API Key"
    alert.informativeText = """
        key 存进本机的 Keychain，不进日志、不进仓库、不随任何东西上传。

        开启云端翻译后，你说的每一句话都会发到 Google 的服务器。
        涉及报价、客户信息等机密内容时不要开启。
        """
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.placeholderString = "粘贴 API Key"
    alert.accessoryView = field
    alert.addButton(withTitle: "存入 Keychain")
    alert.addButton(withTitle: "取消")
    // 让输入框拿到焦点，否则粘贴要先点一下。
    alert.window.initialFirstResponder = field

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let value = field.stringValue
    return value.isEmpty ? nil : value
}

/// 输入自定义的云端模型标识符。
@MainActor
func presentCloudModelPanel(current: String) -> String? {
    NSApplication.shared.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = "自定义云端模型"
    alert.informativeText = """
        填 Google 的模型标识符，例如 gemini-2.0-flash。

        这里填什么都不会被校验——vInput 至今没有对 Gemini 发过一次真实
        请求。填错的表现是每次听写都退回中文原文，日志里是一条 HTTP 4xx。
        """
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.stringValue = current
    alert.accessoryView = field
    alert.addButton(withTitle: "使用")
    alert.addButton(withTitle: "取消")
    alert.window.initialFirstResponder = field

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return field.stringValue
}
