import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Takes the first click, as the Settings window's content does.
private final class ClickableHost: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Settings > Screenshots > Save Location: the row shows the folder that
/// was just chosen, without leaving the tab and coming back.
@MainActor
final class SaveFolderSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var first: URL!
    private var second: URL!
    private var windows: [NSWindow] = []
    private let size = CGSize(width: 560, height: 1500)

    override func setUp() async throws {
        _ = NSApplication.shared
        suiteName = "ShotnixCoreTests.SaveFolder.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Settings.defaults = defaults
        // Nothing on the page that moves by itself: the file name preview
        // shows the time unless the template has no time in it.
        defaults.set("Shot", forKey: "filenameTemplate")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("snx-\(UUID().uuidString.prefix(6))", isDirectory: true)
        first = base.appendingPathComponent("first-folder", isDirectory: true)
        second = base.appendingPathComponent("second-folder", isDirectory: true)
        for folder in [first!, second!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        XCTAssertTrue(Settings.setAutoSaveLocation(first.path))
    }

    override func tearDown() async throws {
        ScreenshotsSettingsView.chooseFolder = Self.realChooser
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if let first { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        defaults.removePersistentDomain(forName: suiteName)
        Settings.defaults = .standard
    }

    private static let realChooser = ScreenshotsSettingsView.chooseFolder

    // MARK: Support

    /// The Screenshots tab in a window of its own, tall enough to show
    /// every section, reading and writing this test's settings.
    private func openTab() async -> NSHostingView<AnyView> {
        let page = ZStack(alignment: .top) {
            ShotnixTheme.stageBottom
            ScreenshotsSettingsView()
        }
        .frame(width: size.width, height: size.height)
        .defaultAppStorage(defaults)
        let host = ClickableHost(rootView: AnyView(page))
        host.frame = NSRect(origin: .zero, size: size)
        // Far off screen, in the window list like a visible one: SwiftUI
        // answers clicks only in a window that is.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -9000, y: -9000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = TestAppearance.appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        windows.append(window)
        await settle(host)
        return host
    }

    private func settle(_ host: NSView, _ seconds: TimeInterval = 0.3) async {
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        host.layoutSubtreeIfNeeded()
    }

    private func picture(of host: NSView, _ name: String) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-capture-snapshots/save-folder-\(name).png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return rep
    }

    /// Where two pictures differ: how many points, and the box around them
    /// (top-left origin).
    private func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (count: Int, box: CGRect) {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, let pa = a.bitmapData, let pb = b.bitmapData else {
            return (.max, .zero)
        }
        let samples = a.samplesPerPixel
        var count = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                let offset = y * a.bytesPerRow + x * samples
                var most = 0
                for channel in 0..<min(3, samples) {
                    most = max(most, abs(Int(pa[offset + channel]) - Int(pb[offset + channel])))
                }
                if most > 24 {
                    count += 1
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        let scale = CGFloat(a.pixelsWide) / size.width
        let box = count == 0 ? .zero : CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        return (count, box)
    }

    /// A click in top-left view coordinates.
    private func click(_ point: CGPoint, in host: NSView) async {
        guard let window = host.window else { return }
        let location = NSPoint(x: point.x, y: host.bounds.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await settle(host)
    }

    // MARK: The stored value

    func testTheShownFolderFollowsTheStoredValue() {
        XCTAssertEqual(Settings.autoSaveLocation(stored: ""), Settings.defaultAutoSaveLocation, "nothing stored: the Desktop")
        XCTAssertEqual(Settings.autoSaveLocation(stored: second.path), second.standardizedFileURL.path)
        XCTAssertEqual(Settings.autoSaveLocation(stored: second.path + "-gone"), Settings.defaultAutoSaveLocation, "a folder that isn't there")
        XCTAssertEqual(Settings.autoSaveLocation, first.standardizedFileURL.path, "and the setting reads the same way")
    }

    // MARK: The row

    /// The page is drawn from its settings: a different folder is a
    /// different picture, and the same folder the same one. The checks
    /// below lean on both.
    func testThePageShowsTheFolder() async throws {
        let withFirst = try picture(of: await openTab(), "first")
        let again = try picture(of: await openTab(), "first-again")
        XCTAssertEqual(difference(withFirst, again).count, 0, "nothing on the page changes by itself")
        XCTAssertTrue(Settings.setAutoSaveLocation(second.path))
        let withSecond = try picture(of: await openTab(), "second")
        let changed = difference(withFirst, withSecond)
        XCTAssertGreaterThan(changed.count, 20, "the folder's path is on the page")
        XCTAssertLessThan(changed.box.height, 24, "one line of text: \(changed.box)")
    }

    /// The folder changes while the tab is open (chosen here, or from the
    /// menu's own item): the row shows the new one at once, as a tab
    /// opened afresh does.
    func testAnOpenTabShowsAFolderChosenMeanwhile() async throws {
        let host = await openTab()
        let before = try picture(of: host, "open-before")
        XCTAssertTrue(Settings.setAutoSaveLocation(second.path))
        await settle(host)
        let after = try picture(of: host, "open-after")
        let fresh = try picture(of: await openTab(), "open-fresh")
        XCTAssertGreaterThan(difference(before, after).count, 20, "the row changed without leaving the tab")
        XCTAssertEqual(difference(after, fresh).count, 0, "and reads as it does after coming back to the tab")
    }

    /// The real thing: a click on Choose..., a folder picked in the panel.
    func testChoosingAFolderShowsItInTheRow() async throws {
        var asked: [String] = []
        ScreenshotsSettingsView.chooseFolder = { current in
            asked.append(current)
            return self.second
        }
        let host = await openTab()
        let before = try picture(of: host, "click-before")
        // The row is where the path is drawn: found by what a different
        // folder changes on the page. Its button is at the row's right end.
        XCTAssertTrue(Settings.setAutoSaveLocation(second.path))
        let path = difference(before, try picture(of: await openTab(), "click-probe")).box
        XCTAssertTrue(Settings.setAutoSaveLocation(first.path))
        await settle(host)
        XCTAssertEqual(difference(before, try picture(of: host, "click-reset")).count, 0, "back where it started")

        await click(CGPoint(x: size.width - 22 - 12 - 30, y: path.midY - 9), in: host)

        XCTAssertEqual(asked, [first.standardizedFileURL.path], "the panel opens in the current folder")
        XCTAssertEqual(Settings.autoSaveLocation, second.standardizedFileURL.path, "the folder is saved")
        let after = try picture(of: host, "click-after")
        let fresh = try picture(of: await openTab(), "click-fresh")
        XCTAssertGreaterThan(difference(before, after).count, 20, "the row shows the new folder right after the panel closes")
        XCTAssertEqual(difference(after, fresh).count, 0, "the same as after switching tabs and back")
    }

    /// Cancelling the panel changes nothing.
    func testCancellingThePanelKeepsTheFolder() async throws {
        var asked = 0
        ScreenshotsSettingsView.chooseFolder = { _ in
            asked += 1
            return nil
        }
        let host = await openTab()
        let before = try picture(of: host, "cancel-before")
        XCTAssertTrue(Settings.setAutoSaveLocation(second.path))
        let path = difference(before, try picture(of: await openTab(), "cancel-probe")).box
        XCTAssertTrue(Settings.setAutoSaveLocation(first.path))
        await settle(host)

        await click(CGPoint(x: size.width - 22 - 12 - 30, y: path.midY - 9), in: host)

        XCTAssertEqual(asked, 1, "the click reached the button")
        XCTAssertEqual(Settings.autoSaveLocation, first.standardizedFileURL.path)
        XCTAssertEqual(difference(before, try picture(of: host, "cancel-after")).count, 0)
    }
}
