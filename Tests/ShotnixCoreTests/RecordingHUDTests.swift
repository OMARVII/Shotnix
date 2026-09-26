import AppKit
import XCTest
@testable import ShotnixCore

/// The recording HUD: never takes focus, sits where it was left (outside
/// the recorded area when there's room), and its buttons work.
@MainActor
final class RecordingHUDTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suiteName = "ShotnixCoreTests.RecordingHUD.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Settings.defaults = defaults
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        Settings.defaults = .standard
        super.tearDown()
    }

    private func makeHUD() -> RecordingHUDWindow {
        let hud = RecordingHUDWindow()
        hud.elapsedProvider = { 83 }
        hud.configure(systemAudio: true, microphone: true, camera: true, keystrokes: true, fps: 60, quality: "High")
        hud.setFrameOrigin(RecordingUITestSupport.offscreen)
        hud.orderFrontRegardless()
        return hud
    }

    /// Clicking or dragging the HUD must not activate Shotnix: the app
    /// being recorded would turn inactive in the video.
    func testHUDNeverTakesFocus() {
        let hud = RecordingHUDWindow()
        XCTAssertTrue((hud as NSWindow) is NSPanel)
        XCTAssertTrue(hud.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(hud.canBecomeKey)
        XCTAssertFalse(hud.canBecomeMain)
        XCTAssertFalse(hud.hidesOnDeactivate)
        XCTAssertTrue(hud.isMovableByWindowBackground)
    }

    func testPlacementRemembersTheSpotAndAvoidsTheRecordedArea() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let size = RecordingHUDWindow.size

        let standard = RecordingHUDWindow.origin(size: size, visibleFrame: visible, savedOffset: nil, avoiding: nil)
        XCTAssertEqual(standard.x, visible.midX - size.width / 2, accuracy: 0.5, "top center")
        XCTAssertEqual(standard.y, visible.maxY - 18 - size.height, accuracy: 0.5)

        let remembered = RecordingHUDWindow.origin(size: size, visibleFrame: visible, savedOffset: CGPoint(x: -400, y: 300), avoiding: nil)
        XCTAssertEqual(remembered.x, visible.midX - 400 - size.width / 2, accuracy: 0.5)
        XCTAssertEqual(remembered.y, visible.maxY - 300 - size.height, accuracy: 0.5)

        // A spot saved on a bigger screen still lands on this one.
        let clamped = RecordingHUDWindow.origin(size: size, visibleFrame: visible, savedOffset: CGPoint(x: 3000, y: -500), avoiding: nil)
        XCTAssertTrue(visible.insetBy(dx: 7, dy: 7).contains(CGRect(origin: clamped, size: size)))

        // An area at the top of the screen: the HUD moves below it.
        let topArea = CGRect(x: 300, y: 480, width: 900, height: 460)
        let belowTop = RecordingHUDWindow.origin(size: size, visibleFrame: visible, savedOffset: nil, avoiding: topArea)
        XCTAssertFalse(CGRect(origin: belowTop, size: size).intersects(topArea))
        XCTAssertEqual(belowTop.y, topArea.minY - 12 - size.height, accuracy: 0.5)

        // An area low on the screen doesn't move it at all.
        let lowArea = CGRect(x: 300, y: 60, width: 900, height: 400)
        XCTAssertEqual(RecordingHUDWindow.origin(size: size, visibleFrame: visible, savedOffset: nil, avoiding: lowArea), standard)

        // An area around the HUD with room above: the HUD goes above.
        let middleArea = CGRect(x: 300, y: 300, width: 900, height: 560)
        let aboveMiddle = RecordingHUDWindow.origin(size: size, visibleFrame: visible, savedOffset: CGPoint(x: 0, y: 200), avoiding: middleArea)
        XCTAssertEqual(aboveMiddle.y, middleArea.maxY + 12, accuracy: 0.5)

        // Recording the whole screen leaves no room: it stays put.
        XCTAssertEqual(RecordingHUDWindow.origin(size: size, visibleFrame: visible, savedOffset: nil, avoiding: visible), standard)
    }

    func testDraggedPositionIsSaved() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let hud = makeHUD()
        defer { hud.closeHUD() }
        hud.show(on: screen)
        XCTAssertNil(Settings.recordingHUDOffset, "placing it isn't a drag")
        let visible = screen.visibleFrame
        hud.setFrameOrigin(NSPoint(x: visible.minX + 40, y: visible.minY + 60))
        RecordingUITestSupport.spinRunLoop(0.1)
        let offset = try XCTUnwrap(Settings.recordingHUDOffset)
        XCTAssertEqual(offset.x, hud.frame.midX - visible.midX, accuracy: 0.5)
        XCTAssertEqual(offset.y, visible.maxY - hud.frame.maxY, accuracy: 0.5)
        // The next recording opens it there.
        let next = RecordingHUDWindow.origin(size: RecordingHUDWindow.size, visibleFrame: visible, savedOffset: offset, avoiding: nil)
        XCTAssertEqual(next.x, hud.frame.minX, accuracy: 1)
        XCTAssertEqual(next.y, hud.frame.minY, accuracy: 1)
    }

    func testButtonsRespondToRealClicks() throws {
        let hud = makeHUD()
        defer { hud.closeHUD() }
        var events: [String] = []
        hud.stopHandler = { events.append("stop") }
        hud.pauseHandler = { events.append("pause") }
        hud.discardHandler = { events.append("discard") }

        RecordingUITestSupport.click(try XCTUnwrap(RecordingUITestSupport.button(labelled: "Pause recording", in: hud)), in: hud)
        XCTAssertEqual(events, ["pause"])
        hud.setPaused(true)
        XCTAssertEqual(hud.state, .paused)
        XCTAssertNotNil(RecordingUITestSupport.button(labelled: "Resume recording", in: hud))

        // Discard asks first; Keep goes back to where it was.
        RecordingUITestSupport.click(try XCTUnwrap(RecordingUITestSupport.button(labelled: "Discard recording", in: hud)), in: hud)
        XCTAssertEqual(hud.state, .confirmingDiscard)
        XCTAssertEqual(events, ["pause"], "nothing is deleted without confirming")
        RecordingUITestSupport.click(try XCTUnwrap(RecordingUITestSupport.button(labelled: "Keep", in: hud)), in: hud)
        XCTAssertEqual(hud.state, .paused)

        RecordingUITestSupport.click(try XCTUnwrap(RecordingUITestSupport.button(labelled: "Discard recording", in: hud)), in: hud)
        RecordingUITestSupport.click(try XCTUnwrap(RecordingUITestSupport.button(labelled: "Discard", in: hud)), in: hud)
        XCTAssertEqual(events, ["pause", "discard"])

        let stopHUD = makeHUD()
        defer { stopHUD.closeHUD() }
        stopHUD.stopHandler = { events.append("stop") }
        let stop = try XCTUnwrap(RecordingUITestSupport.button(labelled: "Stop recording", in: stopHUD))
        XCTAssertTrue(stop.toolTip?.contains(RecordingStopHotkey.displayText) == true, "the tooltip names the stop shortcut")
        RecordingUITestSupport.click(stop, in: stopHUD)
        XCTAssertEqual(events.last, "stop")
    }

    /// The outline around an area recording: click-through, never focused,
    /// and drawn entirely outside the recorded pixels.
    func testAreaOutlineStaysOutsideTheRecordedArea() throws {
        let area = CGRect(x: RecordingUITestSupport.offscreen.x, y: RecordingUITestSupport.offscreen.y, width: 360, height: 200)
        let outline = RecordingAreaOutlineWindow(around: area)
        defer { outline.close() }
        XCTAssertTrue(outline.ignoresMouseEvents)
        XCTAssertFalse(outline.canBecomeKey)
        XCTAssertTrue(outline.styleMask.contains(.nonactivatingPanel))
        let inset = RecordingAreaOutlineWindow.gap + RecordingAreaOutlineWindow.lineWidth
        XCTAssertEqual(outline.frame, area.insetBy(dx: -inset, dy: -inset))
        outline.show()
        try RecordingUITestSupport.writeSnapshot(of: outline, name: "area-outline")
        outline.setPaused(true)
        try RecordingUITestSupport.writeSnapshot(of: outline, name: "area-outline-paused")
    }

    func testSavingStateHidesTheControls() throws {
        let hud = makeHUD()
        defer { hud.closeHUD() }
        hud.showSaving()
        XCTAssertEqual(hud.state, .saving)
        XCTAssertNil(RecordingUITestSupport.button(labelled: "Stop recording", in: hud))
        XCTAssertNil(RecordingUITestSupport.button(labelled: "Pause recording", in: hud))
        hud.setPaused(true)
        XCTAssertEqual(hud.state, .saving, "pausing after Stop does nothing")
    }

    func testRendersEachState() throws {
        var snapshots: [URL] = []

        let recording = makeHUD()
        snapshots.append(try RecordingUITestSupport.writeSnapshot(of: recording, name: "hud-recording"))
        recording.closeHUD()

        let paused = makeHUD()
        paused.setPaused(true)
        snapshots.append(try RecordingUITestSupport.writeSnapshot(of: paused, name: "hud-paused"))
        paused.closeHUD()

        let warning = makeHUD()
        warning.showWarning("Mic disconnected")
        warning.setMicrophoneSilent(true)
        snapshots.append(try RecordingUITestSupport.writeSnapshot(of: warning, name: "hud-warning"))
        warning.closeHUD()

        let confirming = makeHUD()
        RecordingUITestSupport.click(try XCTUnwrap(RecordingUITestSupport.button(labelled: "Discard recording", in: confirming)), in: confirming)
        snapshots.append(try RecordingUITestSupport.writeSnapshot(of: confirming, name: "hud-discard"))
        confirming.closeHUD()

        let saving = makeHUD()
        saving.showSaving()
        snapshots.append(try RecordingUITestSupport.writeSnapshot(of: saving, name: "hud-saving"))
        saving.closeHUD()

        let plain = RecordingHUDWindow()
        plain.configure(systemAudio: false, microphone: false, camera: false, keystrokes: false, fps: 30, quality: "Balanced")
        plain.elapsedProvider = { 5 }
        plain.setFrameOrigin(RecordingUITestSupport.offscreen)
        plain.orderFrontRegardless()
        snapshots.append(try RecordingUITestSupport.writeSnapshot(of: plain, name: "hud-plain"))
        plain.closeHUD()

        XCTAssertEqual(snapshots.count, 6)
    }
}
