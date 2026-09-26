import AppKit
import XCTest
@testable import ShotnixCore

/// Menu rows and on-screen hints: Capture All Displays is reachable on
/// multi-display Macs, and hints name the user's real shortcuts.
@MainActor
final class CaptureMenuAndHintsTests: XCTestCase {

    override func setUp() async throws {
        _ = NSApplication.shared
    }

    func testCaptureAllDisplaysRowOnlyWithSeveralDisplays() throws {
        let delegate = AppDelegate()
        let single = try XCTUnwrap(delegate.commandCenterSections(screenCount: 1).first { $0.id == "capture" })
        XCTAssertFalse(single.actions.map(\.id).contains("capture.all-displays"), "one display: nothing extra to capture")

        let dual = try XCTUnwrap(delegate.commandCenterSections(screenCount: 2).first { $0.id == "capture" })
        let ids = dual.actions.map(\.id)
        let fullscreen = try XCTUnwrap(ids.firstIndex(of: "capture.fullscreen"))
        XCTAssertEqual(ids[fullscreen + 1], "capture.all-displays", "sits right under Capture Fullscreen")
        XCTAssertEqual(dual.actions[fullscreen + 1].title, "Capture All Displays")
    }

    func testCaptureAllDisplaysHasAnAssignableShortcut() {
        XCTAssertTrue(ShotnixShortcut.allCases.contains(.captureAllDisplays))
        XCTAssertEqual(ShotnixShortcut.captureAllDisplays.title, "Capture All Displays")
        XCTAssertEqual(ShotnixShortcut.captureAllDisplays.name.rawValue, "captureAllDisplays")
    }

    func testWelcomeHintsNameTheBoundShortcuts() {
        let bound: [ShotnixShortcut: String] = [.captureArea: "⌃⌥4", .captureFullscreenNative: "⇧⌘3"]
        XCTAssertEqual(
            WelcomeWindowController.shortcutsHint(shortcut: { bound[$0] }),
            "⌃⌥4 area · ⇧⌘3 fullscreen — Shotnix lives in your menu bar"
        )
        XCTAssertEqual(WelcomeWindowController.shortcutsHint(shortcut: { _ in nil }), "Shotnix lives in your menu bar")
        XCTAssertEqual(WelcomeWindowController.captureHint(captureAreaShortcut: "⌃⌥4"), "Press ⌃⌥4 anytime — or try it right now.")
        XCTAssertFalse(WelcomeWindowController.captureHint(captureAreaShortcut: nil).contains("⌘"))
    }

    func testHiddenMenuBarIconToastNamesTheBoundShortcut() {
        XCTAssertTrue(AppDelegate.hiddenIconMessage(captureAreaShortcut: "⇧⌘4").contains("⇧⌘4 still captures"))
        let unassigned = AppDelegate.hiddenIconMessage(captureAreaShortcut: nil)
        XCTAssertTrue(unassigned.contains("your shortcuts still work"))
        XCTAssertFalse(unassigned.contains("⌘"))
    }
}
