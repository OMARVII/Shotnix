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
}
