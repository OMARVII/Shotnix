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

    // MARK: Video exports

    func testTheThirdFinishedExportAsksExactlyOnce() {
        XCTAssertEqual(Settings.videoExportCount, 0)
        for _ in 1..<StarNudge.exportThreshold {
            XCTAssertFalse(StarNudge.recordExport())
            XCTAssertEqual(StarNudge.state, .pending)
            XCTAssertFalse(StarNudge.shouldShowWithExports)
        }

        XCTAssertTrue(StarNudge.recordExport(), "the third finished export asks")
        XCTAssertEqual(StarNudge.state, .toastShown)
        XCTAssertTrue(StarNudge.shouldShowWithExports, "the line stays under finished exports")
        XCTAssertTrue(StarNudge.shouldShowInHistoryPanel, "and in History, like after the screenshot ask")

        XCTAssertFalse(StarNudge.recordExport(), "later exports never ask again")
        XCTAssertEqual(Settings.videoExportCount, StarNudge.exportThreshold + 1, "exports keep being counted")
        XCTAssertTrue(StarNudge.shouldShowWithExports, "unanswered, the line is still there")
    }

    func testWhicheverSideAsksFirstTheOtherNeverAsks() {
        for _ in 0..<StarNudge.exportThreshold { StarNudge.recordExport() }
        XCTAssertEqual(StarNudge.state, .toastShown)
        for _ in 0..<50 { XCTAssertFalse(StarNudge.recordCapture(), "no screenshot toast after the export ask") }

        Settings.starNudgeState = ""
        Settings.captureCount = 0
        Settings.videoExportCount = 0
        for _ in 0..<StarNudge.captureThreshold { StarNudge.recordCapture() }
        XCTAssertEqual(StarNudge.state, .toastShown)
        for _ in 0..<50 { XCTAssertFalse(StarNudge.recordExport(), "no export ask after the screenshot toast") }
    }

    func testTheScreenshotAskReachesExportsOnlyAfterThree() {
        for _ in 0..<StarNudge.captureThreshold { StarNudge.recordCapture() }
        XCTAssertFalse(StarNudge.shouldShowWithExports, "asked over screenshots, before any video")
        StarNudge.recordExport()
        StarNudge.recordExport()
        XCTAssertFalse(StarNudge.shouldShowWithExports)
        StarNudge.recordExport()
        XCTAssertTrue(StarNudge.shouldShowWithExports, "unanswered, it waits under the third finished export")
    }

    func testEitherAnswerRetiresTheExportLineForGood() {
        for _ in 0..<StarNudge.exportThreshold { StarNudge.recordExport() }
        StarNudge.markDismissed()
        XCTAssertFalse(StarNudge.shouldShowWithExports)
        XCTAssertFalse(StarNudge.shouldShowInHistoryPanel)
        for _ in 0..<50 { XCTAssertFalse(StarNudge.recordExport()) }
        XCTAssertEqual(StarNudge.state, .dismissed)

        Settings.starNudgeState = ""
        Settings.videoExportCount = 0
        for _ in 0..<StarNudge.exportThreshold { StarNudge.recordExport() }
        StarNudge.markStarred()
        XCTAssertFalse(StarNudge.shouldShowWithExports)
        XCTAssertFalse(StarNudge.recordExport())
        XCTAssertFalse(StarNudge.recordCapture())
        XCTAssertEqual(StarNudge.state, .starred)
    }

    func testUnknownStoredStateFallsBackToPending() {
        Settings.starNudgeState = "not-a-real-state"
        XCTAssertEqual(StarNudge.state, .pending)
    }
}
