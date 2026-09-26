import XCTest
@testable import ShotnixCore

final class RecordingSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ShotnixCoreTests.RecordingSettings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Settings.defaults = defaults
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        Settings.defaults = .standard
        super.tearDown()
    }

    /// Pressing Record in 0.23.1 and earlier stored whatever the menu
    /// showed, so a stored 30 usually wasn't a choice. It moves to 60 once.
    func testStoredThirtyMovesToSixtyOnce() {
        defaults.set(30, forKey: "recordingFPS")
        Settings.migrateRecordingFPSIfNeeded()
        XCTAssertEqual(Settings.recordingFPS, 60)
        XCTAssertNil(defaults.object(forKey: "recordingFPS"), "no value stored: the default applies")

        // Picking 30 afterwards sticks — the migration never runs again.
        Settings.recordingFPS = 30
        Settings.migrateRecordingFPSIfNeeded()
        XCTAssertEqual(Settings.recordingFPS, 30)
    }

    func testMigrationLeavesOtherValuesAlone() {
        defaults.set(60, forKey: "recordingFPS")
        Settings.migrateRecordingFPSIfNeeded()
        XCTAssertEqual(defaults.integer(forKey: "recordingFPS"), 60)

        // A fresh install: nothing stored, nothing written except the flag.
        let freshSuite = "ShotnixCoreTests.RecordingSettings.fresh.\(UUID().uuidString)"
        let fresh = UserDefaults(suiteName: freshSuite)!
        defer { fresh.removePersistentDomain(forName: freshSuite) }
        Settings.defaults = fresh
        Settings.migrateRecordingFPSIfNeeded()
        XCTAssertNil(fresh.object(forKey: "recordingFPS"))
        XCTAssertEqual(Settings.recordingFPS, 60)
        XCTAssertTrue(fresh.bool(forKey: "didMigrateRecordingFPSTo60"))
    }

    func testCountdownOffersOffThreeFiveTen() {
        XCTAssertEqual(Settings.recordingCountdownSeconds, 0, "off by default")
        for seconds in [3, 5, 10, 0] {
            Settings.recordingCountdownSeconds = seconds
            XCTAssertEqual(Settings.recordingCountdownSeconds, seconds)
        }
        Settings.recordingCountdownSeconds = 7
        XCTAssertEqual(Settings.recordingCountdownSeconds, 0)
        defaults.set(42, forKey: "recordingCountdownSeconds")
        XCTAssertEqual(Settings.recordingCountdownSeconds, 0)
    }

    func testHUDPositionIsRemembered() {
        XCTAssertNil(Settings.recordingHUDOffset)
        Settings.recordingHUDOffset = CGPoint(x: -240, y: 64)
        XCTAssertEqual(Settings.recordingHUDOffset, CGPoint(x: -240, y: 64))
        Settings.recordingHUDOffset = nil
        XCTAssertNil(Settings.recordingHUDOffset)
    }
}
