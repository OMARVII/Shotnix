import AppKit

/// Detects and disables macOS native screenshot shortcuts that conflict with Shotnix.
/// The native shortcuts (⌘⇧3, ⌘⇧4, ⌘⇧5) are stored in com.apple.symbolichotkeys.
enum NativeShortcutManager {

    // Symbolic hotkey IDs for macOS screenshot shortcuts
    // 28 = ⌘⇧3 (fullscreen screenshot)
    // 30 = ⌘⇧4 (area screenshot)
    // 184 = ⌘⇧5 (screenshot/recording toolbar)
    private static let screenshotHotkeyIDs = [28, 30, 184]

    /// Returns true if any native screenshot shortcuts are still enabled.
    static var nativeShortcutsEnabled: Bool {
        guard let prefs = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let hotkeys = prefs.dictionary(forKey: "AppleSymbolicHotKeys") as? [String: Any] else {
            return true // Assume enabled if we can't read
        }

        for id in screenshotHotkeyIDs {
            guard let entry = hotkeys["\(id)"] as? [String: Any],
                  let enabled = entry["enabled"] as? Bool else {
                return true // Entry missing or unreadable — assume enabled
            }
            if enabled { return true }
        }
        return false
    }

    /// Disables native macOS screenshot shortcuts (⌘⇧3, ⌘⇧4, ⌘⇧5).
    /// Requires a logout/login or cfprefsd restart to take full effect,
    /// but most apps pick up the change immediately.
    static func disableNativeShortcuts() {
        for id in screenshotHotkeyIDs {
            let task = Process()
            task.launchPath = "/usr/bin/defaults"
            task.arguments = [
                "write", "com.apple.symbolichotkeys",
                "AppleSymbolicHotKeys", "-dict-add", "\(id)",
                "<dict><key>enabled</key><false/></dict>"
            ]
            try? task.run()
            task.waitUntilExit()
        }

        // Restart cfprefsd so changes take effect without logout
        let restart = Process()
        restart.launchPath = "/usr/bin/killall"
        restart.arguments = ["cfprefsd"]
        try? restart.run()
    }

    /// Shows a one-time dialog offering to disable conflicting native shortcuts.
    /// Only shown once (tracked via UserDefaults).
    @MainActor
    static func promptIfNeeded() {
        let key = "didPromptNativeShortcuts"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        guard nativeShortcutsEnabled else { return }

        // Delay slightly so the app is fully launched before showing alert
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showConflictAlert()
        }
    }

    @MainActor
    private static func showConflictAlert() {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Shortcut Conflict Detected"
        alert.informativeText = """
        macOS has built-in screenshot shortcuts (⌘⇧3, ⌘⇧4, ⌘⇧5) that conflict with Shotnix.

        Both tools will trigger at the same time unless the native shortcuts are disabled.

        Shotnix can disable them for you automatically. You can re-enable them anytime in System Settings → Keyboard → Shortcuts → Screenshots.
        """
        alert.alertStyle = .informational
        alert.icon = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyboard")
        alert.addButton(withTitle: "Disable Native Shortcuts")
        alert.addButton(withTitle: "Keep Both (Not Recommended)")
        alert.addButton(withTitle: "I'll Do It Myself")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            disableNativeShortcuts()
            showSuccessToast()
        }

        NSApp.setActivationPolicy(.prohibited)
    }

    @MainActor
    private static func showSuccessToast() {
        ToastWindow.show(message: "Native screenshot shortcuts disabled. Shotnix shortcuts are now active.")
    }
}
