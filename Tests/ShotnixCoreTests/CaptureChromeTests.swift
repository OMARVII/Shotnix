import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ShotnixCore

/// Shotnix's floating capture chrome: the quick-access stack, pins, ⌘W,
/// desktop covers, what captures leave out, and the OCR result panel.
@MainActor
final class CaptureChromeTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func setUp() async throws {
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    // MARK: Quick access stack

    func testStackOnASmallScreenNeverReachesUnderTheMenuBar() {
        // 1280×720 display, 25 pt menu bar.
        let visible = CGRect(x: 0, y: 0, width: 1280, height: 695)
        let card = CGSize(width: 240, height: 152)
        let capacity = QuickAccessStackLayout.capacity(visibleFrame: visible, cardHeight: card.height)
        XCTAssertEqual(capacity, 3, "only three cards fit — the fourth used to slide under the menu bar")
        for slot in 0..<QuickAccessStackLayout.maxCards {
            let origin = QuickAccessStackLayout.origin(slot: slot, visibleFrame: visible, cardSize: card, onLeft: true)
            let frame = CGRect(origin: origin, size: card)
            XCTAssertTrue(visible.contains(frame), "slot \(slot) at \(frame) leaves \(visible)")
        }
    }

    func testStackOnALargeScreenKeepsFiveCardsWithoutOverlap() {
        let visible = CGRect(x: 1440, y: 30, width: 2560, height: 1385)
        let card = CGSize(width: 240, height: 152)
        XCTAssertEqual(QuickAccessStackLayout.capacity(visibleFrame: visible, cardHeight: card.height), 5)
        let frames = (0..<5).map { CGRect(origin: QuickAccessStackLayout.origin(slot: $0, visibleFrame: visible, cardSize: card, onLeft: false), size: card) }
        for (lower, upper) in zip(frames, frames.dropFirst()) {
            XCTAssertFalse(lower.intersects(upper))
            XCTAssertEqual(upper.minY - lower.maxY, QuickAccessStackLayout.gap, accuracy: 0.01)
        }
        XCTAssertEqual(frames[0].maxX, visible.maxX - QuickAccessStackLayout.sideMargin, accuracy: 0.01)
    }

    // MARK: Close Window (⌘W)

    func testCloseWindowCommandClosesTheRightThings() {
        let pin = PinnedWindow(image: Self.sampleImage())
        guard case .custom = AppDelegate.closeAction(for: pin) else { return XCTFail("pins close themselves") }

        let titled = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        guard case .performClose = AppDelegate.closeAction(for: titled) else { return XCTFail("titled windows use performClose") }

        let overlay = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        guard case .none = AppDelegate.closeAction(for: overlay) else { return XCTFail("capture overlays refuse ⌘W") }
    }

    // MARK: Pins

    func testPinsTakeKeyboardFocusWithoutActivatingTheApp() throws {
        let pin = PinnedWindow(image: Self.sampleImage())
        windows.append(pin)
        XCTAssertTrue(pin.canBecomeKey)
        XCTAssertTrue(pin.styleMask.contains(.nonactivatingPanel), "the user's app stays frontmost")
        XCTAssertFalse(pin.hidesOnDeactivate)
        XCTAssertTrue(pin.responds(to: #selector(NSText.copy(_:))), "Edit → Copy (⌘C) reaches the pin")
    }

    func testEscClosesAFocusedPin() throws {
        let pin = PinnedWindow(image: Self.sampleImage())
        windows.append(pin)
        pin.show()
        XCTAssertTrue(pin.isVisible)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: pin.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        pin.keyDown(with: escape)
        XCTAssertFalse(pin.isVisible)
    }

    func testCommandWClosesAPin() {
        let pin = PinnedWindow(image: Self.sampleImage())
        windows.append(pin)
        pin.show()
        pin.closeFromCommand()
        XCTAssertFalse(pin.isVisible)
    }

    // MARK: Desktop covers

    func testDesktopCoverSitsJustAboveTheIconsAndIsCaptured() async throws {
        guard let screen = NSScreen.main else { throw XCTSkip("no screen") }
        let cover = await DesktopIconsCover.show(on: [screen])
        defer { cover.remove() }
        let window = try XCTUnwrap(cover.windows.first)
        XCTAssertEqual(cover.windows.count, 1)
        XCTAssertEqual(window.level.rawValue, Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        XCTAssertLessThan(window.level.rawValue, NSWindow.Level.normal.rawValue, "below every app window")
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.stationary))
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertEqual(window.frame, screen.frame)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(CaptureEngine.isCapturableOwnWindow(window), "the cover must be IN the capture — that's what hides the icons")
        XCTAssertFalse(CaptureEngine.ownChromeWindowNumbers().contains(CGWindowID(window.windowNumber)))
        XCTAssertTrue(window.contentView?.layer?.contents != nil || window.contentView?.layer?.backgroundColor != nil, "shows the desktop picture")

        cover.remove()
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(cover.windows.isEmpty)
    }

    func testDesktopCoverNeverWaitsLongOnScreenCapture() async throws {
        guard let screen = NSScreen.main else { throw XCTSkip("no screen") }
        let deadline = DesktopIconsCover.screenCaptureDeadline
        DesktopIconsCover.screenCaptureDeadline = 0
        defer { DesktopIconsCover.screenCaptureDeadline = deadline }
        let started = Date()
        let cover = await DesktopIconsCover.show(on: [screen])
        defer { cover.remove() }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "a stalled ScreenCaptureKit call can't hold up the capture")
        let window = try XCTUnwrap(cover.windows.first)
        XCTAssertTrue(window.contentView?.layer?.contents != nil || window.contentView?.layer?.backgroundColor != nil, "falls back to the desktop picture")
    }

    // MARK: What captures leave out

    func testFloatingChromeIsLeftOutButContentWindowsStay() {
        let toast = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 200, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        toast.level = .floating
        let editor = NSWindow(contentRect: NSRect(x: 300, y: 40, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        windows += [toast, editor]
        toast.orderFrontRegardless()
        editor.orderFrontRegardless()

        let chrome = CaptureEngine.ownChromeWindowNumbers()
        XCTAssertTrue(chrome.contains(CGWindowID(toast.windowNumber)))
        XCTAssertFalse(chrome.contains(CGWindowID(editor.windowNumber)), "users screenshot the editors themselves")
    }

    func testMacOS13WindowListDropsShotnixChromeAndKeepsOrder() {
        let list: [[String: Any]] = [
            [kCGWindowNumber as String: 11],
            [kCGWindowNumber as String: 22],
            [kCGWindowNumber as String: 33],
            [kCGWindowNumber as String: 44],
        ]
        XCTAssertEqual(CaptureEngine.windowIDs(in: list, excluding: [22, 44]), [11, 33])
        XCTAssertEqual(CaptureEngine.windowIDs(in: list, excluding: []), [11, 22, 33, 44])
    }

    // MARK: Scrolling capture Esc

    func testTemporaryHotKeyRegistersAndUnregisters() throws {
        // F19: nobody's Escape gets swallowed while the test runs.
        let hotKey = try XCTUnwrap(TemporaryHotKey(keyCode: UInt32(kVK_F19)) {})
        hotKey.unregister()
        let again = try XCTUnwrap(TemporaryHotKey(keyCode: UInt32(kVK_F19)) {}, "the key is free again after unregistering")
        again.unregister()
    }

    // MARK: OCR result panel

    func testRenderOCRResultWindowSnapshot() throws {
        let lines: [OCRLine] = [
            ["Item", "Qty", "Price"], ["Pens", "12", "3.50"], ["Paper", "5", "8.00"],
        ].enumerated().flatMap { row, cells in
            cells.enumerated().map { column, text in
                OCRLine(text: text, box: CGRect(x: 20 + column * 160, y: 30 + row * 40, width: text.count * 11, height: 18))
            }
        } + [
            OCRLine(text: "Order online at https://shotnix.com/store", box: CGRect(x: 20, y: 200, width: 420, height: 18)),
            OCRLine(text: "Questions: hello@shotnix.com", box: CGRect(x: 20, y: 240, width: 300, height: 18)),
        ]
        let result = OCRResult(lines: lines)
        XCTAssertEqual(OCRResultWindow.extrasSummary(for: result), "a table, 1 link, 1 email address")

        let window = OCRResultWindow(result: result)
        windows.append(window)
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-capture-snapshots/ocr-result.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT-OCR: \(url.path)")
    }

    private static func sampleImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 120, height: 80))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 120, height: 80)).fill()
        image.unlockFocus()
        return image
    }
}
