import AppKit

/// One-time "Enjoying Shotnix? Star it on GitHub" nudge.
///
/// The app is the only place regular users are reached, so the ask happens
/// here rather than on the website. It fires exactly once, after the tenth
/// successful screenshot, as a clickable toast. From then on a dismissible
/// line sits at the top of the history panel until the user stars or
/// dismisses it. Neither surface ever comes back after either choice.
/// Nothing leaves the Mac; the count and state live in UserDefaults.
enum StarNudge {
    static let repositoryURL = URL(string: "https://github.com/OMARVII/Shotnix")!
    static let captureThreshold = 10

    enum State: String {
        /// Still counting captures.
        case pending
        /// The toast fired; the history-panel line is visible.
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

    static var shouldShowInHistoryPanel: Bool { state == .toastShown }

    static func markStarred() { state = .starred }
    static func markDismissed() { state = .dismissed }
}

@MainActor
extension StarNudge {
    /// Call from every successful screenshot pipeline. On the threshold
    /// capture, shows the one-time toast on the capture's screen, a beat after
    /// the quick-access overlay lands so the two don't compete for attention.
    static func captureDidFinish(rect: CGRect) {
        guard recordCapture() else { return }
        let screen = NSScreen.screenContaining(rect: rect) ?? NSScreen.main
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            ToastWindow.show(
                message: "Enjoying Shotnix? Click to star it on GitHub ★",
                duration: 6,
                on: screen
            ) {
                openRepository()
            }
        }
    }

    /// Opens the repository in the browser and retires the nudge everywhere.
    static func openRepository() {
        markStarred()
        NSWorkspace.shared.open(repositoryURL)
    }
}
