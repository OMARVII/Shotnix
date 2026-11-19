import AppKit
import QuartzCore
import ScreenCaptureKit
import XCTest
@testable import ShotnixCore

/// "Freeze the screen while selecting" against the real screen: the shot
/// shows what was there when the selection began, and is the same picture a
/// live capture of a still screen gives. Needs Screen Recording permission
/// for the test runner, skipped otherwise.
@MainActor
final class ScreenshotFreezeIntegrationTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var selection: AreaSelectionWindow?
    private var suiteName: String!

    override func setUp() async throws {
        guard CGPreflightScreenCaptureAccess(), #available(macOS 14.0, *) else { throw XCTSkip("needs Screen Recording permission") }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        guard session["CGSSessionScreenIsLocked"] as? Bool != true, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else {
            throw XCTSkip("the screen is locked or asleep")
        }
        _ = NSApplication.shared
        suiteName = "ShotnixCoreTests.ScreenshotFreeze.\(UUID().uuidString)"
        Settings.defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        if selection?.isShowingOverlays == true { selection?.cancel() }
        selection = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if let suiteName {
            Settings.defaults.removePersistentDomain(forName: suiteName)
            Settings.defaults = .standard
        }
    }

    // MARK: Support

    private func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// A window of Shotnix's own that screenshots keep (titled), floating
    /// above other apps' windows so nothing covers it.
    private func showWindow(_ color: NSColor, on screen: NSScreen) async throws -> NSWindow {
        let frame = NSRect(x: screen.frame.midX - 180, y: screen.frame.midY - 120, width: 360, height: 240)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.level = .floating
        window.backgroundColor = color
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        window.display()
        windows.append(window)
        CATransaction.flush()
        let id = try XCTUnwrap(CGWindowID(exactly: window.windowNumber))
        for _ in 0..<40 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if content.windows.contains(where: { $0.windowID == id }) { break }
            try await sleep(0.05)
        }
        try await sleep(0.2)
        return window
    }

    private func repaint(_ window: NSWindow, _ color: NSColor) async throws {
        window.backgroundColor = color
        window.display()
        CATransaction.flush()
        try await sleep(0.35)
    }

    /// How far the middle of `image` is from `color`, in the image's own
    /// color space: a capture is in the display's, where a color has other
    /// numbers than in sRGB.
    private func distance(ofCenterOf image: NSImage, from color: NSColor) throws -> Double {
        var rect = NSRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let center = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        let wanted = try XCTUnwrap(color.usingColorSpace(rep.colorSpace))
        return max(abs(center.redComponent - wanted.redComponent), abs(center.greenComponent - wanted.greenComponent), abs(center.blueComponent - wanted.blueComponent))
    }

    private func pixels(_ image: NSImage) throws -> (width: Int, height: Int, data: [UInt8]) {
        var rect = NSRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        var data = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: try XCTUnwrap(cgImage.colorSpace), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return (cgImage.width, cgImage.height, data)
    }

    /// Drags a selection over `rect` (AppKit screen space) on its display's overlay.
    private func select(_ rect: CGRect, on screen: NSScreen) async throws {
        let overlay = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.frame == screen.frame && $0.contentView?.subviews.contains { $0 is SelectionOverlayView } == true })
        let view = try XCTUnwrap(overlay.contentView?.subviews.compactMap { $0 as? SelectionOverlayView }.first)
        view.captureImmediately = true
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            let local = CGPoint(x: point.x - screen.frame.minX, y: point.y - screen.frame.minY)
            return NSEvent.mouseEvent(with: type, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: rect.minX, y: rect.minY)))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: rect.midX, y: rect.midY)))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: rect.maxX, y: rect.maxY)))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: rect.maxX, y: rect.maxY)))
        try await sleep(0.2)
    }

    // MARK: Tests

    func testAFrozenSelectionCapturesTheScreenAsItWasWhenItBegan() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let engine = CaptureEngine()
        let window = try await showWindow(.systemGreen, on: screen)

        var selected: CGRect?
        let selection = AreaSelectionWindow(mode: .area, freezesScreen: true) { rect, _ in selected = rect }
        self.selection = selection
        let frontBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let started = CFAbsoluteTimeGetCurrent()
        await selection.prepareAndShow(engine: engine)
        print("FREEZE: stills of \(NSScreen.screens.count) display(s) in \(Int((CFAbsoluteTimeGetCurrent() - started) * 1000)) ms")
        XCTAssertEqual(selection.showsFrozenScreens, NSScreen.screens.map { _ in true })

        // The stills were taken before Shotnix came forward, so the screen in
        // them is as it was. Coming forward afterwards still has to work, or
        // Esc and the arrow keys would go to the app behind. (Asked of the
        // system: a test runner has no event loop to hear it from.)
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != ownProcess { try await sleep(0.05) }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, ownProcess, "Shotnix is in front once the frozen screen shows")
        if frontBefore == ownProcess { print("FREEZE: the test runner was in front already, so coming forward wasn't put to the test") }

        // The screen moves on while the selection is made.
        try await repaint(window, .systemRed)
        let inside = window.frame.insetBy(dx: 40, dy: 50)
        try await select(inside, on: screen)
        let rect = try XCTUnwrap(selected)
        let frozen = try XCTUnwrap(selection.selectedFrozenScreen)

        let cutFromStill = await engine.image(of: rect, on: screen, frozen: frozen, purpose: "test shot")
        let shot = try XCTUnwrap(cutFromStill)
        XCTAssertLessThan(try distance(ofCenterOf: shot, from: .systemGreen), 0.12, "the window as it was when the selection began")
        XCTAssertEqual(shot.size, rect.size)

        // Without the still, the same rect is what's on screen now.
        let capturedNow = await engine.image(of: rect, on: screen, frozen: nil, purpose: "test shot")
        let now = try XCTUnwrap(capturedNow)
        XCTAssertLessThan(try distance(ofCenterOf: now, from: .systemRed), 0.12)
    }

    func testAShotCutFromTheStillIsTheSamePictureAsALiveCapture() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let engine = CaptureEngine()
        let window = try await showWindow(.systemTeal, on: screen)
        // Something with edges, so a shot that is off by a pixel shows.
        let stripes = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
        stripes.wantsLayer = true
        for index in 0..<12 {
            let stripe = CALayer()
            stripe.frame = CGRect(x: 15 + index * 28, y: 20 + index * 9, width: 13, height: 77)
            stripe.backgroundColor = (index.isMultiple(of: 2) ? NSColor.white : NSColor.black).cgColor
            stripes.layer?.addSublayer(stripe)
        }
        window.contentView = stripes
        window.display()
        CATransaction.flush()
        try await sleep(0.4)

        // The display's still, as a frozen selection takes it.
        let whole = await engine.captureRectToImage(screen.frame, on: screen, purpose: "test still")
        var wholeRect = NSRect(origin: .zero, size: screen.frame.size)
        let still = FrozenScreen(image: try XCTUnwrap(whole?.cgImage(forProposedRect: &wholeRect, context: nil, hints: nil)), screenFrame: screen.frame)

        // Odd offsets and sizes: whole points, half points on a Retina
        // display, and what a pointer really gives.
        for rect in [
            window.frame.insetBy(dx: 30, dy: 40),
            CGRect(x: window.frame.minX + 17.5, y: window.frame.minY + 33.5, width: 201.5, height: 99),
            CGRect(x: window.frame.minX + 61, y: window.frame.minY + 12, width: 77, height: 151.5),
            CGRect(x: window.frame.minX + 40.5, y: window.frame.minY + 20, width: 120.5, height: 130),
            CGRect(x: window.frame.minX + 22.27, y: window.frame.minY + 41.81, width: 187.36, height: 93.4),
        ] {
            let cutImage = await engine.image(of: rect, on: screen, frozen: still, purpose: "test shot")
            let liveImage = await engine.image(of: rect, on: screen, frozen: nil, purpose: "test shot")
            let cut = try XCTUnwrap(cutImage), live = try XCTUnwrap(liveImage)
            XCTAssertEqual(cut.size, live.size, "\(rect)")
            let a = try pixels(cut), b = try pixels(live)
            XCTAssertEqual(a.width, b.width, "\(rect)")
            XCTAssertEqual(a.height, b.height, "\(rect)")
            guard a.width == b.width, a.height == b.height else { continue }
            var differing = 0
            for offset in stride(from: 0, to: a.data.count, by: 4) where abs(Int(a.data[offset]) - Int(b.data[offset])) > 3 || abs(Int(a.data[offset + 1]) - Int(b.data[offset + 1])) > 3 || abs(Int(a.data[offset + 2]) - Int(b.data[offset + 2])) > 3 {
                differing += 1
            }
            XCTAssertEqual(differing, 0, "\(differing) of \(a.width * a.height) pixels differ for \(rect)")
        }
    }
}
