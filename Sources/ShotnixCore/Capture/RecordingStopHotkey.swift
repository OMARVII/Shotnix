import AppKit
import Carbon.HIToolbox

/// ⌃⌘Esc stops a recording from any app — the macOS convention for screen
/// recordings. A Carbon hot key needs no Accessibility access, and it is
/// registered only while a recording runs, so plain Esc keeps working in
/// the recorded app (and shows up as a keycap) and the combination is free
/// the rest of the time.
@MainActor
enum RecordingStopHotkey {
    static let displayText = "⌃⌘Esc"

    private static var hotKey: EventHotKeyRef?
    private static var eventHandler: EventHandlerRef?
    private static var action: (() -> Void)?
    nonisolated private static let signature: OSType = 0x534E_5253 // "SNRS"

    static var isRegistered: Bool { hotKey != nil }

    static func register(_ action: @escaping () -> Void) {
        unregister()
        installHandlerIfNeeded()
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            UInt32(controlKey | cmdKey),
            EventHotKeyID(signature: signature, id: 1),
            GetEventDispatcherTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            // Taken elsewhere (another app, or the user's own Stop Recording
            // shortcut): the HUD, the menu bar and that shortcut still stop.
            print("[Shotnix] ⌃⌘Esc stop shortcut unavailable: \(status)")
            return
        }
        hotKey = reference
        self.action = action
    }

    static func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        action = nil
    }

    private static func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            // Other hot keys (the user's shortcuts) belong to other handlers.
            guard status == noErr, hotKeyID.signature == RecordingStopHotkey.signature else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { RecordingStopHotkey.action?() }
            }
            return noErr
        }, 1, &eventType, nil, &eventHandler)
    }
}
