import Carbon.HIToolbox
import Foundation

/// 热键 ID 到 Swift 闭包的映射。
///
/// Carbon 的事件处理器是 C 函数指针，无法捕获上下文，
/// 只能拿到一个整数 ID，因此需要这张表做转发。
@MainActor
final class HotkeyCallbackTable {
    static let shared = HotkeyCallbackTable()

    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    func register(_ handler: @escaping () -> Void) -> UInt32 {
        let id = nextID
        nextID += 1
        handlers[id] = handler
        return id
    }

    func unregister(_ id: UInt32) {
        handlers.removeValue(forKey: id)
    }

    func dispatch(_ id: UInt32) {
        handlers[id]?()
    }
}

enum HotkeyError: Error, Equatable {
    case registrationFailed(OSStatus)
    case handlerInstallFailed(OSStatus)
}

/// 一个全局快捷键的注册与生命周期管理。
///
/// 使用 Carbon `RegisterEventHotKey`，**不需要「输入监控」权限**。
/// 只有发送 CGEvent 才需要辅助功能授权。
@MainActor
final class HotkeyRegistrar {
    /// 应用签名，用于区分不同应用注册的热键。'vINP'
    private static let signature: OSType = 0x76_49_4E_50

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var callbackID: UInt32?

    /// 注册快捷键。
    /// - Parameters:
    ///   - keyCode: Carbon 虚拟键码，例如 `UInt32(kVK_ANSI_D)`
    ///   - modifiers: Carbon 修饰键掩码，例如 `UInt32(optionKey | cmdKey)`
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        handler: @escaping () -> Void
    ) throws {
        unregister()

        let id = HotkeyCallbackTable.shared.register(handler)
        callbackID = id

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var pressedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard status == noErr else { return status }
                let identifier = pressedID.id
                // Carbon 回调在主线程，但编译器不知道，显式跳一次。
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        HotkeyCallbackTable.shared.dispatch(identifier)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard installStatus == noErr else {
            HotkeyCallbackTable.shared.unregister(id)
            callbackID = nil
            throw HotkeyError.handlerInstallFailed(installStatus)
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            unregister()
            throw HotkeyError.registrationFailed(registerStatus)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        if let callbackID {
            HotkeyCallbackTable.shared.unregister(callbackID)
            self.callbackID = nil
        }
    }

    // deinit 不能进 MainActor，因此不在此处调用 unregister()。
    // AppModel 负责在应用退出前显式调用。
}
