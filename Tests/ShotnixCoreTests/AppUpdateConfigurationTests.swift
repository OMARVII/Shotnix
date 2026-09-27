import XCTest
@testable import ShotnixCore

final class AppUpdateConfigurationTests: XCTestCase {
    func testRejectsMissingOrPlaceholderConfiguration() {
        XCTAssertNil(AppUpdateConfiguration(feedURLString: nil, publicEDKey: "abc"))
        XCTAssertNil(AppUpdateConfiguration(feedURLString: "https://shotnix.com/downloads/appcast.xml", publicEDKey: nil))
        XCTAssertNil(AppUpdateConfiguration(feedURLString: "https://shotnix.com/downloads/appcast.xml", publicEDKey: "SET_SPARKLE_PUBLIC_ED_KEY_IN_RELEASE_BUILD"))
    }

    func testAcceptsValidConfiguration() throws {
        let configuration = try XCTUnwrap(AppUpdateConfiguration(
            feedURLString: "https://shotnix.com/downloads/appcast.xml",
            publicEDKey: "abcdefghijklmnopqrstuvwxyz"
        ))

        XCTAssertEqual(configuration.feedURL.absoluteString, "https://shotnix.com/downloads/appcast.xml")
        XCTAssertEqual(configuration.publicEDKey, "abcdefghijklmnopqrstuvwxyz")
    }

    /// A downloaded update installs by itself only when nothing would notice
    /// Shotnix quitting and reopening.
    func testDownloadedUpdateWaitsForAQuietMoment() {
        XCTAssertTrue(QuietUpdateInstaller.isQuiet(busy: false, openWindows: 0, idleSeconds: 60))
        XCTAssertFalse(QuietUpdateInstaller.isQuiet(busy: true, openWindows: 0, idleSeconds: 600), "a recording or export is running")
        XCTAssertFalse(QuietUpdateInstaller.isQuiet(busy: false, openWindows: 1, idleSeconds: 600), "an editor, Settings or a pin is open")
        XCTAssertFalse(QuietUpdateInstaller.isQuiet(busy: false, openWindows: 0, idleSeconds: 20), "someone is typing or pointing")
    }
}
