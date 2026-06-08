import AppKit

@MainActor
extension NSApplication {
    func restoreBackgroundOnlyActivationPolicyIfNeeded(excluding closingWindow: NSWindow? = nil) {
        // Never drop to background while an editor is open (even minimized) — it must keep its
        // Dock icon / ⌘-Tab entry so the user can return to it. See `ShotnixEditorActivation`.
        if VideoDemoEditorWindowController.hasOpenEditors || AnnotationWindowController.hasOpenEditors {
            return
        }

        guard !hasVisiblePersistentWindow(excluding: closingWindow) else {
            return
        }

        setActivationPolicy(.prohibited)
    }

    private func hasVisiblePersistentWindow(excluding closingWindow: NSWindow?) -> Bool {
        windows.contains { window in
            if let closingWindow, window === closingWindow {
                return false
            }

            guard window.isVisible, !window.isMiniaturized else {
                return false
            }

            if window is PinnedWindow {
                return true
            }

            let persistentMasks: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
            return !window.styleMask.intersection(persistentMasks).isEmpty
        }
    }
}

/// Coordinates the Dock-icon presence across both editors. While a photo or video editor window is
/// open, Shotnix runs as a regular app (Dock icon + ⌘-Tab) so the user can always return to it;
/// once the last editor of either kind closes, it drops back to accessory (menu-bar-only).
@MainActor
enum ShotnixEditorActivation {
    static func sync() {
        let editing = VideoDemoEditorWindowController.hasOpenEditors
            || AnnotationWindowController.hasOpenEditors
        let policy: NSApplication.ActivationPolicy = editing ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }
}
