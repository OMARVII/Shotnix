import AppKit
import ScreenCaptureKit

/// The app the user was in before Shotnix's recording controls took focus.
/// Pressing Record hands focus straight back, so the recording doesn't
/// open on an inactive app (grey title bar, no caret) — and with an editor
/// open, Shotnix doesn't stay in front of what's being recorded.
@MainActor
enum RecordingFocus {
    private static var lastExternalApp: NSRunningApplication?
    private static var returnTarget: NSRunningApplication?
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

    /// Recording setup begins (before any Shotnix UI shows): focus will go
    /// back to the app the user was in — unless they were working in one of
    /// Shotnix's own windows (recording the editor itself, say).
    static func noteSetupStarted() {
        let workingInShotnix = NSApp.isActive && NSApp.keyWindow?.styleMask.contains(.titled) == true
        returnTarget = workingInShotnix ? nil : previousApp
    }

    /// Call while Shotnix is the active app — right at the user's click:
    /// macOS only lets the active app pass focus on. `app` wins (a window
    /// recording's own app); otherwise the target noted at setup.
    static func returnFocus(to app: NSRunningApplication? = nil) {
        guard let target = app ?? returnTarget, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: target)
            target.activate(from: .current, options: [])
        } else {
            target.activate(options: [])
        }
    }

    /// Brings the window being recorded in front of its app's other windows
    /// (with Accessibility access; without it the app just comes forward).
    /// Other windows of the app are left out of the video anyway, but one
    /// that stays in front would still hide the chosen one on screen.
    static func raise(_ window: SCWindow) {
        guard AXIsProcessTrusted(), let processID = window.owningApplication?.processID else { return }
        let app = AXUIElementCreateApplication(processID)
        // Runs as Record is pressed: a hung app mustn't hold the start up.
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let candidates = value as? [AXUIElement] else { return }
        // AX positions are in the same top-left global space as SCWindow frames.
        let target = window.frame
        let match = candidates.first { element in
            guard let frame = frame(of: element) else { return false }
            return abs(frame.minX - target.minX) < 2 && abs(frame.minY - target.minY) < 2
                && abs(frame.width - target.width) < 2 && abs(frame.height - target.height) < 2
        }
        if let match {
            AXUIElementPerformAction(match, kAXRaiseAction as CFString)
        }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        // Forced casts are safe: both type IDs were checked just above.
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func remember(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApp = app
    }
}
