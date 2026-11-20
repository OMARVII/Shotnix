import AppKit

/// Shotnix takes the keyboard for a capture (the selection overlay, a
/// countdown) and gives it back to the app the user was in when the capture
/// is over.
///
/// It has to do that itself whenever one of its own windows is open in the
/// background: a video editor left open after a recording, Settings,
/// History. Shotnix then stays the active app when the capture's window
/// closes, and macOS makes that background window key and brings it in front
/// of the app the user was in, sometimes in time to be in the screenshot.
/// With no window of its own open, Shotnix drops out of the foreground
/// instead and macOS hands the keyboard back by itself.
@MainActor
enum CaptureFocus {
    /// The app the capture borrowed the keyboard from. Nil when the user was
    /// working in one of Shotnix's own windows, which then keeps it.
    private(set) static var lender: NSRunningApplication?

    private static var holder: KeyboardHolderWindow?
    private static var keyObserver: NSObjectProtocol?
    private static var resignObserver: NSObjectProtocol?
    private static var timeout: DispatchWorkItem?

    /// Off in the test app, where other tests' windows aren't a user's
    /// editor and focus shouldn't wander off mid-run. Its own tests turn it on.
    static var isEnabled = NSClassFromString("XCTestCase") == nil

    /// How long the keyboard is held for a capture window that never comes.
    static var patience: TimeInterval = 5
    /// How long to wait for macOS to switch apps before letting go anyway.
    static var handoverPatience: TimeInterval = 1

    /// What's true of the app right now. Tests put their own answers here.
    struct Environment {
        var isActive: @MainActor () -> Bool = { NSApp.isActive }
        var keyWindow: @MainActor () -> NSWindow? = { NSApp.keyWindow }
        var staysInFront: @MainActor () -> Bool = { NSApp.staysInFrontAfterTransientUI() }
        var frontmostApp: @MainActor () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
        /// The last app in front that wasn't Shotnix.
        var previousApp: @MainActor () -> NSRunningApplication? = { RecordingFocus.previousApp }
        var giveFocus: @MainActor (NSRunningApplication) -> Void = { $0.takeFocusFromShotnix() }
    }
    static var environment = Environment()

    /// Whether the keyboard is parked on the invisible window right now.
    static var isHolding: Bool { holder?.isVisible == true }

    // MARK: – The capture's stages

    /// A capture starts. Call before its first window shows.
    static func begin() {
        guard isEnabled else { return }
        cancelTimeout()
        stopWaitingForHandover()
        let key = environment.keyWindow()
        let workingInShotnix = environment.isActive() && key.map(isWorkWindow) == true
        if workingInShotnix {
            lender = nil
        } else if let front = environment.frontmostApp(), !front.isShotnix {
            lender = front
        } else {
            // Shotnix is in front for something that comes and goes (its
            // menu, an earlier capture): the app before that.
            lender = environment.previousApp()
        }
    }

    /// A window of the capture is about to close. Call BEFORE ordering it
    /// out: afterwards macOS has already picked the window to bring forward.
    ///
    /// - Parameter more: another capture window follows (the selection, then
    ///   a countdown). The keyboard waits on an invisible window meanwhile,
    ///   so nothing of Shotnix's comes forward in between.
    static func windowWillClose(more: Bool) {
        guard isEnabled else { return }
        guard let lender, !lender.isTerminated, environment.isActive(), environment.staysInFront() else {
            // Nothing was borrowed, or macOS gives it back by itself.
            if !more { end() }
            return
        }
        hold()
        if more {
            startTimeout(after: patience) { giveBack() }
        } else {
            giveBack()
        }
    }

    /// The capture is over and none of its windows is left (a result with
    /// nothing to show, say). Gives the keyboard back if it's still held.
    static func finish() {
        guard isEnabled else { return }
        if isHolding, lender != nil {
            giveBack()
        } else {
            end()
        }
    }

    // MARK: – Holding and giving back

    private static func hold() {
        let window = holder ?? KeyboardHolderWindow()
        holder = window
        window.park()
        guard keyObserver == nil else { return }
        // The next window of Shotnix's that takes the keyboard (a countdown,
        // the recording controls, a result) relieves the holder.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated { anotherWindowBecameKey(window) }
        }
    }

    private static func anotherWindowBecameKey(_ window: NSWindow?) {
        guard let window, window !== holder, isHolding else { return }
        // The user is in a window of Shotnix's now: it keeps the keyboard.
        if isWorkWindow(window) { lender = nil }
        cancelTimeout()
        stopWaitingForHandover()
        release()
    }

    private static func giveBack() {
        cancelTimeout()
        guard let target = lender, !target.isTerminated else { return end() }
        lender = nil
        guard environment.isActive() else { return release() }
        // The holder goes once Shotnix is no longer the active app. Closing
        // it before that would bring the background window forward after all.
        stopWaitingForHandover()
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { handoverDone() }
        }
        startTimeout(after: handoverPatience) { handoverDone() }
        environment.giveFocus(target)
    }

    private static func handoverDone() {
        cancelTimeout()
        stopWaitingForHandover()
        release()
    }

    private static func end() {
        cancelTimeout()
        stopWaitingForHandover()
        lender = nil
        release()
    }

    private static func release() {
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
            self.keyObserver = nil
        }
        holder?.orderOut(nil)
    }

    private static func stopWaitingForHandover() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    private static func startTimeout(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        cancelTimeout()
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private static func cancelTimeout() {
        timeout?.cancel()
        timeout = nil
    }

    /// A window the user works in (an editor, Settings, History), as
    /// opposed to what floats over the screen for a moment.
    static func isWorkWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled)
    }

    /// Back to a clean slate (tests).
    static func reset() {
        end()
        environment = Environment()
        patience = 5
        handoverPatience = 1
        isEnabled = NSClassFromString("XCTestCase") == nil
    }
}

/// Holds the keyboard between two capture windows, and while macOS switches
/// back to the user's app: one clear point that takes no clicks. While it's
/// the key window, closing another window of Shotnix's promotes nothing.
private final class KeyboardHolderWindow: NSWindow {
    init() {
        let origin = NSScreen.main?.frame.origin ?? .zero
        super.init(contentRect: NSRect(origin: origin, size: NSSize(width: 1, height: 1)), styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        // Above the windows it stands in for, on every Space.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func park() {
        if let origin = NSScreen.main?.frame.origin { setFrameOrigin(origin) }
        makeKeyAndOrderFront(nil)
        makeMain()
    }

    // A key pressed in the meantime goes nowhere, without the system beep.
    override func keyDown(with event: NSEvent) {}
    override func noResponder(for eventSelector: Selector) {}
}

extension NSRunningApplication {
    var isShotnix: Bool { processIdentifier == ProcessInfo.processInfo.processIdentifier }

    /// Makes this app the active one in Shotnix's place. Only works while
    /// Shotnix is the active app: macOS lets the active app pass focus on.
    @MainActor
    func takeFocusFromShotnix() {
        guard !isTerminated, !isShotnix else { return }
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: self)
            activate(from: .current, options: [])
        } else {
            activate(options: [])
        }
    }
}
