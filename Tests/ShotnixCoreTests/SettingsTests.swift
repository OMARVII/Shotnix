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
        XCTAssertTrue(Settings.openVideoEditorAfterRecording)
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

    func testResolvedLastRecordingFallsBackToNewestShotnixMP4() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertTrue(Settings.setAutoSaveLocation(dir.path))
        Settings.lastRecordingPath = dir.appendingPathComponent("missing.mp4").path

        let older = dir.appendingPathComponent("Shotnix 2026-01-01 at 10.00.00 AM.mp4")
        let newer = dir.appendingPathComponent("Shotnix 2026-01-01 at 10.01.00 AM.mp4")
        let ignored = dir.appendingPathComponent("Other.mp4")
        try Data([1]).write(to: older)
        try Data([2]).write(to: newer)
        try Data([3]).write(to: ignored)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 3600)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 7200)], ofItemAtPath: newer.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10_800)], ofItemAtPath: ignored.path)

        let resolved = try XCTUnwrap(Settings.resolvedLastRecordingURL)
        let expectedPath = newer.standardizedFileURL.path

        XCTAssertEqual(resolved.standardizedFileURL.path, expectedPath)
        XCTAssertEqual(URL(fileURLWithPath: Settings.lastRecordingPath).standardizedFileURL.path, expectedPath)
    }
}
