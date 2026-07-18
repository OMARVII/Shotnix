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

    /// Quits Shotnix and relaunches it via a detached shell so the stale
    /// CGPreflight permission cache refreshes without a manual restart.
    @MainActor
    static func quitAndReopen() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The bundle path is passed as $0 so no shell escaping is needed.
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// Show an alert directing the user to System Settings if permission was denied.
    @MainActor
    static func showPermissionDeniedAlert() {
        if requestScreenRecordingPermission() { return }

        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        if Settings.didRequestScreenRecordingPermission || Settings.didConfirmScreenRecordingPermission {
            alert.informativeText = "Enable Shotnix in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Shotnix so macOS applies the permission."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Quit & Reopen")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                openScreenRecordingSettings()
            case .alertSecondButtonReturn:
                quitAndReopen()
            default:
                break
            }
        } else {
            alert.informativeText = "Shotnix needs Screen Recording permission to capture your screen.\n\nPlease enable it in System Settings → Privacy & Security → Screen & System Audio Recording."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                openScreenRecordingSettings()
            }
        }
    }
}
