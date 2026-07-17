import AppKit
import Carbon.HIToolbox

@MainActor
final class GlobalHotKeyManager {
    var onPressed: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let identifier: UInt32

    init(identifier: UInt32 = 1) {
        self.identifier = identifier
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated {
                    manager.onPressed?()
                }
                return noErr
            },
            1,
            &eventType,
            pointer,
            &handlerRef
        )
    }

    func register(_ shortcut: CaptureShortcut) {
        register(keyCode: shortcut.keyCode, modifiersRaw: shortcut.modifiersRaw)
    }

    func register(keyCode: UInt16, modifiersRaw: UInt) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        let flags = NSEvent.ModifierFlags(rawValue: modifiersRaw)
        var carbonModifiers: UInt32 = 0
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        let hotKeyID = EventHotKeyID(signature: OSType(0x53534854), id: identifier) // SSHT
        RegisterEventHotKey(
            UInt32(keyCode),
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func invalidate() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

}
