import AppKit
import ScreenCaptureKit

enum PermissionsManager {

    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            Settings.didConfirmScreenRecordingPermission = true
            return true
        }

        Settings.didRequestScreenRecordingPermission = true
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            Settings.didConfirmScreenRecordingPermission = true
        }
        return granted
    }

    static var hasScreenRecordingPermission: Bool {
        let granted = CGPreflightScreenCaptureAccess()
        if granted {
            Settings.didConfirmScreenRecordingPermission = true
        }
        return granted
    }

    @MainActor
    static func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Show an alert directing the user to System Settings if permission was denied.
    @MainActor
    static func showPermissionDeniedAlert() {
        if requestScreenRecordingPermission() { return }

        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        if Settings.didRequestScreenRecordingPermission || Settings.didConfirmScreenRecordingPermission {
            alert.informativeText = "If you already enabled Shotnix in System Settings, quit and reopen Shotnix so macOS applies the Screen & System Audio Recording permission."
            alert.addButton(withTitle: "Quit Shotnix")
        } else {
            alert.informativeText = "Shotnix needs Screen Recording permission to capture your screen.\n\nPlease enable it in System Settings → Privacy & Security → Screen & System Audio Recording."
            alert.addButton(withTitle: "Open System Settings")
        }
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if Settings.didRequestScreenRecordingPermission || Settings.didConfirmScreenRecordingPermission {
                NSApp.terminate(nil)
            } else {
                openScreenRecordingSettings()
            }
        }
    }
}
