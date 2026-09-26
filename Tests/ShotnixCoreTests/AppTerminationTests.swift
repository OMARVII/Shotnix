import XCTest
@testable import ShotnixCore

@MainActor
final class AppTerminationTests: XCTestCase {
    func testFinishAllWaitsForEveryPieceOfWork() {
        var finished: [String] = []
        var completed = false
        var recordingDone: (@MainActor () -> Void)?
        _ = AppTermination.begin("Recording") { done in
            finished.append("recording")
            recordingDone = done
        }
        _ = AppTermination.begin("Exporting", asksBeforeQuit: true) { done in
            finished.append("export")
            done()
        }
        XCTAssertTrue(AppTermination.isBusy)
        XCTAssertTrue(AppTermination.asksBeforeQuit)
        XCTAssertEqual(AppTermination.descriptions, ["Exporting", "Recording"])

        AppTermination.finishAll { completed = true }
        XCTAssertEqual(Set(finished), ["recording", "export"])
        XCTAssertFalse(completed, "still waiting for the recording to save")

        recordingDone?()
        XCTAssertTrue(completed)
        XCTAssertFalse(AppTermination.isBusy)
    }

    func testWhenIdleRunsOnceWorkEndsOnItsOwn() {
        var idle = false
        let token = AppTermination.begin("Transcribing") { _ in XCTFail("whenIdle never asks work to stop") }
        AppTermination.whenIdle { idle = true }
        XCTAssertFalse(idle)
        AppTermination.end(token)
        XCTAssertTrue(idle)

        var immediate = false
        AppTermination.whenIdle { immediate = true }
        XCTAssertTrue(immediate)
    }
}
