import AppKit
import ScreenCaptureKit

enum PermissionsManager {

    static func requestScreenRecordingPermission() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    static var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Show an alert directing the user to System Settings if permission was denied.
    @MainActor
    static func showPermissionDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "Shotnix needs Screen Recording permission to capture your screen.\n\nPlease enable it in System Settings → Privacy & Security → Screen Recording."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
}
