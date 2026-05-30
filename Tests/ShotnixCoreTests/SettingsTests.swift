import XCTest
@testable import ShotnixCore

final class SettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ShotnixCoreTests.Settings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        Settings.defaults = defaults
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        Settings.defaults = .standard
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsMatchFreshInstallBehavior() {
        XCTAssertEqual(Settings.overlayTimeout, 6)
        XCTAssertTrue(Settings.overlayOnLeft)
        XCTAssertTrue(Settings.playSounds)
        XCTAssertTrue(Settings.afterCaptureShowOverlay)
        XCTAssertTrue(Settings.afterCaptureCopyToClipboard)
        XCTAssertFalse(Settings.afterCaptureSaveAutomatically)
        XCTAssertEqual(Settings.screenshotFormat, "png")
        XCTAssertEqual(Settings.jpegQuality, 0.95, accuracy: 0.001)
        XCTAssertEqual(Settings.recordingFPS, 30)
        XCTAssertEqual(Settings.recordingQuality, "high")
        XCTAssertTrue(Settings.recordingShowsCursor)
    }

    func testRecordingSettingsClampInvalidValues() {
        Settings.recordingFPS = 99
        Settings.recordingQuality = "cinematic"

        XCTAssertEqual(Settings.recordingFPS, 30)
        XCTAssertEqual(Settings.recordingQuality, "high")

        Settings.recordingFPS = 60
        Settings.recordingQuality = "max"

        XCTAssertEqual(Settings.recordingFPS, 60)
        XCTAssertEqual(Settings.recordingQuality, "max")
    }
}
