import AppKit

/// The app the user was in before Shotnix's recording controls took focus.
/// Pressing Record hands focus straight back, so the recording doesn't
/// open on an inactive app (grey title bar, no caret) — and with an editor
/// open, Shotnix doesn't stay in front of what's being recorded.
@MainActor
enum RecordingFocus {
    private static var lastExternalApp: NSRunningApplication?
    private static var observer: NSObjectProtocol?

    static func startTracking() {
        guard observer == nil else { return }
        remember(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { remember(app) }
        }
    }

    static var previousApp: NSRunningApplication? {
        guard let app = lastExternalApp, !app.isTerminated else { return nil }
        return app
    }

    /// Call while Shotnix is the active app — right at the user's click:
    /// macOS only lets the active app pass focus on.
    static func returnFocus(to app: NSRunningApplication? = nil) {
        guard let target = app ?? previousApp, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: target)
            target.activate(from: .current, options: [])
        } else {
            target.activate(options: [])
        }
    }

    private static func remember(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApp = app
    }
}
