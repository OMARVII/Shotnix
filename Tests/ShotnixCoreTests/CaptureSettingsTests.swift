import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Capture & history settings: fresh-install defaults, value handling, and
/// a render of the new Settings → Screenshots sections.
@MainActor
final class CaptureSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "ShotnixCoreTests.CaptureSettings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Settings.defaults = defaults
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        Settings.defaults = .standard
    }

    func testFreshInstallDefaults() {
        XCTAssertTrue(Settings.captureImmediatelyAfterSelecting, "release still captures by default")
        XCTAssertEqual(Settings.historyRetention, .forever)
        XCTAssertEqual(Settings.ocrLanguages, [])
        XCTAssertFalse(Settings.ocrFastRecognition)
        XCTAssertEqual(OCREngine.Options.current, OCREngine.Options(fast: false, languages: []))
    }

    func testOCRLanguagesRoundTrip() {
        Settings.ocrLanguages = ["en-US", "de-DE"]
        XCTAssertEqual(Settings.ocrLanguagesRaw, "en-US,de-DE")
        XCTAssertEqual(Settings.ocrLanguages, ["en-US", "de-DE"])
        Settings.ocrLanguagesRaw = " fr-FR , ,ja-JP"
        XCTAssertEqual(Settings.ocrLanguages, ["fr-FR", "ja-JP"])
        XCTAssertEqual(OCREngine.Options.current.languages, ["fr-FR", "ja-JP"])
    }

    func testUnknownRetentionValueFallsBackToForever() {
        defaults.set("15y", forKey: "historyRetention")
        XCTAssertEqual(Settings.historyRetention, .forever)
        Settings.historyRetention = .items500
        XCTAssertEqual(Settings.historyRetention.maxCount, 500)
        XCTAssertNil(Settings.historyRetention.maxAge)
    }

    func testRetentionOptionsCoverTheRequestedLimits() {
        XCTAssertEqual(HistoryRetention.allCases.compactMap(\.maxAge), [7, 30, 90].map { TimeInterval($0) * 86_400 })
        XCTAssertEqual(HistoryRetention.allCases.compactMap(\.maxCount), [100, 500, 1000])
        XCTAssertEqual(HistoryRetention.allCases.first, .forever)
    }

    func testRenderScreenshotsSettingsSections() async throws {
        _ = NSApplication.shared
        let sections = VStack(alignment: .leading, spacing: 18) {
            CaptureSelectionPreferences()
            TextRecognitionPreferences()
            HistoryPreferences()
        }
        .padding(22)
        .frame(width: 560, height: 560, alignment: .top)
        .background(Color(nsColor: ShotnixColors.editorStageTop))
        .environment(\.colorScheme, .dark)

        let host = NSHostingView(rootView: sections)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-capture-snapshots/settings-capture-sections.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT-SETTINGS: \(url.path)")
        window.orderOut(nil)
    }
}
