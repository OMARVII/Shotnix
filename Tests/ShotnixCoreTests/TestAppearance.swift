import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// The appearance the tests draw the interface in.
///
/// Dark, as Shotnix was always drawn, whatever the Mac is set to. With
/// `SHOTNIX_TEST_APPEARANCE=light` every snapshot comes out in the light
/// appearance instead, under the same names: point `TMPDIR` somewhere else
/// to keep both sets side by side.
enum TestAppearance {
    static let isLight = ProcessInfo.processInfo.environment["SHOTNIX_TEST_APPEARANCE"] == "light"

    static var name: NSAppearance.Name { isLight ? .aqua : .darkAqua }
    static var colorScheme: ColorScheme { isLight ? .light : .dark }

    /// For a window or a view that pins its appearance. Asking for it also
    /// puts the app as a whole in that appearance, for the windows the code
    /// under test opens by itself.
    @MainActor
    static var appearance: NSAppearance? {
        applyToApp()
        return NSAppearance(named: name)
    }

    @MainActor
    static func applyToApp() {
        guard NSApplication.shared.appearance?.name != name else { return }
        NSApplication.shared.appearance = NSAppearance(named: name)
    }
}

/// Runs first (test classes go in alphabetical order) and puts the whole
/// test app in the appearance asked for, before any window exists.
@MainActor
final class AAAppearanceTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        MainActor.assumeIsolated { TestAppearance.applyToApp() }
    }

    func testTheTestAppDrawsInTheAppearanceAskedFor() {
        XCTAssertEqual(NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), TestAppearance.name)
    }
}
