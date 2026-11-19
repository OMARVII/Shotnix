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
        // The key window only: a menu is open from whatever has the keyboard,
        // and with Shotnix in the background its menus are chrome's.
        recordableOwnWindowIDs(in: NSApp.windows, front: NSApp.keyWindow)
    }

    /// Kept: Shotnix's real windows (titled, and not owned by a framework
    /// bundled in the app — the updater's prompts are titled too), anything
    /// attached to one of them whatever its owner (popovers, sheets,
    /// alerts), and, while one of them is key, the menus opened from it.
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
        return Set(kept.compactMap { CGWindowID(exactly: $0.windowNumber) })
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
    /// after the filter was built out of the video too. `content` lists the
    /// windows on screen; `ownApplication` is Shotnix's app entry, which
    /// such a list names only while one of its windows is on screen.
    ///
    /// `desktopCover`: the windows this recording hides the desktop icons
    /// with, which belong in the video. `menuBar`: what happens to the menu
    /// bar's windows (RecordingMenuBar).
    static func displayFilter(
        display: SCDisplay,
        content: SCShareableContent,
        ownApplication: SCRunningApplication?,
        desktopCover: [NSWindow] = [],
        menuBar: RecordingMenuBar.Filter = RecordingMenuBar.Filter()
    ) -> SCContentFilter {
        let processID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let keep = recordableOwnWindowIDs().union(desktopCover.compactMap { CGWindowID(exactly: $0.windowNumber) })
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == processID }
        let controlCenter = menuBar.leavesOutControlCenter ? controlCenter(in: content) : nil
        let controlCenterWindows = controlCenter.map { app in content.windows.filter { $0.owningApplication?.processID == app.processID } } ?? []
        let letBackIn = controlCenterWindows.filter { menuBar.letIn.contains($0.windowID) }
        // Windows of apps that are in the video. One of an app that's left
        // out would be let in by naming it, so those are never among them.
        let leftOut = content.windows.filter { window in
            guard menuBar.leftOut.contains(window.windowID) else { return false }
            let owner = window.owningApplication?.processID
            return owner != processID && (controlCenter == nil || owner != controlCenter?.processID)
        }
        if let app = ownApplication ?? content.applications.first(where: { $0.processID == processID }),
           leavesOutApplications(content: content, ownApplication: app, naming: menuBar.leftOut) {
            // A window named as an exception is shown when its app is left
            // out and left out when its app is shown. Leaving out all of
            // Control Center also leaves out what it opens later.
            return SCContentFilter(
                display: display,
                excludingApplications: [app] + (controlCenter.map { [$0] } ?? []),
                exceptingWindows: ownWindows.filter { keep.contains($0.windowID) } + letBackIn + leftOut
            )
        }
        let letBackInIDs = Set(letBackIn.map(\.windowID))
        return SCContentFilter(
            display: display,
            excludingWindows: ownWindows.filter { !keep.contains($0.windowID) }
                + controlCenterWindows.filter { !letBackInIDs.contains($0.windowID) }
                + leftOut
        )
    }

    /// Whether a display filter that names `windows` leaves apps out as
    /// apps, so that what they open later stays out too. Otherwise it can
    /// only leave out the windows the list names now. It takes Shotnix's
    /// own entry in the list, and one that can be told from the owner of
    /// the windows named.
    static func leavesOutApplications(content: SCShareableContent, ownApplication: SCRunningApplication?, naming windows: Set<CGWindowID>) -> Bool {
        let processID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let app = ownApplication ?? content.applications.first(where: { $0.processID == processID }) else { return false }
        let owners = content.windows
            .filter { windows.contains($0.windowID) && $0.owningApplication?.processID != processID }
            .map { $0.owningApplication?.bundleIdentifier ?? "" }
        return canName(ownersIdentifiers: owners, leavingOut: app.bundleIdentifier)
    }

    /// The Window Server's windows have an owner without an identifier.
    /// With an app without one among those left out (Shotnix run outside
    /// its app bundle, as tests do), ScreenCaptureKit on macOS 26 takes
    /// them for that app's: naming one as an exception then shows it.

    nonisolated static func canName(ownersIdentifiers: [String], leavingOut identifier: String) -> Bool {
        !identifier.isEmpty || !ownersIdentifiers.contains("")
    }

    /// Control Center's app entry. An on-screen list only names it while
    /// one of its windows is on screen, which is whenever the menu bar is.
    static func controlCenter(in content: SCShareableContent) -> SCRunningApplication? {
        content.applications.first { $0.bundleIdentifier == RecordingMenuBar.controlCenterBundleID }
    }

    /// Control Center's windows as `content` lists them.
    static func controlCenterWindows(in content: SCShareableContent) -> [RecordingMenuBar.Window] {
        content.windows.compactMap { window in
            guard window.owningApplication?.bundleIdentifier == RecordingMenuBar.controlCenterBundleID else { return nil }
            return RecordingMenuBar.Window(id: window.windowID, layer: window.windowLayer, name: window.title ?? "", frame: window.frame)
        }
    }

    /// The Window Server's dots as `content` lists them. The list gives
    /// them an owner without a name or an identifier.
    static func privacyDots(in content: SCShareableContent) -> Set<CGWindowID> {
        Set(content.windows.filter { window in
            window.title == RecordingMenuBar.privacyDotName && (window.owningApplication?.bundleIdentifier ?? "").isEmpty
        }.map(\.windowID))
    }

    /// What the display filter depends on: a change means it's rebuilt.
    static func ownWindowsSignature() -> [CGWindowID] {
        let visible = NSApp.windows.filter { $0.isVisible && $0.windowNumber > 0 }.compactMap { CGWindowID(exactly: $0.windowNumber) }
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

    /// Whether the recorded window's app has normal windows out of sight
    /// now (minimized, or on another Space) that `windowsToHide` would
    /// leave out: only an every-window list holds those. `windowList` is
    /// CGWindowListCopyWindowInfo(.optionAll), quick however many windows
    /// the Mac holds. Untitled, tiny windows are an app's own machinery,
    /// never shown.
    static func hasHiddenSiblings(of windowID: CGWindowID, in windowList: [[String: Any]]) -> Bool {
        func number(_ info: [String: Any], _ key: CFString) -> Int? { (info[key as String] as? NSNumber)?.intValue }
        guard let owner = windowList.first(where: { number($0, kCGWindowNumber) == Int(windowID) }).flatMap({ number($0, kCGWindowOwnerPID) }) else {
            return false
        }
        return windowList.contains { info in
            guard number(info, kCGWindowOwnerPID) == owner,
                  number(info, kCGWindowNumber) != Int(windowID),
                  number(info, kCGWindowLayer) == 0,
                  (info[kCGWindowIsOnscreen as String] as? Bool) != true else { return false }
            let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            let titled = !((info[kCGWindowName as String] as? String) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            return titled && bounds.width >= 80 && bounds.height >= 60
        }
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
