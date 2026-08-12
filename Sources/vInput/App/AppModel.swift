import Carbon.HIToolbox
import Foundation
import Observation
import SwiftUI

/// 顶层接线：把各层组装起来，并把状态暴露给菜单栏 UI。
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case idle
        case listening
        case working
        case error(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastText: String = ""
    private(set) var permissionStatus: Permissions.Status = .ready
    /// 实际选中的模型，显示在菜单栏，方便确认切换是否生效。
    private(set) var activeModelName: String = ""

    private let permissions = Permissions()
    private let hotkey = HotkeyRegistrar()
    private var session: DictationSession?

    /// 默认快捷键：Option + D。
    private let hotkeyCode = UInt32(kVK_ANSI_D)
    private let hotkeyModifiers = UInt32(optionKey)

    /// 本地模型目录。WhisperKit 内置的下载器在丢包网络下会整体超时，
    /// 模型由 scripts/fetch-model.sh 用 curl 预拉。目录不存在时
    /// 回退到按名称下载。
    ///
    /// 按 `preferredModels` 的顺序取第一个本地已存在的，
    /// 因此换模型只需下载对应目录，无需改代码。
    private static func resolvedModel() -> (name: String, folder: String?) {
        let root = Bundle.main.bundleURL
            .deletingLastPathComponent()   // dist/
            .deletingLastPathComponent()   // 仓库根

        for name in ModelPreference.preferredModels {
            let path = root.appendingPathComponent("vendor/models/\(name)").path
            if FileManager.default.fileExists(atPath: path) {
                return (name, path)
            }
        }
        // 一个本地模型都没有，交给 WhisperKit 自行下载（此网络下大概率失败，
        // 会以 TranscribeError.engineFailed 的形式出现在菜单栏状态里）。
        return (ModelPreference.preferredModels.last ?? "base", nil)
    }

    func bootstrap() {
        permissionStatus = permissions.status()

        let model = Self.resolvedModel()
        activeModelName = model.name

        let session = DictationSession(
            audioSource: SystemMicSource(),
            transcriber: WhisperKitTranscriber(
                modelName: model.name,
                modelFolder: model.folder,
                language: "zh"
            ),
            sink: RoutingTextSink(
                typing: TypingSink(),
                clipboard: ClipboardSink(),
                threshold: 100
            ),
            targetGuard: TargetAppGuard()
        )

        session.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .idle: self.phase = .idle
            case .listening: self.phase = .listening
            case .transcribing, .injecting: self.phase = .working
            }
        }
        session.onError = { [weak self] error in
            self?.phase = .error(String(describing: error))
        }
        session.onText = { [weak self] text in
            self?.lastText = text
        }
        self.session = session

        do {
            try hotkey.register(keyCode: hotkeyCode, modifiers: hotkeyModifiers) { [weak self] in
                self?.toggle()
            }
        } catch {
            phase = .error("快捷键注册失败：\(error)")
        }
    }

    func shutdown() {
        hotkey.unregister()
    }

    /// 快捷键触发：未在录音则开始，正在录音则结束。
    func toggle() {
        guard let session else { return }

        permissionStatus = permissions.status()
        guard permissionStatus == .ready else {
            handleMissingPermission()
            return
        }

        switch session.state {
        case .idle:
            do {
                try session.start()
            } catch {
                phase = .error(String(describing: error))
            }
        case .listening:
            Task { await session.finish() }
        case .transcribing, .injecting:
            // 正在处理上一段，忽略。
            break
        }
    }

    private func handleMissingPermission() {
        switch permissionStatus {
        case .microphoneMissing:
            Task {
                _ = await permissions.requestMicrophone()
                permissionStatus = permissions.status()
            }
        case .accessibilityMissing:
            permissions.openAccessibilitySettings()
        case .ready:
            break
        }
    }
}
