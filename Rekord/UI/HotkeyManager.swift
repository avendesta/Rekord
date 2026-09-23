import Carbon.HIToolbox

/// Registers one global shortcut via Carbon's RegisterEventHotKey, which works
/// from any app without Accessibility permission.
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onTrigger: () -> Void

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    deinit { unregister() }

    /// Returns false when the combination can't be registered, typically because
    /// another app already holds it.
    @discardableResult
    func register(_ hotkey: Hotkey) -> Bool {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.onTrigger() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x52454B44), id: 1) // 'REKD'
        let status = RegisterEventHotKey(UInt32(hotkey.keyCode), UInt32(hotkey.modifiers), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { unregister() }
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
