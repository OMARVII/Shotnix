import AppKit
import XCTest
@testable import ShotnixCore

/// A capture borrows the keyboard and gives it back to the app the user was
/// in. Without that, a window of Shotnix's own that's open in the background
/// (a video editor left open after a recording) comes to the front when the
/// capture's last window closes.
@MainActor
final class CaptureFocusTests: XCTestCase {

    /// What the app is told about itself, and what it was asked to do.
    private var active = false
    private var keyWindow: NSWindow?
    private var hasWindowOpen = true
    private var front: NSRunningApplication?
    private var previous: NSRunningApplication?
    private var givenTo: [pid_t] = []

    /// Any other app that's running stands in for "the app the user was in".
    private var otherApp: NSRunningApplication!
    private var windows: [NSWindow] = []
    private var suiteName: String!

    override func setUp() async throws {
        _ = NSApplication.shared
        suiteName = "ShotnixCoreTests.CaptureFocus.\(UUID().uuidString)"
        Settings.defaults = UserDefaults(suiteName: suiteName)!
        otherApp = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { !$0.isShotnix && !$0.isTerminated })
        active = false
        keyWindow = nil
        hasWindowOpen = true
        front = otherApp
        previous = nil
        givenTo = []
        CaptureFocus.reset()
        CaptureFocus.isEnabled = true
        CaptureFocus.environment = CaptureFocus.Environment(
            isActive: { [unowned self] in self.active },
            keyWindow: { [unowned self] in self.keyWindow },
            staysInFront: { [unowned self] in self.hasWindowOpen },
            frontmostApp: { [unowned self] in self.front },
            previousApp: { [unowned self] in self.previous },
            giveFocus: { [unowned self] app in self.givenTo.append(app.processIdentifier) }
        )
    }

    override func tearDown() async throws {
        CaptureFocus.reset()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        Settings.defaults.removePersistentDomain(forName: suiteName)
        Settings.defaults = .standard
    }

    // MARK: Support

    private func window(titled: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: titled ? [.titled, .closable] : [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    /// The user is in another app and a capture starts: Shotnix is in front
    /// from then on, its overlay holding the keyboard.
    private func beginFromAnotherApp() {
        active = false
        front = otherApp
        CaptureFocus.begin()
        active = true
        keyWindow = window(titled: false)
    }

    /// macOS has switched to the other app.
    private func otherAppTookOver() {
        active = false
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    }

    private func becomesKey(_ window: NSWindow) {
        keyWindow = window
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }

    private func wait(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: A screenshot

    func testAScreenshotGivesTheKeyboardBackToTheAppItCameFrom() {
        beginFromAnotherApp()
        XCTAssertEqual(CaptureFocus.lender?.processIdentifier, otherApp.processIdentifier)

        CaptureFocus.windowWillClose(more: false)
        XCTAssertEqual(givenTo, [otherApp.processIdentifier], "the app the user was in is made active again")
        XCTAssertTrue(CaptureFocus.isHolding, "the keyboard stays parked until macOS has switched: closing earlier brings the editor forward")

        otherAppTookOver()
        XCTAssertFalse(CaptureFocus.isHolding)
        XCTAssertNil(CaptureFocus.lender)
    }

    /// The usual case: nothing of Shotnix's is open, it leaves the
    /// foreground and macOS hands the keyboard back by itself.
    func testWithNoWindowOfItsOwnOpenNothingIsDone() {
        hasWindowOpen = false
        beginFromAnotherApp()
        CaptureFocus.windowWillClose(more: false)
        XCTAssertTrue(givenTo.isEmpty)
        XCTAssertFalse(CaptureFocus.isHolding)
    }

    /// A screenshot taken while working in the editor leaves the user there.
    func testAScreenshotTakenFromTheEditorStaysInTheEditor() {
        active = true
        keyWindow = window(titled: true)
        front = NSRunningApplication.current
        CaptureFocus.begin()
        XCTAssertNil(CaptureFocus.lender)

        keyWindow = window(titled: false)
        CaptureFocus.windowWillClose(more: false)
        XCTAssertTrue(givenTo.isEmpty)
        XCTAssertFalse(CaptureFocus.isHolding)
    }

    /// Started from Shotnix's menu, the capture gives the keyboard to the
    /// app the user was in before the menu.
    func testACaptureStartedFromTheMenuGoesBackToTheAppBeforeIt() {
        previous = otherApp
        active = true
        keyWindow = window(titled: false)
        front = NSRunningApplication.current
        CaptureFocus.begin()
        XCTAssertEqual(CaptureFocus.lender?.processIdentifier, otherApp.processIdentifier)

        CaptureFocus.windowWillClose(more: false)
        XCTAssertEqual(givenTo, [otherApp.processIdentifier])
        otherAppTookOver()
    }

    func testTheUserHavingMovedOnThereIsNothingToGiveBack() {
        beginFromAnotherApp()
        active = false
        CaptureFocus.windowWillClose(more: false)
        XCTAssertTrue(givenTo.isEmpty)
        XCTAssertFalse(CaptureFocus.isHolding)
    }

    func testIfMacOSNeverSwitchesTheHolderLetsGoAnyway() async throws {
        CaptureFocus.handoverPatience = 0.15
        beginFromAnotherApp()
        CaptureFocus.windowWillClose(more: false)
        XCTAssertTrue(CaptureFocus.isHolding)
        try await wait(0.4)
        XCTAssertFalse(CaptureFocus.isHolding)
    }

    // MARK: A capture in two steps

    /// The selection, then a countdown: the keyboard waits in between and
    /// goes back when the countdown closes.
    func testTheKeyboardWaitsBetweenTwoCaptureWindows() {
        beginFromAnotherApp()
        CaptureFocus.windowWillClose(more: true)
        XCTAssertTrue(CaptureFocus.isHolding, "held so no window of Shotnix's is promoted in the gap")
        XCTAssertTrue(givenTo.isEmpty)

        becomesKey(window(titled: false))
        XCTAssertFalse(CaptureFocus.isHolding, "the countdown has the keyboard now")
        XCTAssertNotNil(CaptureFocus.lender, "and still owes it to the app the user was in")

        CaptureFocus.windowWillClose(more: false)
        XCTAssertEqual(givenTo, [otherApp.processIdentifier])
        otherAppTookOver()
        XCTAssertFalse(CaptureFocus.isHolding)
    }

    /// A result window is the user's to work in: it keeps the keyboard.
    func testAResultWindowThatOpensKeepsTheKeyboard() {
        beginFromAnotherApp()
        CaptureFocus.windowWillClose(more: true)
        becomesKey(window(titled: true))
        XCTAssertFalse(CaptureFocus.isHolding)
        XCTAssertNil(CaptureFocus.lender)
        XCTAssertTrue(givenTo.isEmpty)
    }

    func testAHeldKeyboardGoesBackWhenNoWindowComes() async throws {
        CaptureFocus.patience = 0.15
        beginFromAnotherApp()
        CaptureFocus.windowWillClose(more: true)
        XCTAssertTrue(givenTo.isEmpty)
        try await wait(0.4)
        XCTAssertEqual(givenTo, [otherApp.processIdentifier], "nothing took the keyboard: the user gets it back")
    }

    /// A scan that found nothing shows no result window.
    func testFinishingWithNothingToShowGivesTheKeyboardBack() {
        beginFromAnotherApp()
        CaptureFocus.windowWillClose(more: true)
        CaptureFocus.finish()
        XCTAssertEqual(givenTo, [otherApp.processIdentifier])
        otherAppTookOver()
        XCTAssertFalse(CaptureFocus.isHolding)
    }

    func testFinishingTwiceGivesItBackOnce() {
        beginFromAnotherApp()
        CaptureFocus.windowWillClose(more: false)
        CaptureFocus.finish()
        CaptureFocus.windowWillClose(more: false)
        XCTAssertEqual(givenTo.count, 1)
    }

    func testANewCaptureStartsFromACleanSlate() {
        CaptureFocus.patience = 0.15
        beginFromAnotherApp()
        CaptureFocus.windowWillClose(more: true)
        // The next capture starts before the first one's window came.
        active = false
        CaptureFocus.begin()
        active = true
        becomesKey(window(titled: false))
        XCTAssertFalse(CaptureFocus.isHolding)
        XCTAssertTrue(givenTo.isEmpty)
    }

    // MARK: The selection overlay and the countdown

    private func makeSelection(leadsToAnotherWindow: Bool, completion: @escaping (CGRect?) -> Void = { _ in }) -> AreaSelectionWindow {
        let selection = AreaSelectionWindow(mode: .area, leadsToAnotherWindow: leadsToAnotherWindow) { rect, _ in completion(rect) }
        selection.stillProvider = { _ in nil }
        return selection
    }

    func testCancellingASelectionGivesTheKeyboardBack() async throws {
        let engine = CaptureEngine()
        let selection = makeSelection(leadsToAnotherWindow: false)
        active = false
        await selection.prepareAndShow(engine: engine)
        XCTAssertEqual(CaptureFocus.lender?.processIdentifier, otherApp.processIdentifier, "noted before the overlays showed")
        active = true
        selection.cancel()
        XCTAssertEqual(givenTo, [otherApp.processIdentifier])
        otherAppTookOver()
    }

    /// Esc gives the keyboard back even where a finished selection would
    /// have led to a countdown.
    func testCancellingASelectionThatWouldLeadOnGivesTheKeyboardBackToo() async throws {
        let engine = CaptureEngine()
        let selection = makeSelection(leadsToAnotherWindow: true)
        active = false
        await selection.prepareAndShow(engine: engine)
        active = true
        selection.cancel()
        XCTAssertEqual(givenTo, [otherApp.processIdentifier])
        XCTAssertNil(CaptureFocus.lender)
        otherAppTookOver()
    }

    func testTheKeyboardIsParkedBeforeTheOverlaysClose() async throws {
        let engine = CaptureEngine()
        let selection = makeSelection(leadsToAnotherWindow: false)
        active = false
        await selection.prepareAndShow(engine: engine)
        active = true
        var overlaysUpWhenAsked: Bool?
        CaptureFocus.environment.giveFocus = { _ in overlaysUpWhenAsked = selection.isShowingOverlays }
        selection.cancel()
        XCTAssertEqual(overlaysUpWhenAsked, true, "asked while the overlays were still up")
        otherAppTookOver()
    }

    func testATimedShotsCountdownGivesTheKeyboardBackAndARecordingsDoesNot() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        for givesFocusBack in [true, false] {
            givenTo = []
            beginFromAnotherApp()
            let countdown = CountdownWindow(seconds: 3, on: screen, givesFocusBack: givesFocusBack) { _ in }
            countdown.isReleasedWhenClosed = false
            countdown.cancel()
            XCTAssertEqual(givenTo.count, givesFocusBack ? 1 : 0, "givesFocusBack \(givesFocusBack)")
            otherAppTookOver()
            CaptureFocus.finish()
        }
    }
}
