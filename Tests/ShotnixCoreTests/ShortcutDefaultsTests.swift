import KeyboardShortcuts
import XCTest
@testable import ShotnixCore

final class ShortcutDefaultsTests: XCTestCase {
    func testAllExpectedShortcutsAreRegistered() {
        XCTAssertEqual(ShotnixShortcut.allCases.count, 7)
        XCTAssertEqual(Set(ShotnixShortcut.allCases.map(\.name.rawValue)).count, ShotnixShortcut.allCases.count)
    }

    func testDefaultShortcutMappingMatchesLegacyHotkeys() {
        XCTAssertEqual(ShotnixShortcut.captureArea.name.defaultShortcut, .init(.four, modifiers: [.command, .shift]))
        XCTAssertEqual(ShotnixShortcut.captureWindow.name.defaultShortcut, .init(.five, modifiers: [.command, .shift]))
        XCTAssertEqual(ShotnixShortcut.captureFullscreenNative.name.defaultShortcut, .init(.three, modifiers: [.command, .shift]))
        XCTAssertEqual(ShotnixShortcut.captureFullscreenFallback.name.defaultShortcut, .init(.six, modifiers: [.command, .shift]))
        XCTAssertEqual(ShotnixShortcut.capturePreviousArea.name.defaultShortcut, .init(.seven, modifiers: [.command, .shift]))
        XCTAssertEqual(ShotnixShortcut.captureText.name.defaultShortcut, .init(.o, modifiers: [.command, .shift]))
        XCTAssertEqual(ShotnixShortcut.captureScrolling.name.defaultShortcut, .init(.s, modifiers: [.command, .shift]))
    }
}
