import XCTest
@testable import ShotnixCore

final class StarNudgeTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ShotnixCoreTests.StarNudge.\(UUID().uuidString)"
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

    func testFreshInstallIsPendingWithZeroCaptures() {
        XCTAssertEqual(StarNudge.state, .pending)
        XCTAssertEqual(Settings.captureCount, 0)
        XCTAssertFalse(StarNudge.shouldShowInHistoryPanel)
    }

    func testNudgeFiresExactlyOnceOnThresholdCapture() {
        for _ in 1..<StarNudge.captureThreshold {
            XCTAssertFalse(StarNudge.recordCapture())
            XCTAssertEqual(StarNudge.state, .pending)
        }

        XCTAssertTrue(StarNudge.recordCapture(), "the threshold capture fires the nudge")
        XCTAssertEqual(StarNudge.state, .toastShown)
        XCTAssertTrue(StarNudge.shouldShowInHistoryPanel)

        XCTAssertFalse(StarNudge.recordCapture(), "later captures never fire it again")
        XCTAssertEqual(Settings.captureCount, StarNudge.captureThreshold + 1, "captures keep being counted")
    }

    func testDismissRetiresNudgeForGood() {
        for _ in 0..<StarNudge.captureThreshold { StarNudge.recordCapture() }
        StarNudge.markDismissed()

        XCTAssertEqual(StarNudge.state, .dismissed)
        XCTAssertFalse(StarNudge.shouldShowInHistoryPanel)
        for _ in 0..<50 { XCTAssertFalse(StarNudge.recordCapture()) }
        XCTAssertEqual(StarNudge.state, .dismissed)
    }

    func testStarringRetiresNudgeForGood() {
        for _ in 0..<StarNudge.captureThreshold { StarNudge.recordCapture() }
        StarNudge.markStarred()

        XCTAssertEqual(StarNudge.state, .starred)
        XCTAssertFalse(StarNudge.shouldShowInHistoryPanel)
        XCTAssertFalse(StarNudge.recordCapture())
    }

    func testUnknownStoredStateFallsBackToPending() {
        Settings.starNudgeState = "not-a-real-state"
        XCTAssertEqual(StarNudge.state, .pending)
    }
}
