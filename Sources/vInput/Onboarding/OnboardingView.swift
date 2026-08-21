import SwiftUI

/// 首次启动向导的界面：欢迎 → 麦克风 → 辅助功能 → 下载模型 → 试说一句。
///
/// ## 验收标准就是这一屏
///
/// 读它的人是「只会双击安装包」的那位——装完能自己说出第一句话。因此每一步
/// 只讲一件事、只给一个主按钮，说明用大白话，不出现「辅助功能 API」
/// 「模型变体」这类词。
///
/// ## 视觉：跟 M9 同一套，但**不锁死深浅**
///
/// 强调色、V 字 mark 走 `VITheme`，字号成表（下面的 `TypeScale`）——与菜单
/// 面板同源。**唯一不照抄的是底色**：`MenuPanelView` 把底色写死成
/// `VITheme.panelBackground`（深色）并因此钉死 `colorScheme = .dark`，那是
/// 因为它长在菜单栏面板里、本就该是深的。向导是一扇普通窗口，是这个应用给
/// 新用户的第一印象——深色模式下弹出一扇突兀的白窗（或浅色模式下一扇突兀的
/// 黑窗）只会显得没做完。所以底色用系统的 `windowBackgroundColor`，
/// 内容块用 `controlBackgroundColor`，跟着系统走。窗口那侧的对应决定见
/// `OnboardingWindowController.makeWindow`（不设 appearance）。
///
/// ## 逻辑一律不在这里
///
/// 视图只读 `coordinator` 的属性、只调它的方法。这不是洁癖：本仓库在
/// 「重试」的禁用文案上栽过——文案拼在视图里，全仓测试一条都守不住它。
/// 凡是判断（下载完没完、能不能点完成、第几步）都在
/// `OnboardingCoordinator` 上，那边测得到。
struct OnboardingView: View {
    @Bindable var coordinator: OnboardingCoordinator

    /// 向导的字号表。
    ///
    /// **比 `MenuPanelView.TypeScale` 整体大一档**，不是复用它。那张表是给
    /// 320pt 宽、贴着菜单栏、老用户扫一眼就关掉的面板定的；这里是 560pt 宽的
    /// 窗口，读它的人第一次见这个应用，要逐字读完才知道下一步干什么。
    /// 沿用 13/12pt 会让向导看上去像一份说明书的脚注。
    enum TypeScale {
        /// 每一步的标题，整扇窗里最大的一处。
        static let title: CGFloat = 22
        /// 正文说明。
        static let body: CGFloat = 15
        /// 次要说明、进度百分比、步骤指示。
        static let secondary: CGFloat = 13
        /// 主按钮。
        static let button: CGFloat = 15
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                stepBody
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            VMarkShape(bars: VMark.bars)
                .fill(VITheme.accent)
                .frame(width: 18, height: 18)
            Text("vInput").font(.system(size: TypeScale.body, weight: .semibold))
            Spacer()
            if let indicator = coordinator.stepIndicator {
                Text(indicator)
                    .font(.system(size: TypeScale.secondary))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - 分步

    @ViewBuilder
    private var stepBody: some View {
        switch coordinator.state.step {
        case .welcome: welcomeStep
        case .microphone: microphoneStep
        case .accessibility: accessibilityStep
        case .downloadModel: downloadStep
        case .testDictation: testDictationStep
        }
    }

    // MARK: - ① 欢迎

    /// 一句话说清这个应用是干什么的，外加「一共几步」。
    ///
    /// 步数由 `coordinator.plannedSteps` 给，不是写死的 5——已经给过权限的人
    /// 走的步数更少，第一句话就不准的话，后面说什么都要打折。
    private var welcomeStep: some View {
        stepScaffold(
            title: "欢迎使用 vInput",
            body: [
                "按一下 ⌥D 开始说话，说完再按一下，你说的话就会变成文字打进你正在用的那个窗口"
                    + "——微信、邮件、备忘录都行。",
                "接下来一共 \(coordinator.plannedSteps.count) 步，几分钟就好。",
            ]
        ) {
            primaryButton("开始") { coordinator.advance() }
        }
    }

    // MARK: - ② 麦克风

    private var microphoneStep: some View {
        stepScaffold(
            title: "允许使用麦克风",
            body: [
                "vInput 要听见你说话，才能把它写成文字。",
                "点下面的按钮，系统会弹出一个框，选「好」就行。",
            ]
        ) {
            primaryButton("允许使用麦克风") { coordinator.requestMicrophone() }
        }
    }

    // MARK: - ③ 辅助功能

    /// **这一步没有对话框**，必须把这件事说明白。
    ///
    /// 用户点完按钮会被扔进「系统设置」，那里有一长串应用和一排开关；
    /// 不说清要找哪一个、勾完之后回来会怎样，他就会卡在那儿。
    /// 勾完自动翻页由 `AccessibilityPoller` 每 0.5 秒轮询实现——
    /// 没有它，用户勾完切回来看到的还是这一屏，无从判断向导察觉了没有。
    private var accessibilityStep: some View {
        stepScaffold(
            title: "允许把文字打进别的应用",
            body: [
                "这一项没有弹窗，要你自己去系统设置里打开一个开关。",
                "点下面的按钮会直接跳到那一页：在列表里找到 vInput，把它前面的开关打开。",
                "打开之后直接切回来就行，这个窗口会自己继续。",
            ]
        ) {
            primaryButton("打开系统设置") { coordinator.openAccessibilitySettings() }
            Text("正在等你打开开关…")
                .font(.system(size: TypeScale.secondary))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - ④ 下载模型

    /// 进度条 + 三种收场：还在下、下完了、失败了。
    ///
    /// 下载**不是**在这一步才开始的（那样用户就得干等 1.5GB），
    /// 而是在 `OnboardingCoordinator.present()` 里就踢起来了——前三步的时间
    /// 全部被它吃掉。这一步只是把进度显示出来。
    private var downloadStep: some View {
        stepScaffold(
            title: "正在准备语音模型",
            body: ["第一次使用要下载一个约 1.5GB 的语音模型，之后就不用再下了。"]
        ) {
            if let failure = coordinator.downloadFailure {
                Text(failure)
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    primaryButton("重试") { coordinator.retryModelDownload() }
                    // 手动导入复用菜单里那个目录选择器（`presentWhisperModelFolderPanel`），
                    // 不另造一个——两个选择器的校验标准迟早会走岔。
                    secondaryButton("我已经有模型文件") { coordinator.importExistingModel() }
                }
            } else if coordinator.downloadFinished {
                Text("模型已经准备好了。")
                    .font(.system(size: TypeScale.body))
                primaryButton("下一步") { coordinator.advance() }
            } else {
                ProgressView(value: coordinator.downloadProgress)
                    .progressViewStyle(.linear)
                    .tint(VITheme.accent)
                Text("已下载 \(coordinator.progressText)")
                    .font(.system(size: TypeScale.secondary))
                    .foregroundStyle(.secondary)
                secondaryButton("我已经有模型文件") { coordinator.importExistingModel() }
            }
        }
    }

    // MARK: - ⑤ 试说一句

    /// 试说出来的字落进**下面这个输入框**，不会进任何别的应用。
    ///
    /// 那条保证不是靠「向导此刻是前台」——是靠
    /// `OnboardingCoordinator.enter(.testDictation)` 把注入改道到了
    /// `RedirectableTextSink`：这条路上根本没有 CGEvent 被投递。
    ///
    /// 文案说的是「按一下 ⌥D……说完再按一下」而不是「按住」：⌥D 走 Carbon
    /// 热键，只注册了 `kEventHotKeyPressed`（`HotkeyRegistrar.swift`），
    /// 是按一下开、再按一下停的开关，不是按住不放。真按住的话松手前什么都
    /// 不会发生，而这一步恰恰是用来建立信心的。
    private var testDictationStep: some View {
        stepScaffold(
            title: "试着说一句话",
            body: [
                "按一下 ⌥D 开始说话，说完再按一下。你说的话会出现在下面的框里。",
                "（也可以直接点下面的按钮，效果一样。）",
            ]
        ) {
            TextField("说完这里会出现文字", text: $coordinator.dictationText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: TypeScale.body))
                .lineLimit(3, reservesSpace: true)

            HStack(spacing: 12) {
                primaryButton("开始 / 结束说话") { coordinator.toggleDictation() }
                    .disabled(!coordinator.isDictationReady)
                if !coordinator.isDictationReady {
                    Text("语音模型还在准备，稍等一下…")
                        .font(.system(size: TypeScale.secondary))
                        .foregroundStyle(.secondary)
                }
            }

            // 「说出来了才算过」——`canFinish` 在 coordinator 上，测得到。
            secondaryButton("完成") { coordinator.complete() }
                .disabled(!coordinator.canFinish)
        }
    }

    // MARK: - 复用的排版与控件

    /// 每一步都是同一副骨架：标题 + 若干段说明 + 动作区。
    ///
    /// 抽出来是为了「每一步长得一样」这件事不靠自觉：五步各写一遍的话，
    /// 间距和字号迟早各走各的。
    private func stepScaffold(
        title: String,
        body lines: [String],
        @ViewBuilder actions: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: TypeScale.title, weight: .semibold))
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: TypeScale.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) { actions() }
                .padding(.top, 4)
        }
    }

    /// 主按钮：琥珀橙渐变，与菜单面板的「开始听写」同一副外观。
    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: TypeScale.button, weight: .semibold))
                .foregroundStyle(Color(red: 0.10, green: 0.07, blue: 0.02))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [VITheme.accentGradientTop, VITheme.accentGradientBottom],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    /// 次要按钮：不抢主按钮的视线，但也不能藏起来——
    /// 「我已经有模型文件」是下载失败时唯一的活路。
    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: TypeScale.button))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9).stroke(VITheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
