import AppKit

/// One-time "Enjoying Shotnix? Star it on GitHub" nudge.
///
/// The app is the only place regular users are reached, so the ask happens
/// here rather than on the website. It is made exactly once, at whichever
/// comes first: the tenth successful screenshot (a clickable toast) or the
/// third finished video export (a line under the finished export). From
/// then on a dismissible line sits at the top of the history panel, and
/// under every finished export once there have been three, until the user
/// stars or dismisses it. No surface ever comes back after either choice.
/// Nothing leaves the Mac; the counts and state live in UserDefaults.
enum StarNudge {
    static let repositoryURL = URL(string: "https://github.com/OMARVII/Shotnix")!
    static let captureThreshold = 10
    static let exportThreshold = 3

    enum State: String {
        /// Still counting captures and exports.
        case pending
        /// The ask was made (the raw value dates from when a toast was the
        /// only way); the reminder lines are visible.
        case toastShown
        /// The user chose "Not now".
        case dismissed
        /// The user opened the repository from the nudge.
        case starred
    }

    static var state: State {
        get { State(rawValue: Settings.starNudgeState) ?? .pending }
        set { Settings.starNudgeState = newValue.rawValue }
    }

    /// Pure bookkeeping, no UI. Returns true exactly once: on the capture
    /// that crosses the threshold while the nudge is still pending.
    @discardableResult
    static func recordCapture() -> Bool {
        Settings.captureCount += 1
        guard state == .pending, Settings.captureCount >= captureThreshold else { return false }
        state = .toastShown
        return true
    }

    /// The same for a finished video export (not a failed or cancelled
    /// one): true exactly once, on the export that crosses the threshold
    /// while the nudge is still pending.
    @discardableResult
    static func recordExport() -> Bool {
        Settings.videoExportCount += 1
        guard state == .pending, Settings.videoExportCount >= exportThreshold else { return false }
        state = .toastShown
        return true
    }

    static var shouldShowInHistoryPanel: Bool { state == .toastShown }

    /// The line under a finished export: asked and not answered yet, and
    /// only for someone who has exported enough to have an opinion (the
    /// ask may have come from screenshots before their first video).
    static var shouldShowWithExports: Bool {
        state == .toastShown && Settings.videoExportCount >= exportThreshold
    }

    static func markStarred() { state = .starred }
    static func markDismissed() { state = .dismissed }
}

@MainActor
extension StarNudge {
    /// Opens a link in the browser. Tests replace it.
    static var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Exports count toward the nudge. Off under tests, whose exports
    /// would otherwise add up in the test runner's own defaults and put
    /// the line into every later render; a test turns it on for itself.
    static var countsExports = NSClassFromString("XCTestCase") == nil

    /// The line under a finished export is in front of the user.
    static var exportLineIsOnShow = false

    /// Call from every successful screenshot pipeline. On the threshold
    /// capture, shows the one-time toast on the capture's screen, a beat after
    /// the quick-access overlay lands so the two don't compete for attention.
    static func captureDidFinish(rect: CGRect) {
        guard recordCapture() else { return }
        let screen = NSScreen.screenContaining(rect: rect) ?? NSScreen.main
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            showToast(on: screen)
        }
    }

    /// Call for every finished video export. On the threshold export the
    /// ask is the line under the finished export in the export sheet. If
    /// that sheet was hidden while Shotnix is still in front, nothing
    /// shows the result, so the toast asks instead. With Shotnix in the
    /// background nothing pops up over another app: the line waits under
    /// the next finished export.
    static func exportDidFinish() {
        guard countsExports, recordExport() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard shouldToastAfterExport(lineOnShow: exportLineIsOnShow, appActive: NSApplication.shared.isActive) else { return }
            showToast(on: NSApplication.shared.keyWindow?.screen ?? NSApplication.shared.mainWindow?.screen)
        }
    }

    /// Whether the threshold export asks with the toast: still unanswered
    /// a beat later, the line isn't already asking, and Shotnix is in front.
    static func shouldToastAfterExport(lineOnShow: Bool, appActive: Bool) -> Bool {
        state == .toastShown && !lineOnShow && appActive
    }

    private static func showToast(on screen: NSScreen?) {
        ToastWindow.show(
            message: L("Enjoying Shotnix? Click to star it on GitHub ★"),
            duration: 6,
            on: screen
        ) {
            openRepository()
        }
    }

    /// Opens the repository in the browser and retires the nudge everywhere.
    static func openRepository() {
        markStarred()
        open(repositoryURL)
    }
}
