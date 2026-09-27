import AppKit
import XCTest
@testable import ShotnixCore

/// Restarting for a new language: the new Shotnix starts only once quitting
/// is certain, a cancelled quit leaves nothing behind, and the new one waits
/// for the old one to exit. `terminate` stands in for NSApp.terminate(_:),
/// which returns only when the quit is cancelled.
@MainActor
final class AppRelaunchTests: XCTestCase {
    func testTheNewShotnixStartsOnlyOnceQuittingIsCertain() throws {
        var launches: [NSWorkspace.OpenConfiguration] = []
        AppRelaunch.quitThenRelaunch {
            XCTAssertTrue(AppRelaunch.isRestarting)
            XCTAssertTrue(launches.isEmpty, "nothing starts while the quit can still be cancelled")
            // Nothing cancelled: NSApplication calls applicationWillTerminate, then exits.
            AppRelaunch.launchNewInstanceIfRestarting { launches.append($0) }
        }
        XCTAssertEqual(launches.count, 1)
        let configuration = try XCTUnwrap(launches.first)
        XCTAssertTrue(configuration.createsNewApplicationInstance, "a second process, not this one brought forward")
        XCTAssertEqual(configuration.arguments, ["--relaunched-from", String(ProcessInfo.processInfo.processIdentifier)])
    }

    func testACancelledQuitLeavesNoRestartBehind() {
        AppRelaunch.quitThenRelaunch {
            // Cancel or Keep Working: terminate returns and Shotnix keeps running.
        }
        XCTAssertFalse(AppRelaunch.isRestarting)
        var launched = false
        AppRelaunch.launchNewInstanceIfRestarting { _ in launched = true }
        XCTAssertFalse(launched, "a later quit stays a quit")
    }

    func testAnOrdinaryQuitDoesntRelaunch() {
        var launched = false
        AppRelaunch.launchNewInstanceIfRestarting { _ in launched = true }
        XCTAssertFalse(launched)
    }

    func testTheNewShotnixKnowsWhichOneItReplaces() {
        XCTAssertNil(AppRelaunch.previousInstance(in: ["/Applications/Shotnix.app/Contents/MacOS/Shotnix"]), "an ordinary launch")
        XCTAssertEqual(AppRelaunch.previousInstance(in: ["Shotnix", "--relaunched-from", "4242"]), 4242)
        XCTAssertNil(AppRelaunch.previousInstance(in: ["Shotnix", "--relaunched-from"]))
        XCTAssertNil(AppRelaunch.previousInstance(in: ["Shotnix", "--relaunched-from", "0"]), "never a process group")
        XCTAssertNil(AppRelaunch.previousInstance(in: ["Shotnix", "--relaunched-from", "Shotnix"]))
    }

    func testTheNewShotnixWaitsWhileThePreviousOneRuns() {
        let running = String(ProcessInfo.processInfo.processIdentifier)
        var start = Date()
        AppRelaunch.waitForPreviousInstance(in: ["Shotnix", "--relaunched-from", running], timeout: 0.3)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.3, "still running: waits until the timeout")

        start = Date()
        AppRelaunch.waitForPreviousInstance(in: ["Shotnix", "--relaunched-from", "99999999"], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "already gone: goes on at once")

        start = Date()
        AppRelaunch.waitForPreviousInstance(in: ["Shotnix"], timeout: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "an ordinary launch doesn't wait")
    }
}
