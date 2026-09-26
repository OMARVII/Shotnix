import AppKit
import ScreenCaptureKit

/// Which windows a recording shows, beyond the display or window chosen.
@MainActor
enum RecordingCaptureFilter {

    // MARK: Display recordings: Shotnix's own windows

    /// Everything Shotnix floats over the screen — HUD, camera bubble,
    /// toasts, the menu bar timer, Command Center, overlays, update prompts —
    /// stays out of a display recording, even windows that open
    /// mid-recording. Its real windows stay in, as they do in screenshots.
    static func recordableOwnWindowIDs() -> Set<CGWindowID> {
        recordableOwnWindowIDs(in: NSApp.windows, front: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    /// Kept: Shotnix's real windows (titled, and not owned by a framework
    /// bundled in the app — the updater's prompts are titled too), anything
    /// attached to one of them whatever its owner (popovers, sheets,
    /// alerts), and, while one of them is in front, the menus opened from it.
    static func recordableOwnWindowIDs(in windows: [NSWindow], front: NSWindow?) -> Set<CGWindowID> {
        let visible = windows.filter { $0.isVisible && $0.windowNumber > 0 }
        let real = Set(visible.filter(isRealWindow).map(ObjectIdentifier.init))
        func belongsToReal(_ window: NSWindow) -> Bool {
            var current: NSWindow? = window
            for _ in 0..<12 {
                guard let candidate = current else { return false }
                if real.contains(ObjectIdentifier(candidate)) { return true }
                current = candidate.sheetParent ?? candidate.parent
            }
            return false
        }
        var kept = visible.filter(belongsToReal)
        if let front, belongsToReal(front) {
            kept += visible.filter { $0.level == .popUpMenu }
        }
        return Set(kept.map { CGWindowID($0.windowNumber) })
    }

    static func isRealWindow(_ window: NSWindow) -> Bool {
        guard window.styleMask.contains(.titled) else { return false }
        let owner: AnyObject? = window.windowController ?? (window.delegate as AnyObject?)
        if let owner, isBundledFramework(Bundle(for: type(of: owner))) { return false }
        return true
    }

    /// A framework shipped inside the app (the updater), as opposed to
    /// Shotnix's own code or the system's (AppKit alerts and open panels
    /// are part of whatever window they belong to).
    static func isBundledFramework(_ bundle: Bundle) -> Bool {
        bundle != Bundle(for: RecordingEngine.self) && !bundle.bundlePath.hasPrefix("/System/")
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

    // MARK: Window recordings: the chosen window and what belongs to it

    struct WindowSummary: Equatable {
        let id: CGWindowID
        /// CG window layer: 0 for normal windows, 101 for menus.
        let layer: Int
        let title: String?
        /// CG space.
        let frame: CGRect
    }

    /// The app's windows a window recording leaves out: its other normal
    /// windows (layer 0), which would cover the chosen one where they
    /// overlap it. Menus, popovers and sheets that open later still come
    /// through, and so does an untitled window already over the chosen one
    /// when recording starts — that's its sheet or popover.
    static func windowsToHide(recording chosen: WindowSummary, others: [WindowSummary]) -> Set<CGWindowID> {
        Set(others.compactMap { other -> CGWindowID? in
            guard other.id != chosen.id, other.layer == 0 else { return nil }
            let untitled = (other.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            if untitled, other.frame.intersects(chosen.frame) { return nil }
            return other.id
        })
    }

    /// The chosen window's app, minus its other windows present now.
    static func windowFilter(for window: SCWindow, hiding hidden: [SCWindow], on display: SCDisplay) -> SCContentFilter {
        if let app = window.owningApplication {
            return SCContentFilter(display: display, including: [app], exceptingWindows: hidden)
        }
        return SCContentFilter(display: display, including: [window])
    }

    /// The windows of `window`'s app to leave out, from `content`.
    static func windowsToHide(recording window: SCWindow, in content: SCShareableContent) -> [SCWindow] {
        guard let processID = window.owningApplication?.processID else { return [] }
        let siblings = content.windows.filter { $0.owningApplication?.processID == processID && $0.windowID != window.windowID }
        let hide = windowsToHide(recording: summary(of: window), others: siblings.map(summary(of:)))
        return siblings.filter { hide.contains($0.windowID) }
    }

    static func summary(of window: SCWindow) -> WindowSummary {
        WindowSummary(id: window.windowID, layer: window.windowLayer, title: window.title, frame: window.frame)
    }
}
