import Foundation
import Carbon

@MainActor
final class HotKeyManager {
    private var hotKeys: [UInt32: EventHotKeyRef?] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?

    init() {
        registerHandler()
    }

    func registerDefaultHotKeys() {
        registerHotKey(id: 1, keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey)) {
            LauncherAppController.shared.activateApp()
        }
        registerHotKey(id: 2, keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey)) {
            LauncherAppController.shared.launchLastPlayed()
        }
        registerHotKey(id: 3, keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey)) {
            LauncherAppController.shared.rescan()
        }
        registerHotKey(id: 4, keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey | optionKey)) {
            LauncherAppController.shared.openSettings()
        }
    }

    private func registerHandler() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, eventRef, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            Task { @MainActor in
                HotKeyManager.sharedHandle(hotKeyID.id)
            }
            return noErr
        }, 1, &eventSpec, nil, &handlerRef)
    }

    private func registerHotKey(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        actions[id] = action
        let hotKeyID = EventHotKeyID(signature: OSType("RYJX".fourCharCodeValue), id: id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        hotKeys[id] = ref
    }

    private func handle(_ id: UInt32) {
        actions[id]?()
    }

    private static func sharedHandle(_ id: UInt32) {
        shared.handle(id)
    }

    static let shared = HotKeyManager()
}

private extension String {
    var fourCharCodeValue: UInt32 {
        var result: UInt32 = 0
        for scalar in unicodeScalars {
            result = (result << 8) + scalar.value
        }
        return result
    }
}
