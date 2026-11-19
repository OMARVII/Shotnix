import AppKit
import XCTest
@testable import ShotnixCore

/// "Freeze the screen while selecting": the stills are taken before the
/// overlays show, the displays show them, and the shot is cut from the still
/// of the display it was selected on. The stills here are plain pictures; the
/// real ones are checked in ScreenshotFreezeIntegrationTests.
@MainActor
final class CaptureFreezeTests: XCTestCase {

    private var suiteName: String!
    private var selection: AreaSelectionWindow?
    private var engine: CaptureEngine!
    private var completions: [CGRect?] = []
    private var deadline: TimeInterval = 0

    override func setUp() async throws {
        _ = NSApplication.shared
        suiteName = "ShotnixCoreTests.CaptureFreeze.\(UUID().uuidString)"
        Settings.defaults = UserDefaults(suiteName: suiteName)!
        deadline = AreaSelectionWindow.freezeDeadline
        engine = CaptureEngine()
        completions = []
    }

    override func tearDown() async throws {
        if selection?.isShowingOverlays == true { selection?.cancel() }
        selection = nil
        engine = nil
        AreaSelectionWindow.freezeDeadline = deadline
        Settings.defaults.removePersistentDomain(forName: suiteName)
        Settings.defaults = .standard
    }

    // MARK: Support

    private func picture(_ color: NSColor) -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.usingColorSpace(.sRGB)!.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        return context.makeImage()!
    }

    /// A selection whose stills are `pictures` (by display), each ready
    /// after `delay`. `asked` counts the stills taken.
    private func makeSelection(mode: SelectionMode = .area, freezes: Bool, delay: TimeInterval, pictures: [CGImage?]? = nil, onStill: (() -> Void)? = nil) -> AreaSelectionWindow {
        let selection = AreaSelectionWindow(mode: mode, freezesScreen: freezes) { [weak self] rect, _ in
            self?.completions.append(rect)
        }
        let screens = NSScreen.screens
        let stills = pictures ?? screens.map { _ in picture(.systemGreen) }
        selection.stillProvider = { screen in
            onStill?()
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let index = screens.firstIndex(of: screen), stills.indices.contains(index), let image = stills[index] else { return nil }
            return FrozenScreen(image: image, screenFrame: screen.frame)
        }
        self.selection = selection
        return selection
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// The selection views now on screen, by display.
    private func overlayViews() -> [(view: SelectionOverlayView, screen: NSScreen)] {
        NSApp.windows.filter(\.isVisible).compactMap { window in
            guard let view = window.contentView?.subviews.compactMap({ $0 as? SelectionOverlayView }).first,
                  let screen = NSScreen.screens.first(where: { $0.frame == window.frame }) else { return nil }
            return (view, screen)
        }
    }

    /// Drags out a selection on `screen`'s overlay, as the mouse would.
    private func select(on screen: NSScreen) async throws {
        let view = try XCTUnwrap(overlayViews().first { $0.screen == screen }?.view)
        view.captureImmediately = true
        let number = try XCTUnwrap(view.window).windowNumber
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 200, y: 180)))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 300, y: 250)))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: 300, y: 250)))
        // The completion fires on the next turn of the run loop.
        try await sleep(0.2)
    }

    // MARK: Live, as before

    func testWithoutFreezingTheCrosshairIsUpAtOnceAndTheShotIsTakenLive() async throws {
        let selection = makeSelection(freezes: false, delay: 0.15)
        let started = Date()
        await selection.prepareAndShow(engine: engine)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "the overlays don't wait for the stills")
        XCTAssertTrue(selection.isShowingOverlays)
        XCTAssertEqual(selection.showsFrozenScreens, NSScreen.screens.map { _ in false })

        try await sleep(0.4)
        XCTAssertEqual(selection.showsFrozenScreens, NSScreen.screens.map { _ in false }, "the stills only feed the loupe")
        try await select(on: NSScreen.screens[0])
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first??.size, CGSize(width: 200, height: 150))
        XCTAssertNil(selection.selectedFrozenScreen, "captured live")
    }

    func testWindowModeNeverFreezes() async throws {
        var asked = 0
        let selection = makeSelection(mode: .window, freezes: true, delay: 0, onStill: { asked += 1 })
        await selection.prepareAndShow(engine: engine)
        XCTAssertTrue(selection.isShowingOverlays)
        try await sleep(0.1)
        XCTAssertEqual(asked, 0, "a window is picked on the live screen: no stills at all")
        XCTAssertEqual(selection.showsFrozenScreens, NSScreen.screens.map { _ in false })
    }

    // MARK: Frozen

    func testFrozenTheStillsAreTakenBeforeAnythingShowsAndTheDisplaysShowThem() async throws {
        let screens = NSScreen.screens
        let pictures: [CGImage?] = screens.indices.map { picture($0 == 0 ? .systemGreen : .systemBlue) }
        var overlaysUpWhenAsked: [Bool] = []
        var selection: AreaSelectionWindow!
        selection = makeSelection(freezes: true, delay: 0.1, pictures: pictures, onStill: { overlaysUpWhenAsked.append(selection.isShowingOverlays) })
        XCTAssertFalse(selection.isShowingOverlays)
        await selection.prepareAndShow(engine: engine)

        XCTAssertEqual(overlaysUpWhenAsked, screens.map { _ in false }, "every display's still, with nothing of Shotnix's on screen yet")
        XCTAssertTrue(selection.isShowingOverlays)
        XCTAssertEqual(selection.showsFrozenScreens, screens.map { _ in true })
        XCTAssertEqual(overlayViews().count, screens.count)

        let screen = try XCTUnwrap(screens.last)
        try await select(on: screen)
        XCTAssertEqual(completions.count, 1)
        let frozen = try XCTUnwrap(selection.selectedFrozenScreen)
        XCTAssertTrue(frozen.image === pictures[screens.count - 1], "the still of the display the selection was made on")
        XCTAssertEqual(frozen.screenFrame, screen.frame)
        XCTAssertFalse(selection.isShowingOverlays)
    }

    func testEscCancelsAFrozenSelection() async throws {
        let selection = makeSelection(freezes: true, delay: 0)
        await selection.prepareAndShow(engine: engine)
        let view = try XCTUnwrap(overlayViews().first?.view)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: try XCTUnwrap(view.window).windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)
        XCTAssertEqual(completions.count, 1)
        XCTAssertNil(completions.first ?? nil)
        XCTAssertFalse(selection.isShowingOverlays)
        XCTAssertNil(selection.selectedFrozenScreen)
    }

    func testAStillThatTakesTooLongDoesNotHoldTheCrosshair() async throws {
        AreaSelectionWindow.freezeDeadline = 0.15
        let selection = makeSelection(freezes: true, delay: 1.2)
        let started = Date()
        await selection.prepareAndShow(engine: engine)
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThan(waited, 0.12)
        XCTAssertLessThan(waited, 0.6, "the deadline, not the still")
        XCTAssertTrue(selection.isShowingOverlays)
        XCTAssertEqual(selection.showsFrozenScreens, NSScreen.screens.map { _ in false }, "live until its still is there")

        try await select(on: NSScreen.screens[0])
        XCTAssertEqual(completions.count, 1)
        XCTAssertNil(selection.selectedFrozenScreen, "selected on the live screen, so captured live")
        // The still arriving after the selection is over changes nothing.
        try await sleep(1.3)
        XCTAssertFalse(selection.isShowingOverlays)
        XCTAssertNil(selection.selectedFrozenScreen)
    }

    func testALateStillFreezesItsDisplayWhenItArrives() async throws {
        AreaSelectionWindow.freezeDeadline = 0.1
        let green = picture(.systemGreen)
        let selection = makeSelection(freezes: true, delay: 0.45, pictures: NSScreen.screens.map { _ in green })
        await selection.prepareAndShow(engine: engine)
        XCTAssertEqual(selection.showsFrozenScreens, NSScreen.screens.map { _ in false })
        try await sleep(0.6)
        XCTAssertEqual(selection.showsFrozenScreens, NSScreen.screens.map { _ in true })
        try await select(on: NSScreen.screens[0])
        XCTAssertTrue(try XCTUnwrap(selection.selectedFrozenScreen).image === green, "selected on the still, so cut from it")
    }

    func testAStillThatFailsLeavesItsDisplayLive() async throws {
        let selection = makeSelection(freezes: true, delay: 0.05, pictures: NSScreen.screens.map { _ in nil })
        await selection.prepareAndShow(engine: engine)
        XCTAssertTrue(selection.isShowingOverlays)
        XCTAssertEqual(selection.showsFrozenScreens, NSScreen.screens.map { _ in false })
        try await select(on: NSScreen.screens[0])
        XCTAssertEqual(completions.count, 1)
        XCTAssertNil(selection.selectedFrozenScreen)
    }

    func testCancellingWhileTheStillsAreTakenShowsNothing() async throws {
        let selection = makeSelection(freezes: true, delay: 0.4)
        let showing = Task { @MainActor in await selection.prepareAndShow(engine: engine) }
        try await sleep(0.1)
        XCTAssertFalse(selection.isShowingOverlays)
        selection.cancel()
        XCTAssertEqual(completions.count, 1)
        XCTAssertNil(completions.first ?? nil)
        await showing.value
        XCTAssertFalse(selection.isShowingOverlays, "the stills arriving afterwards bring up no overlays")
        try await sleep(0.2)
        XCTAssertTrue(overlayViews().isEmpty)
        XCTAssertEqual(completions.count, 1, "told once")
    }

    // MARK: The setting

    func testFreezingIsOffUnlessTurnedOn() {
        XCTAssertFalse(Settings.freezeScreenWhileSelecting)
        Settings.freezeScreenWhileSelecting = true
        XCTAssertTrue(Settings.freezeScreenWhileSelecting)
        XCTAssertTrue(Settings.defaults.bool(forKey: "freezeScreenWhileSelecting"), "the key the Settings window binds to")
    }
}
