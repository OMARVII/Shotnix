import AppKit
import ScreenCaptureKit

/// Which of Shotnix's own windows a recording shows. Everything the app
/// floats over the screen — HUD, camera bubble, toasts, the menu bar timer,
/// Command Center, overlays, update prompts — stays out of the video, even
/// windows that open mid-recording. The app's real windows (editors,
/// history, preferences) stay in, as they do in screenshots.
@MainActor
enum RecordingCaptureFilter {
    /// Visible titled windows that Shotnix itself owns — not a framework:
    /// Sparkle's update windows are titled too.
    static func recordableOwnWindowIDs(in windows: [NSWindow] = NSApp.windows) -> Set<CGWindowID> {
        Set(windows.compactMap { window -> CGWindowID? in
            guard window.isVisible, window.windowNumber > 0, window.styleMask.contains(.titled) else { return nil }
            let owner: AnyObject? = window.windowController ?? (window.delegate as AnyObject?)
            if let owner, !isShotnixType(owner) { return nil }
            return CGWindowID(window.windowNumber)
        })
    }

    static func isShotnixType(_ object: AnyObject) -> Bool {
        Bundle(for: type(of: object)) == Bundle(for: RecordingEngine.self)
    }

    /// A display (or area) recording: the display without Shotnix, except
    /// its real windows. Excluding the whole app keeps windows created
    /// after the filter was built out of the video too.
    static func displayFilter(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let processID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let keep = recordableOwnWindowIDs()
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == processID }
        if let app = content.applications.first(where: { $0.processID == processID }) {
            return SCContentFilter(
                display: display,
                excludingApplications: [app],
                exceptingWindows: ownWindows.filter { keep.contains($0.windowID) }
            )
        }
        return SCContentFilter(display: display, excludingWindows: ownWindows.filter { !keep.contains($0.windowID) })
    }

    /// What the display filter depends on: a change means it's rebuilt.
    static func ownWindowsSignature() -> [CGWindowID] {
        let visible = NSApp.windows.filter { $0.isVisible && $0.windowNumber > 0 }.map { CGWindowID($0.windowNumber) }
        return (visible + recordableOwnWindowIDs().map { $0 | 0x8000_0000 }).sorted()
    }
}
