import AppKit
import QuartzCore
import ScreenCaptureKit
import XCTest
@testable import ShotnixCore

/// The window list screenshots and recordings ask ScreenCaptureKit for:
/// the on-screen one, asked once and shared, kept until the displays change.
/// Asking for every window took ~3.5–5 s on a Mac holding ~9,700 hidden
/// windows, and the first shot after a display change waited for several.
@MainActor
final class ScreenshotWindowListTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func setUp() async throws {
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    /// A request that takes a moment and counts how often it ran.
    private final class Counter {
        var runs = 0
        var fails = false
    }

    private func slowFetch(_ counter: Counter) -> SharedFetch<Int> {
        SharedFetch {
            counter.runs += 1
            let run = counter.runs
            try await Task.sleep(nanoseconds: 80_000_000)
            if counter.fails { throw CancellationError() }
            return run
        }
    }

    // MARK: One request, shared and kept

    func testEveryoneWaitingTogetherSharesOneRequest() async throws {
        let counter = Counter()
        let fetch = slowFetch(counter)
        // Both displays' loupe snapshots and the shot, at once.
        async let first = fetch.value()
        async let second = fetch.value()
        async let third = fetch.value()
        let results = try await [first, second, third]
        XCTAssertEqual(counter.runs, 1, "one request for all three")
        XCTAssertEqual(Set(results.map(\.value)), [1])
        XCTAssertEqual(results.filter { $0.source == .fetched }.count, 1)
        XCTAssertEqual(results.filter { $0.source == .joined }.count, 2)

        let again = try await fetch.value()
        XCTAssertEqual(again.source, .cache, "kept: the next shot asks nothing")
        XCTAssertEqual(counter.runs, 1)
    }

    func testFreshAsksAgainAndThoseAfterItWaitOnIt() async throws {
        let counter = Counter()
        let fetch = slowFetch(counter)
        _ = try await fetch.value()
        // A content window just opened: the kept list may not have it.
        let fresh = Task { try await fetch.value(fresh: true) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let kept = try await fetch.value()
        XCTAssertEqual(kept.source, .cache, "a caller that needs nothing new keeps using the kept list")
        let freshResult = try await fresh.value
        XCTAssertEqual(freshResult.source, .fetched)
        XCTAssertEqual(freshResult.value, 2)
        let keptFresh = try await fetch.value()
        XCTAssertEqual(keptFresh.value, 2, "the fresh list is kept")

        fetch.invalidate()
        let starter = Task { try await fetch.value(fresh: true) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let joiner = try await fetch.value()
        XCTAssertEqual(joiner.source, .joined, "with nothing kept, later callers wait on the fresh request")
        let started = try await starter.value
        XCTAssertEqual(started.value, 3)
        XCTAssertEqual(counter.runs, 3)
    }

    func testADisplayChangeDuringARequestDoesntKeepItsAnswer() async throws {
        let counter = Counter()
        let fetch = slowFetch(counter)
        let early = Task { try await fetch.value() }
        try await Task.sleep(nanoseconds: 20_000_000)
        // A display plugged in while the list was being made.
        fetch.invalidate()
        let afterChange = try await fetch.value()
        XCTAssertEqual(afterChange.source, .fetched, "a new request, not the one begun before the change")
        XCTAssertEqual(afterChange.value, 2)
        let earlyResult = try await early.value
        XCTAssertEqual(earlyResult.value, 1, "whoever waited on the old one still gets an answer")
        let kept = try await fetch.value()
        XCTAssertEqual(kept.value, 2, "the old answer never replaces the new one")
    }

    func testAFailedRequestIsntKeptAndTheNextOneTriesAgain() async throws {
        let counter = Counter()
        counter.fails = true
        let fetch = slowFetch(counter)
        do {
            _ = try await fetch.value()
            XCTFail("the request failed")
        } catch {}
        XCTAssertNil(fetch.cached)
        counter.fails = false
        let retry = try await fetch.value()
        XCTAssertEqual(retry.source, .fetched)
        XCTAssertEqual(counter.runs, 2)
    }

    // MARK: Window recordings: when the hidden windows matter

    private func info(_ id: Int, pid: Int, layer: Int = 0, onScreen: Bool, title: String? = nil, size: CGSize = CGSize(width: 800, height: 600)) -> [String: Any] {
        var info: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowIsOnscreen as String: onScreen,
            kCGWindowBounds as String: CGRect(origin: .zero, size: size).dictionaryRepresentation,
        ]
        if let title { info[kCGWindowName as String] = title }
        return info
    }

    func testOnlyAnAppsOwnOutOfSightWindowsCallForEveryWindow() {
        let recorded = info(1, pid: 100, onScreen: true, title: "Report.pdf")
        // A browser's machinery: untitled, tiny, never shown.
        let machinery = (2...400).map { info($0, pid: 100, onScreen: false, size: .zero) }
        XCTAssertFalse(RecordingCaptureFilter.hasHiddenSiblings(of: 1, in: [recorded] + machinery))
        XCTAssertFalse(RecordingCaptureFilter.hasHiddenSiblings(of: 1, in: [recorded, info(500, pid: 100, onScreen: true, title: "Other")]), "on screen: the on-screen list has it")
        XCTAssertFalse(RecordingCaptureFilter.hasHiddenSiblings(of: 1, in: [recorded, info(501, pid: 200, onScreen: false, title: "Someone else")]), "another app's windows aren't hidden")
        XCTAssertFalse(RecordingCaptureFilter.hasHiddenSiblings(of: 1, in: [recorded, info(502, pid: 100, layer: 101, onScreen: false, title: "Menu")]), "only normal windows are hidden")
        XCTAssertTrue(RecordingCaptureFilter.hasHiddenSiblings(of: 1, in: [recorded] + machinery + [info(503, pid: 100, onScreen: false, title: "Minimized draft")]), "a minimized window could come back over the recording")
        XCTAssertFalse(RecordingCaptureFilter.hasHiddenSiblings(of: 99, in: [recorded]), "a window that's gone")
    }

    // MARK: Live: the first shot with nothing kept

    private func showWindow(color: NSColor, frame: NSRect, chrome: Bool) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: chrome ? [.borderless] : [.titled], backing: .buffered, defer: false)
        window.level = chrome ? .floating : .normal
        window.backgroundColor = color
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        // Fully shown at once: a titled window fades in, and a capture
        // mid-fade sees what's under it.
        window.animationBehavior = .none
        window.orderFrontRegardless()
        // Drawn now, not on the next display cycle: a window not drawn yet
        // shows what's under it.
        window.display()
        windows.append(window)
        return window
    }

    /// Until ScreenCaptureKit lists `windows` on screen (a few dozen ms).
    private func waitUntilListed(_ windows: [NSWindow]) async throws {
        let ids = Set(windows.compactMap { CGWindowID(exactly: $0.windowNumber) })
        for _ in 0..<40 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if ids.isSubset(of: Set(content.windows.map(\.windowID))) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("the test windows never came on screen")
    }

    private func centerColor(of image: NSImage) throws -> (r: Double, g: Double, b: Double) {
        var rect = NSRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let color = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }

    /// The windows at the middle of `rect`, front to back, as the window
    /// server stacks them (owner name and window number).
    private func windowsAtCenter(of rect: NSRect) -> [(owner: String, number: Int)] {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let center = CGPoint(x: rect.midX, y: primaryHeight - rect.midY)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo), bounds.contains(center),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            return (info[kCGWindowOwnerName as String] as? String ?? "?", info[kCGWindowNumber as String] as? Int ?? 0)
        }
    }

    /// Whether `window` is the front window at the middle of `rect`, `except`
    /// aside. Someone using the Mac while the test runs can click another
    /// app's window over it.
    private func isInFront(_ window: NSWindow, at rect: NSRect, except: NSWindow) -> Bool {
        windowsAtCenter(of: rect).first { $0.number != except.windowNumber }?.number == window.windowNumber
    }

    /// The report's check, on a cold list: Shotnix's floating chrome (a pin,
    /// the preview) stays out of the very first shot, and its content
    /// windows (an editor) stay in.
    func testTheFirstShotLeavesChromeOutAndKeepsContentWindows() async throws {
        guard CGPreflightScreenCaptureAccess(), #available(macOS 14.0, *) else { throw XCTSkip("needs Screen Recording permission") }
        guard let screen = NSScreen.main else { throw XCTSkip("no screen") }
        let engine = CaptureEngine()
        let origin = NSPoint(x: screen.frame.midX - 150, y: screen.frame.midY - 100)
        let editor = showWindow(color: .systemGreen, frame: NSRect(origin: origin, size: CGSize(width: 300, height: 200)), chrome: false)
        let pin = showWindow(color: .systemRed, frame: NSRect(origin: NSPoint(x: origin.x + 100, y: origin.y + 50), size: CGSize(width: 100, height: 100)), chrome: true)
        CATransaction.flush()
        try await waitUntilListed([editor, pin])
        try await Task.sleep(nanoseconds: 200_000_000)
        // A locked screen or a sleeping display is what any capture shows then.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        guard session["CGSSessionScreenIsLocked"] as? Bool != true, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else {
            throw XCTSkip("the screen is locked or asleep")
        }

        guard isInFront(editor, at: pin.frame, except: pin) else {
            throw XCTSkip("another window is over the test window: \(windowsAtCenter(of: pin.frame).prefix(3))")
        }

        ShareableContentStore.invalidate() // as after a display change
        let started = CFAbsoluteTimeGetCurrent()
        let shot = await engine.captureRectToImage(pin.frame, on: screen, purpose: "test shot")
        let image = try XCTUnwrap(shot)
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        guard isInFront(editor, at: pin.frame, except: pin) else {
            throw XCTSkip("another window came over the test window during the shot: \(windowsAtCenter(of: pin.frame).prefix(3))")
        }
        let color = try centerColor(of: image)
        let green = try XCTUnwrap(NSColor.systemGreen.usingColorSpace(.sRGB))
        print("FIRST SHOT: \(Int(elapsed * 1000)) ms, center \(color)")
        // The editor's own green, give or take the display's color matching
        // (about 0.1): not the red pin, and not whatever is behind the editor.
        let matchesEditor = abs(color.r - Double(green.redComponent)) < 0.15
            && abs(color.g - Double(green.greenComponent)) < 0.15
            && abs(color.b - Double(green.blueComponent)) < 0.15
        XCTAssertTrue(matchesEditor, "the shot shows the green editor, with the red pin left out: got \(color)")
        XCTAssertLessThan(elapsed, 2, "no every-window list on the way")
        if #available(macOS 14.4, *) {
            let own = await ShareableContentStore.ownApplication()
            XCTAssertEqual(own?.processID, pid_t(ProcessInfo.processInfo.processIdentifier))
        }
        withExtendedLifetime(editor) {}
    }
}
