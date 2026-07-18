import AppKit

/// Detects and disables macOS native screenshot shortcuts that conflict with Shotnix.
/// The native shortcuts (⌘⇧3, ⌘⇧4, ⌘⇧5) are stored in com.apple.symbolichotkeys.
enum NativeShortcutManager {

    // Symbolic hotkey IDs for macOS screenshot shortcuts.
    // 28 = ⌘⇧3 (fullscreen screenshot)
    // 29 = ⌘⇧⌃3 (fullscreen screenshot to clipboard)
    // 30 = ⌘⇧4 (area screenshot)
    // 31 = ⌘⇧⌃4 (area screenshot to clipboard)
    // 184 = ⌘⇧5 (screenshot/recording toolbar)
    private static let screenshotHotkeyIDs = [28, 29, 30, 31, 184]
    private static let promptKey = "didPromptNativeShortcuts"
    // Set when the user picks "Don't Ask Again" — suppresses the conflict prompt
    // until they opt back in via restoreNativeShortcuts().
    private static let declinedPromptKey = "declinedNativeShortcutsPrompt"
    private static let appID = "com.apple.symbolichotkeys"
    private static let hotkeysKey = "AppleSymbolicHotKeys"
    private static let screenshotHotkeyParameters: [Int: [Int]] = [
        28: [51, 20, 1_179_648],
        29: [51, 20, 1_441_792],
        30: [52, 21, 1_179_648],
        31: [52, 21, 1_441_792],
        184: [53, 23, 1_179_648]
    ]

    /// Returns true if any native screenshot shortcuts are still enabled.
    static var nativeShortcutsEnabled: Bool {
        let anyHostHotkeys = readHotkeys(host: kCFPreferencesAnyHost)
        let currentHostHotkeys = readHotkeys(host: kCFPreferencesCurrentHost)
        let states = screenshotShortcutStates(in: anyHostHotkeys) + screenshotShortcutStates(in: currentHostHotkeys)
        guard !states.isEmpty else { return true }
        return states.contains(true)
    }

    private static func screenshotShortcutStates(in hotkeys: [String: Any]?) -> [Bool] {
        guard let hotkeys else { return [] }
        return screenshotHotkeyIDs.compactMap { id in
            (hotkeys["\(id)"] as? [String: Any])?["enabled"] as? Bool
        }
    }

    /// Disables native macOS screenshot shortcuts (⌘⇧3, ⌘⇧4, ⌘⇧5).
    /// Requires a logout/login or cfprefsd restart to take full effect,
    /// but most apps pick up the change immediately.
    @discardableResult
    static func disableNativeShortcuts() -> Bool {
        setNativeShortcuts(enabled: false) && !nativeShortcutsEnabled
    }

    /// Re-enables Apple's native screenshot shortcuts (⌘⇧3, ⌘⇧4, ⌘⇧5) —
    /// an escape hatch for users who want the system shortcuts back.
    /// Also clears the "Don't Ask Again" flag so the conflict prompt can reappear.
    @discardableResult
    static func restoreNativeShortcuts() -> Bool {
        UserDefaults.standard.removeObject(forKey: declinedPromptKey)
        UserDefaults.standard.removeObject(forKey: promptKey)
        return setNativeShortcuts(enabled: true) && nativeShortcutsEnabled
    }

    private static func setNativeShortcuts(enabled: Bool) -> Bool {
        guard let currentDict = readHotkeys(host: kCFPreferencesAnyHost) ?? readHotkeys(host: kCFPreferencesCurrentHost) else { return false }

        var newDict = currentDict
        for id in screenshotHotkeyIDs {
            var entry = newDict["\(id)"] as? [String: Any] ?? defaultHotkeyEntry(for: id)
            entry["enabled"] = enabled
            if entry["value"] == nil {
                entry["value"] = defaultHotkeyValue(for: id)
            }
            newDict["\(id)"] = entry
        }

        let cfWrite = writeWithCFPreferences(newDict, host: kCFPreferencesAnyHost)
        let currentHostWrite = writeWithCFPreferences(newDict, host: kCFPreferencesCurrentHost)
        reloadSystemShortcutPreferences()
        return cfWrite || currentHostWrite
    }

    /// Shows a dialog offering to disable conflicting native shortcuts.
    /// Suppressed once the user picks "Don't Ask Again" (tracked via UserDefaults)
    /// until they opt back in via restoreNativeShortcuts().
    @MainActor
    static func promptIfNeeded(onDisabled: (() -> Void)? = nil) {
        guard nativeShortcutsEnabled else {
            UserDefaults.standard.set(true, forKey: promptKey)
            onDisabled?()
            return
        }

        guard !UserDefaults.standard.bool(forKey: declinedPromptKey) else { return }

        if UserDefaults.standard.bool(forKey: promptKey) {
            UserDefaults.standard.removeObject(forKey: promptKey)
        }

        showConflictAlert(onDisabled: onDisabled)
    }

    @MainActor
    private static func showConflictAlert(onDisabled: (() -> Void)?) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Shortcut Conflict Detected"
        alert.informativeText = """
        macOS screenshot shortcuts (⌘⇧3, ⌘⇧4, ⌘⇧5) conflict with Shotnix.

        Disable them so Shotnix owns the capture shortcuts and screenshots do not double-trigger.

        You can re-enable Apple's shortcuts anytime in System Settings → Keyboard → Keyboard Shortcuts → Screenshots.
        """
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard")
        alert.addButton(withTitle: "Disable Apple Shortcuts")
        alert.addButton(withTitle: "Open Keyboard Settings")
        alert.addButton(withTitle: "Don't Ask Again")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            if disableNativeShortcuts() {
                UserDefaults.standard.set(true, forKey: promptKey)
                showSuccessToast()
                onDisabled?()
            } else {
                showManualInstructionsAlert()
            }
        } else if response == .alertSecondButtonReturn {
            openKeyboardSettings()
        } else {
            UserDefaults.standard.set(true, forKey: declinedPromptKey)
        }

        NSApp.restoreBackgroundOnlyActivationPolicyIfNeeded()
    }

    private static func reloadSystemShortcutPreferences() {
        CFPreferencesAppSynchronize(appID as CFString)
        // Run each reload tool once, off the main thread — waitUntilExit blocks.
        DispatchQueue.global(qos: .utility).async {
            runSystemTool("/usr/bin/defaults", arguments: ["read", "com.apple.symbolichotkeys.plist"])
            runSystemTool("/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings", arguments: ["-u"])
            runSystemTool("/usr/bin/killall", arguments: ["SystemUIServer"])
            runSystemTool("/usr/bin/killall", arguments: ["cfprefsd"])
        }
    }

    private static func readHotkeys(host: CFString) -> [String: Any]? {
        CFPreferencesSynchronize(appID as CFString, kCFPreferencesCurrentUser, host)
        return CFPreferencesCopyValue(
            hotkeysKey as CFString,
            appID as CFString,
            kCFPreferencesCurrentUser,
            host
        ) as? [String: Any]
    }

    @discardableResult
    private static func writeWithCFPreferences(_ hotkeys: [String: Any], host: CFString) -> Bool {
        CFPreferencesSetValue(
            hotkeysKey as CFString,
            hotkeys as CFDictionary,
            appID as CFString,
            kCFPreferencesCurrentUser,
            host
        )
        return CFPreferencesSynchronize(appID as CFString, kCFPreferencesCurrentUser, host)
    }

    private static func defaultHotkeyEntry(for id: Int) -> [String: Any] {
        [
            "enabled": false,
            "value": defaultHotkeyValue(for: id)
        ]
    }

    private static func defaultHotkeyValue(for id: Int) -> [String: Any] {
        [
            "type": "standard",
            "parameters": screenshotHotkeyParameters[id] ?? []
        ]
    }

    @discardableResult
    private static func runSystemTool(_ path: String, arguments: [String]) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    @MainActor
    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    private static func showSuccessToast() {
        ToastWindow.show(message: "Apple screenshot shortcuts disabled. Shotnix shortcuts are now active.")
    }

    @MainActor
    private static func showManualInstructionsAlert() {
        let alert = NSAlert()
        alert.messageText = "Could Not Disable Apple Shortcuts"
        alert.informativeText = "Open System Settings → Keyboard → Keyboard Shortcuts → Screenshots and turn off the screenshot shortcuts manually."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Keyboard Settings")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            openKeyboardSettings()
        }
    }
}
