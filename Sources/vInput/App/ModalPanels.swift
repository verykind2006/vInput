import AppKit

// 应用级模态面板（NSOpenPanel / NSAlert）集中在这一份文件里。
//
// 从 `vInputApp.swift` 平移过来（M9 Task 7），内容一字未改，只把 `private`
// 放宽成 `internal`：菜单面板视图搬到了 `UI/MenuPanelView.swift`，跨文件要调。
// 每个函数的注释都是真机踩坑记录（`activate` 为什么不能去掉、取消为什么是
// 默认按钮、为什么用 NSSecureTextField），随代码一起搬，一行没删。

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
