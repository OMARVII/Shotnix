import AppKit
import AVFoundation
import IOKit.pwr_mgt
import ScreenCaptureKit
import XCTest
@testable import ShotnixCore

/// What a display recording keeps out of the picture, checked in real
/// recordings of this Mac's own menu bar and desktop: the recorder's menu bar
/// item, the recording indicator of macOS, every menu bar icon when asked, and
/// the desktop icons when asked. Needs Screen Recording permission for the
/// test runner, skipped otherwise.
@MainActor
final class RecordingCleanScreenIntegrationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var engine: RecordingEngine?
    private var displayAssertion: IOPMAssertionID = 0
    private var windows: [NSWindow] = []
    private var statusItems: [NSStatusItem] = []

    override func setUp() async throws {
        try await super.setUp()
        guard CGPreflightScreenCaptureAccess() else { throw XCTSkip("needs Screen Recording permission") }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Shotnix recording tests" as CFString, &displayAssertion)
        var activity: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Shotnix recording tests" as CFString, kIOPMUserActiveLocal, &activity)
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        guard session["CGSSessionScreenIsLocked"] as? Bool != true, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else {
            throw XCTSkip("the screen is locked or asleep")
        }
        _ = NSApplication.shared
        VideoTestStorage.isolate()
        suiteName = "ShotnixCoreTests.RecordingCleanScreen.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Settings.defaults = defaults
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("recordings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertTrue(Settings.setAutoSaveLocation(folder.path))
        Settings.recordingMicrophone = false
        Settings.recordingSystemAudio = false
        Settings.recordingCamera = false
        Settings.recordingKeystrokes = false
        Settings.openVideoEditorAfterRecording = false
        Settings.recordingFPS = 30
    }

    override func tearDown() async throws {
        if let engine, engine.active {
            engine.discardRecording()
            try? await waitUntil(timeout: 10) { !engine.active }
        }
        engine = nil
        statusItems.forEach(NSStatusBar.system.removeStatusItem)
        statusItems.removeAll()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        Settings.defaults = .standard
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion) }
        try await super.tearDown()
    }

    // MARK: Support

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// A recording of `rect` that delivers frames, or a skip when this Mac
    /// won't give one (see RecordingEngineIntegrationTests).
    private func record(_ rect: CGRect, on screen: NSScreen) async throws -> (RecordingEngine, () -> URL?) {
        let engine = RecordingEngine()
        self.engine = engine
        var finished: URL?
        engine.recordingFinishedHandler = { finished = $0.url }
        await engine.startRecording(rect: rect, on: screen)
        if engine.elapsedSeconds == nil {
            try await sleep(1)
            await engine.startRecording(rect: rect, on: screen)
        }
        guard engine.elapsedSeconds != nil else { throw XCTSkip("ScreenCaptureKit didn't start a stream") }
        let deadline = Date().addingTimeInterval(6)
        while !engine.hasCapturedFrames, Date() < deadline {
            try await sleep(0.05)
        }
        guard engine.hasCapturedFrames else { throw XCTSkip("the screen isn't delivering frames") }
        return (engine, { finished })
    }

    /// The top of a screen, menu bar included.
    @MainActor
    private struct Strip {
        let screen: NSScreen
        static let height: CGFloat = 48

        /// AppKit space: what the recording is asked for.
        var rect: CGRect { CGRect(x: screen.frame.minX, y: screen.frame.maxY - Self.height, width: screen.frame.width, height: Self.height) }
        /// CG space, where window frames are.
        var cgRect: CGRect { ScreenCoordinates.cgRect(fromAppKit: rect) }
        var width: Int { Int(rect.width) }
        var height: Int { Int(Self.height) }

        /// A window's frame in the strip's own points (top-left origin),
        /// short of its edges: video encoding blurs the menu bar's lower
        /// edge into its last row.
        func local(_ frame: CGRect) -> CGRect {
            frame.offsetBy(dx: -cgRect.minX, dy: -cgRect.minY).insetBy(dx: 1, dy: 3).intersection(CGRect(x: 0, y: 0, width: cgRect.width, height: cgRect.height))
        }
    }

    /// A picture at one byte quadruple per point, top row first.
    private struct Pixels {
        let width: Int
        let height: Int
        private(set) var data: [UInt8]

        init(_ image: CGImage, width: Int, height: Int) {
            self.width = width
            self.height = height
            data = [UInt8](repeating: 0, count: width * height * 4)
            let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        private func each(in rect: CGRect, _ body: (Int) -> Void) -> Int {
            let columns = max(0, Int(rect.minX.rounded()))..<min(width, Int(rect.maxX.rounded()))
            let rows = max(0, Int(rect.minY.rounded()))..<min(height, Int(rect.maxY.rounded()))
            for row in rows { for column in columns { body((row * width + column) * 4) } }
            return columns.count * rows.count
        }

        /// The share of `rect` that looks clearly different from `other`:
        /// something drawn there that the other picture doesn't have.
        func changed(from other: Pixels, in rect: CGRect) -> Double {
            var differing = 0
            let total = each(in: rect) { offset in
                let difference = (0..<3).map { abs(Int(data[offset + $0]) - Int(other.data[offset + $0])) }.max() ?? 0
                if difference > 51 { differing += 1 }
            }
            return total > 0 ? Double(differing) / Double(total) : 0
        }

        /// How many points of `rect` look clearly different from `other`:
        /// for something as small as a dot, which is no share of anything.
        func differing(from other: Pixels, in rect: CGRect) -> Int {
            var differing = 0
            _ = each(in: rect) { offset in
                let difference = (0..<3).map { abs(Int(data[offset + $0]) - Int(other.data[offset + $0])) }.max() ?? 0
                if difference > 51 { differing += 1 }
            }
            return differing
        }

        /// The share of `rect` that is magenta, the color nothing else on a Mac's screen is.
        func magenta(in rect: CGRect) -> Double {
            var found = 0
            let total = each(in: rect) { offset in
                if data[offset] > 170, data[offset + 1] < 110, data[offset + 2] > 170 { found += 1 }
            }
            return total > 0 ? Double(found) / Double(total) : 0
        }
    }

    /// The screen as it is now, with or without Control Center's windows.
    private func still(of rect: CGRect, on screen: NSScreen, withoutControlCenter: Bool = false) async throws -> Pixels {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = try XCTUnwrap(ScreenCoordinates.display(for: screen, in: content.displays))
        let left = withoutControlCenter ? content.applications.filter { $0.bundleIdentifier == RecordingMenuBar.controlCenterBundleID } : []
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        configuration.width = Int(rect.width)
        configuration.height = Int(rect.height)
        configuration.showsCursor = false
        let image: CGImage = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingApplications: left, exceptingWindows: []), configuration: configuration)
        return Pixels(image, width: Int(rect.width), height: Int(rect.height))
    }

    private func frame(of url: URL, at seconds: Double, width: Int, height: Int) async throws -> Pixels {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        return Pixels(image, width: width, height: height)
    }

    private static func magentaImage(_ size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// This process's own menu bar item, as Control Center shows it: what
    /// Shotnix's timer is to Shotnix.
    private func ownMenuBarItem(controlCenter: pid_t) async throws -> RecordingMenuBar.Window {
        let item = NSStatusBar.system.statusItem(withLength: 46)
        statusItems.append(item)
        item.button?.image = Self.magentaImage(NSSize(width: 40, height: 16))
        for _ in 0..<60 {
            let windows = RecordingMenuBar.windowsOnScreen(controlCenter: controlCenter)
            let ids = RecordingMenuBar.recorderItems(among: windows, ownBundleID: nil, ownItemFrames: RecordingMenuBar.ownItemFrames())
            if let window = windows.first(where: { ids.contains($0.id) && $0.name != RecordingMenuBar.systemIndicatorName }) { return window }
            try await sleep(0.1)
        }
        throw XCTSkip("the menu bar didn't take a new item (full, or hidden)")
    }

    private func screen(showing frame: CGRect) throws -> NSScreen {
        try XCTUnwrap(NSScreen.screens.first { ScreenCoordinates.cgRect(fromAppKit: $0.frame).contains(CGPoint(x: frame.midX, y: frame.midY)) })
    }


    /// Control Center's menu bar items on the strip. By where an item's
    /// middle is: the clock at the end of a display to the left reaches a
    /// point or two into this one.
    private func items(on strip: Strip, controlCenter: pid_t) -> [RecordingMenuBar.Window] {
        RecordingMenuBar.windowsOnScreen(controlCenter: controlCenter).filter {
            $0.layer == RecordingMenuBar.itemLayer && strip.cgRect.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }
    }

    /// The Window Server's dots on the strip, in the strip's own points.
    private func dots(on strip: Strip) -> [CGRect] {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = RecordingMenuBar.privacyDots(in: windowList)
        return windowList.compactMap { info -> CGRect? in
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, ids.contains(CGWindowID(number)),
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }),
                  strip.cgRect.intersects(bounds) else { return nil }
            return bounds.offsetBy(dx: -strip.cgRect.minX, dy: -strip.cgRect.minY)
        }
    }

    /// Waits until macOS has taken down what an earlier capture brought up:
    /// a recording a person starts begins from a quiet menu bar.
    private func waitForAQuietMenuBar(controlCenter: pid_t) async throws {
        for _ in 0..<80 {
            let look = RecordingMenuBar.look(controlCenter: controlCenter)
            if look.dots.isEmpty, RecordingMenuBar.indicators(among: look.controlCenter).isEmpty { break }
            try await sleep(0.1)
        }
        try await sleep(0.4)
    }

    /// A part of `screen` (AppKit space) no window covers, so the desktop
    /// shows there.
    private func freeDesktopArea(on screen: NSScreen, size: CGSize) -> CGRect? {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let covered = windowList.compactMap { info -> CGRect? in
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 >= 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }) else { return nil }
            return bounds
        }
        let area = ScreenCoordinates.cgRect(fromAppKit: screen.visibleFrame).insetBy(dx: 8, dy: 8)
        for y in stride(from: area.minY, through: area.maxY - size.height, by: 24) {
            for x in stride(from: area.minX, through: area.maxX - size.width, by: 24) {
                let candidate = CGRect(origin: CGPoint(x: x, y: y), size: size)
                if !covered.contains(where: { $0.intersects(candidate) }) {
                    return ScreenCoordinates.appKitRect(fromCG: candidate)
                }
            }
        }
        return nil
    }

    /// The part of the strip the items are in.
    private func itemsRegion(_ items: [RecordingMenuBar.Window], on strip: Strip) -> CGRect {
        let frames = items.map { strip.local($0.frame) }.filter { !$0.isEmpty }
        guard let left = frames.map(\.minX).min() else { return .zero }
        return CGRect(x: left, y: 3, width: strip.cgRect.width - left, height: (frames.map(\.maxY).max() ?? 24) - 3)
    }

    // MARK: The menu bar

    func testTheRecordersItemAndWhatMacOSShowsWhileRecordingStayOutOfTheVideo() async throws {
        guard RecordingMenuBar.controlCenterHostsEveryItem else { throw XCTSkip("before macOS 26 an app's menu bar item is its own window") }
        let controlCenter = try XCTUnwrap(RecordingMenuBar.controlCenterProcessID())
        // A menu bar with no room left doesn't show a new item (beside a
        // notch, mostly): what macOS shows is still checked then.
        var own = try? await ownMenuBarItem(controlCenter: controlCenter)
        let strip = Strip(screen: try own.map { try screen(showing: $0.frame) } ?? XCTUnwrap(NSScreen.main))
        try await waitForAQuietMenuBar(controlCenter: controlCenter)

        // The bar without any item, and as it is now.
        let empty = try await still(of: strip.rect, on: strip.screen, withoutControlCenter: true)
        let live = try await still(of: strip.rect, on: strip.screen)
        if let item = own, live.magenta(in: strip.local(item.frame)) <= 0.3 { own = nil }
        let others = items(on: strip, controlCenter: controlCenter).filter { $0.id != own?.id && $0.name != RecordingMenuBar.systemIndicatorName }
        let drawn = others.filter { live.changed(from: empty, in: strip.local($0.frame)) > 0.03 }
        try XCTSkipIf(drawn.isEmpty, "no other icons in this menu bar to compare with")
        // Those stills brought the indicators up: gone again before the
        // recording, which has to bring them up itself.
        try await waitForAQuietMenuBar(controlCenter: controlCenter)

        let (engine, finished) = try await record(strip.rect, on: strip.screen)
        XCTAssertFalse(engine.coversDesktopIcons, "off unless asked for")
        try await sleep(0.8)
        // What is really on the bar while it records, and where.
        let onBar = try await still(of: strip.rect, on: strip.screen)
        let now = items(on: strip, controlCenter: controlCenter)
        let ownNow = own.flatMap { item in now.first { $0.id == item.id } }
        if own != nil { XCTAssertNotNil(ownNow, "the item keeps its window") }
        let indicator = now.first { $0.name == RecordingMenuBar.systemIndicatorName }
        let dotRects = dots(on: strip)
        try await sleep(1.9)
        let rebuilds = engine.menuBarFilterRebuilds
        engine.stopRecording()
        try await waitUntil(timeout: 20) { finished() != nil }
        let url = try XCTUnwrap(finished())

        let ownRects = [own, ownNow].compactMap { $0 }.map { strip.local($0.frame) }
        if let last = ownRects.last {
            XCTAssertGreaterThan(onBar.magenta(in: last), 0.3, "the recorder's item is on the real bar")
        }
        let dotsOnBar = dotRects.filter { onBar.differing(from: empty, in: $0) > 4 }
        let indicatorOnBar = indicator.map { onBar.changed(from: empty, in: strip.local($0.frame)) > 0.03 } ?? false
        let region = itemsRegion(now, on: strip)
        let late = try await frame(of: url, at: 2.3, width: strip.width, height: strip.height)

        // Every frame of the first half second, where macOS brings its
        // indicators up, then across the end of the launch phase.
        var mostMoved = 0.0
        for time in stride(from: 0.0, through: 0.5, by: 1.0 / 30) + [0.8, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.9, 2.3] {
            let frame = try await frame(of: url, at: time, width: strip.width, height: strip.height)
            let at = String(format: "%.2f s", time)
            for rect in ownRects {
                XCTAssertLessThan(frame.magenta(in: rect), 0.01, "the recorder's own item at \(at)")
            }
            if let last = ownRects.last {
                XCTAssertLessThan(frame.changed(from: empty, in: last), 0.01, "nothing drawn where it is at \(at)")
            }
            if let indicator {
                XCTAssertLessThan(frame.changed(from: empty, in: strip.local(indicator.frame)), 0.01, "the recording indicator at \(at)")
            }
            for dot in dotsOnBar {
                XCTAssertLessThanOrEqual(frame.differing(from: empty, in: dot), 2, "the dot beside Control Center's icon at \(at)")
            }
            // The icons made room for the indicator and the timer before
            // the first frame: nothing slides in the video.
            let moved = frame.changed(from: late, in: region)
            mostMoved = max(mostMoved, moved)
            XCTAssertLessThan(moved, 0.01, "the menu bar holds still from the first frame, at \(at)")
        }
        let shown = drawn.compactMap { item in now.first { $0.id == item.id } }.filter { late.changed(from: empty, in: strip.local($0.frame)) > 0.015 }
print(String(format: "MENU BAR: %d other icons drawn, %d in the video; on the real bar: the recorder's item %@, indicator %@, dots %d; most of the bar that moved in any frame %.4f; filter rebuilt for the menu bar %d×", drawn.count, shown.count, own != nil ? "yes" : "no (no room for it)", indicatorOnBar ? "yes" : "no", dotsOnBar.count, mostMoved, rebuilds))
        XCTAssertGreaterThanOrEqual(shown.count * 10, drawn.count * 8, "everyone else's icons stay in the video")
        XCTAssertTrue(indicatorOnBar, "macOS showed its indicator, so the check above means something")
        XCTAssertFalse(dotsOnBar.isEmpty, "and its dot")
        XCTAssertLessThanOrEqual(rebuilds, 1, "one rebuild ends the launch phase; a still menu bar asks for no more")
    }

    func testHidingMenuBarIconsLeavesThemAllOut() async throws {
        guard RecordingMenuBar.controlCenterHostsEveryItem else { throw XCTSkip("before macOS 26 an app's menu bar item is its own window") }
        let controlCenter = try XCTUnwrap(RecordingMenuBar.controlCenterProcessID())
        Settings.recordingHidesMenuBarIcons = true
        let strip = Strip(screen: try XCTUnwrap(NSScreen.main))
        try await waitForAQuietMenuBar(controlCenter: controlCenter)

        let empty = try await still(of: strip.rect, on: strip.screen, withoutControlCenter: true)
        let live = try await still(of: strip.rect, on: strip.screen)
        let drawn = items(on: strip, controlCenter: controlCenter).filter { live.changed(from: empty, in: strip.local($0.frame)) > 0.03 }
        try XCTSkipIf(drawn.count < 2, "no icons in this menu bar to hide")
        try await waitForAQuietMenuBar(controlCenter: controlCenter)

        let (engine, finished) = try await record(strip.rect, on: strip.screen)
        try await sleep(0.8)
        let onBar = try await still(of: strip.rect, on: strip.screen)
        let now = items(on: strip, controlCenter: controlCenter)
        let dotRects = dots(on: strip)
        try await sleep(1.3)
        let rebuilds = engine.menuBarFilterRebuilds
        engine.stopRecording()
        try await waitUntil(timeout: 20) { finished() != nil }
        let url = try XCTUnwrap(finished())

        let dotsOnBar = dotRects.filter { onBar.differing(from: empty, in: $0) > 4 }
        let region = itemsRegion(now, on: strip)
        XCTAssertGreaterThan(onBar.changed(from: empty, in: region), 0.02, "the icons are on the real bar")
        for time in stride(from: 0.0, through: 0.5, by: 1.0 / 30) + [0.8, 1.2, 1.7] {
            let frame = try await frame(of: url, at: time, width: strip.width, height: strip.height)
            let at = String(format: "%.2f s", time)
            let showing = now.filter { frame.changed(from: empty, in: strip.local($0.frame)) > 0.01 }
            XCTAssertTrue(showing.isEmpty, "\(showing.count) of \(now.count) icons in the video at \(at): \(showing.map(\.name))")
            XCTAssertLessThan(frame.changed(from: empty, in: region), 0.002, "nothing at all on the right of the bar at \(at)")
            for dot in dotsOnBar {
                XCTAssertLessThanOrEqual(frame.differing(from: empty, in: dot), 2, "the dot beside Control Center's icon at \(at)")
            }
        }
        // The left of the bar, where the app's menus are, is as on screen.
        let menus = CGRect(x: 0, y: 3, width: 300, height: region.height)
        let middle = try await frame(of: url, at: 0.9, width: strip.width, height: strip.height)
        XCTAssertLessThan(middle.changed(from: onBar, in: menus), 0.05, "the app menus stay")
        print("MENU BAR, icons hidden: \(drawn.count) icons drawn on screen, none in the video; dots on the real bar: \(dotsOnBar.count); filter rebuilt for the menu bar \(rebuilds)×")
        XCTAssertFalse(dotsOnBar.isEmpty, "macOS showed its dot, so the check above means something")
        XCTAssertEqual(rebuilds, 0, "everything was left out before the first frame, and nothing is let back in")
    }

    // MARK: The desktop

    func testHidingDesktopIconsCoversTheRecordedDisplayUntilTheRecordingStops() async throws {
        Settings.recordingHidesDesktopIcons = true
        let screen = try XCTUnwrap(NSScreen.main)
        // Where the desktop shows, if it does anywhere: the largest such
        // area that takes a stand-in file, down to a small one.
        var rect = CGRect(x: screen.frame.minX + 120, y: screen.frame.minY + 120, width: 640, height: 360)
        var fileFrame = NSRect(x: rect.minX + 200, y: rect.minY + 100, width: 220, height: 140)
        for (area, file) in [
            (CGSize(width: 420, height: 280), CGRect(x: 100, y: 60, width: 220, height: 140)),
            (CGSize(width: 280, height: 190), CGRect(x: 70, y: 40, width: 140, height: 80)),
            (CGSize(width: 180, height: 130), CGRect(x: 40, y: 25, width: 100, height: 50)),
        ] {
            guard let free = freeDesktopArea(on: screen, size: area) else { continue }
            rect = free
            fileFrame = file.offsetBy(dx: free.minX, dy: free.minY)
            break
        }

        // Stands in for a file on the desktop: at the icons' level, and
        // titled, which a recording keeps when it's one of Shotnix's own.
        let file = NSWindow(contentRect: fileFrame, styleMask: [.titled], backing: .buffered, defer: false)
        file.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        file.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        file.isReleasedWhenClosed = false
        file.orderFrontRegardless()
        file.display()
        windows.append(file)
        try await sleep(0.5)
        let whole = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
        // Only where the desktop shows through other apps' windows.
        let fileShows = try await still(of: rect, on: screen).magenta(in: whole) > 0.05

        func covers() -> [NSWindow] { NSApp.windows.filter { DesktopIconsCover.isCoverWindow($0) && $0.isVisible } }
        XCTAssertTrue(covers().isEmpty)
        let (engine, finished) = try await record(rect, on: screen)
        XCTAssertTrue(engine.coversDesktopIcons)
        XCTAssertEqual(covers().map(\.frame), [screen.frame], "the recorded display, and no other")
        // The video shows the cover only if the capture's window list names
        // it: Shotnix's other windows are left out of a recording.
        let listed = Set(try await ShareableContentStore.content(fresh: true, purpose: "test").windows.map(\.windowID))
        let coverIDs = covers().compactMap { CGWindowID(exactly: $0.windowNumber) }
        XCTAssertEqual(coverIDs.count, 1)
        XCTAssertTrue(coverIDs.allSatisfy(listed.contains), "the cover is a window a recording can keep")
        XCTAssertTrue(coverIDs.allSatisfy(RecordingCaptureFilter.recordableOwnWindowIDs().union(coverIDs).contains))
        if fileShows {
            let covered = try await still(of: rect, on: screen).magenta(in: whole)
            XCTAssertLessThan(covered, 0.01, "covered on screen")
        }
        try await sleep(1.6)
        engine.stopRecording()
        XCTAssertFalse(engine.coversDesktopIcons, "back the moment it stops, not once the file is saved")
        XCTAssertTrue(covers().isEmpty)
        try await waitUntil(timeout: 20) { finished() != nil }
        let url = try XCTUnwrap(finished())

        guard fileShows else {
            print("DESKTOP: other windows cover the test area, so the video wasn't checked for the file")
            return
        }
        for time in [0.0, 0.7, 1.4] {
            let frame = try await frame(of: url, at: time, width: Int(rect.width), height: Int(rect.height))
            XCTAssertLessThan(frame.magenta(in: whole), 0.01, "the cover is in the video at \(time) s, the file under it isn't")
        }
        let after = try await still(of: rect, on: screen).magenta(in: whole)
        XCTAssertGreaterThan(after, 0.05, "and the desktop is back as it was")
    }

    func testWithoutTheSettingTheDesktopIsLeftAlone() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let rect = CGRect(x: screen.frame.minX + 120, y: screen.frame.minY + 120, width: 640, height: 360)
        let (engine, finished) = try await record(rect, on: screen)
        XCTAssertFalse(engine.coversDesktopIcons)
        XCTAssertTrue(NSApp.windows.filter(DesktopIconsCover.isCoverWindow).isEmpty)
        XCTAssertEqual(engine.menuBarFilterRebuilds, 0, "an area below the menu bar has nothing of Control Center's to keep up with")
        try await sleep(1)
        XCTAssertEqual(engine.menuBarFilterRebuilds, 0)
        engine.stopRecording()
        try await waitUntil(timeout: 20) { finished() != nil }
    }
}
