import XCTest
@testable import ShotnixCore

/// The crash prompt asks only after a real crash (or macOS closing Shotnix for
/// memory), reads macOS's reports correctly, and never sends a home folder.
final class CrashReporterTests: XCTestCase {
    private let bundleID = "com.shotnix.app"

    /// A crash report the way macOS writes it: a line of JSON, then the crash.
    private func report(bundle: String = "com.shotnix.app", bugType: String = "309", timestamp: String = "2026-10-04 12:59:42.00 +0200", incident: String = "A0BE2FB3") -> String {
        let header: [String: Any] = [
            "app_name": "Shotnix", "timestamp": timestamp, "app_version": "0.26.3", "build_version": "67",
            "bug_type": bugType, "os_version": "macOS 26.2 (25C56)", "incident_id": incident, "name": "Shotnix", "bundleID": bundle,
        ]
        let body: [String: Any] = [
            "procPath": "/Applications/Shotnix.app/Contents/MacOS/Shotnix",
            "modelCode": "Mac16,8",
            "osVersion": ["train": "macOS 26.2", "build": "25C56", "releaseType": "User"],
            "bundleInfo": ["CFBundleShortVersionString": "0.26.3", "CFBundleVersion": "67", "CFBundleIdentifier": bundle],
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"],
            "termination": ["namespace": "SIGNAL", "indicator": "Segmentation fault: 11"],
            "asi": ["libswiftCore.dylib": ["Fatal error: Index out of range"]],
            "faultingThread": 0,
            "threads": [["triggered": true, "frames": [
                ["imageIndex": 0, "imageOffset": 4_242, "symbol": "VideoExporter.writeNextVideoFrame()", "symbolLocation": 120],
                ["imageIndex": 1, "imageOffset": 6_699],
            ]]],
            "usedImages": [["name": "ShotnixCore", "path": "\(NSHomeDirectory())/Shotnix.app/ShotnixCore"], ["name": "libswiftCore.dylib"]],
        ]
        let encode = { (object: Any) in String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        return encode(header) + "\n" + encode(body)
    }

    func testReadsAShotnixCrash() throws {
        let parsed = try XCTUnwrap(CrashReportFile.parse(report(), url: URL(fileURLWithPath: "/tmp/Shotnix-1.ips"), bundleID: bundleID))
        XCTAssertEqual(parsed.incident, "A0BE2FB3")
        XCTAssertEqual(parsed.appVersion, "0.26.3")
        XCTAssertEqual(parsed.build, "67")
        XCTAssertEqual(parsed.osVersion, "macOS 26.2 (25C56)")
        XCTAssertEqual(parsed.model, "Mac16,8")
        XCTAssertEqual(parsed.exception, "EXC_BAD_ACCESS (SIGSEGV)")
        XCTAssertEqual(parsed.frames, ["ShotnixCore  VideoExporter.writeNextVideoFrame() + 120", "libswiftCore.dylib  0x1a2b"])
        XCTAssertTrue(parsed.messages.contains("Fatal error: Index out of range"))
        XCTAssertTrue(parsed.messages.contains("Segmentation fault: 11"))
        XCTAssertEqual(parsed.date, CrashReportFile.parseDate("2026-10-04 12:59:42.00 +0200"))
        XCTAssertFalse(parsed.text.contains(NSHomeDirectory()), "the home folder never leaves the Mac")
    }

    func testIgnoresOtherAppsHangsAndJunk() {
        let url = URL(fileURLWithPath: "/tmp/x.ips")
        XCTAssertNil(CrashReportFile.parse(report(bundle: "com.other.app"), url: url, bundleID: bundleID))
        XCTAssertNil(CrashReportFile.parse(report(bugType: "288"), url: url, bundleID: bundleID), "a hang isn't a crash")
        XCTAssertNil(CrashReportFile.parse("not a report", url: url, bundleID: bundleID))
    }

    func testFindsOnlyShotnixCrashesNewerThanTheLastLaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crash-reports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let since = try XCTUnwrap(CrashReportFile.parseDate("2026-10-04 12:00:00.00 +0200"))
        func write(_ name: String, _ text: String, modified: Date) throws {
            let url = folder.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        try write("Shotnix-old.ips", report(timestamp: "2026-10-03 09:00:00.00 +0200", incident: "old"), modified: since.addingTimeInterval(-86_400))
        try write("Shotnix-new.ips", report(timestamp: "2026-10-04 12:59:42.00 +0200", incident: "new"), modified: since.addingTimeInterval(3_600))
        try write("Shotnix-newer.ips", report(timestamp: "2026-10-04 13:30:00.00 +0200", incident: "newer"), modified: since.addingTimeInterval(5_400))
        try write("Shotnix-hang.ips", report(bugType: "288", incident: "hang"), modified: since.addingTimeInterval(3_600))
        try write("node-2026.ips", report(bundle: "org.nodejs", incident: "node"), modified: since.addingTimeInterval(3_600))

        let found = CrashReportFile.find(in: folder, since: since, bundleID: bundleID)
        XCTAssertEqual(found.map(\.incident), ["newer", "new"])
    }

    // MARK: When to ask

    private func session(ended: Bool, boot: TimeInterval = 1_000, peak: UInt64 = 500_000_000) -> CrashSession {
        CrashSession(started: Date(), bootTime: boot, peakFootprint: peak, version: "0.26.3 (67)", ended: ended)
    }

    func testAsksAfterACrashReport() throws {
        let crash = try XCTUnwrap(CrashReportFile.parse(report(), url: URL(fileURLWithPath: "/tmp/a.ips"), bundleID: bundleID))
        let reason = CrashPromptReason.decide(previous: session(ended: false), reports: [crash], bootTime: 1_000, physicalMemory: 16_000_000_000)
        XCTAssertEqual(reason, .crash(crash))
    }

    func testNeverAsksAfterANormalQuitAForceQuitOrARestart() {
        let memory: UInt64 = 16_000_000_000
        XCTAssertNil(CrashPromptReason.decide(previous: nil, reports: [], bootTime: 1_000, physicalMemory: memory), "first launch")
        XCTAssertNil(CrashPromptReason.decide(previous: session(ended: true, peak: 40_000_000_000), reports: [], bootTime: 1_000, physicalMemory: memory), "quit normally")
        XCTAssertNil(CrashPromptReason.decide(previous: session(ended: false), reports: [], bootTime: 1_000, physicalMemory: memory), "force quit at normal memory")
        XCTAssertNil(CrashPromptReason.decide(previous: session(ended: false, boot: 500, peak: 40_000_000_000), reports: [], bootTime: 1_000, physicalMemory: memory), "the Mac restarted or lost power")
    }

    func testAsksWhenMacOSClosedShotnixForMemory() {
        let reason = CrashPromptReason.decide(previous: session(ended: false, peak: 77_000_000_000), reports: [], bootTime: 1_000.5, physicalMemory: 36_000_000_000)
        XCTAssertEqual(reason, .outOfMemory(peak: 77_000_000_000, physical: 36_000_000_000, version: "0.26.3 (67)"))
    }

    func testTheMemoryBarScalesWithTheMac() {
        XCTAssertEqual(CrashPromptReason.memoryThreshold(physicalMemory: 8_000_000_000), 6_000_000_000)
        XCTAssertEqual(CrashPromptReason.memoryThreshold(physicalMemory: 64_000_000_000), 48_000_000_000)
    }

    // MARK: What gets sent

    func testHidesTheHomeFolderAndAccountName() {
        let text = "/Users/alice/Library/Shotnix crashed for alice"
        XCTAssertEqual(CrashReportFile.redacted(text, home: "/Users/alice", user: "alice"), "~/Library/Shotnix crashed for user")
    }

    func testIssueAndMailLinksStayShortEnoughToOpen() throws {
        var crash = try XCTUnwrap(CrashReportFile.parse(report(), url: URL(fileURLWithPath: "/tmp/a.ips"), bundleID: bundleID))
        crash = CrashReportFile(url: crash.url, incident: crash.incident, date: crash.date, appVersion: crash.appVersion, build: crash.build, osVersion: crash.osVersion,
                                model: crash.model, exception: crash.exception, messages: Array(repeating: String(repeating: "m", count: 3_000), count: 5),
                                frames: Array(repeating: "ShotnixCore  " + String(repeating: "VeryLongSymbolName.", count: 40), count: 16), text: crash.text)
        let summary = CrashReportSummary(reason: .crash(crash))
        let issue = try XCTUnwrap(summary.issueURL(base: CrashReporter.issuesURL))
        XCTAssertLessThan(issue.absoluteString.count, 8_000, "GitHub refuses very long links")
        XCTAssertTrue(issue.absoluteString.hasPrefix("https://github.com/OMARVII/Shotnix/issues/new?title="))
        let mail = try XCTUnwrap(summary.mailtoURL(to: CrashReporter.supportEmail))
        XCTAssertTrue(mail.absoluteString.hasPrefix("mailto:support@shotnix.com?subject="))
        XCTAssertTrue(summary.fullText.contains("----- macOS crash report -----"))
    }

    func testMemoryKillSummary() {
        let summary = CrashReportSummary(reason: .outOfMemory(peak: 77_000_000_000, physical: 36_000_000_000, version: "0.26.3 (67)"))
        XCTAssertEqual(summary.subject, "Shotnix 0.26.3 (67) ran out of memory")
        XCTAssertTrue(summary.details.contains("77.0 GB"))
        XCTAssertTrue(summary.details.contains("36.0 GB"))
    }

    /// Opt-in: SHOTNIX_CRASH_REPORT=/path/to/Shotnix-….ips swift test --filter CrashReporterTests
    /// reads a real crash report and prints what each button would send.
    func testReadsARealCrashReport() throws {
        guard let path = ProcessInfo.processInfo.environment["SHOTNIX_CRASH_REPORT"] else { throw XCTSkip("Set SHOTNIX_CRASH_REPORT") }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let crash = try XCTUnwrap(CrashReportFile.parse(text, url: URL(fileURLWithPath: path), bundleID: bundleID), "not one of Shotnix's crashes")
        XCTAssertFalse(crash.frames.isEmpty, "the crashed thread")
        XCTAssertFalse(crash.text.contains(NSHomeDirectory()))
        let summary = CrashReportSummary(reason: .crash(crash))
        print("SUBJECT: \(summary.subject)")
        print("BODY:\n\(summary.emailBody)")
        let issue = try XCTUnwrap(summary.issueURL(base: CrashReporter.issuesURL))
        print("ISSUE URL (\(issue.absoluteString.count) chars): \(issue.absoluteString.prefix(160))…")
        XCTAssertLessThan(issue.absoluteString.count, 8_000)
    }

    /// Opt-in: SHOTNIX_SNAPSHOT_DIR=/path swift test --filter CrashReporterTests
    /// draws the alert in each language, to check nothing is cut off.
    @MainActor
    func testSnapshotTheAlert() throws {
        guard let path = ProcessInfo.processInfo.environment["SHOTNIX_SNAPSHOT_DIR"] else { throw XCTSkip("Set SHOTNIX_SNAPSHOT_DIR") }
        let crash = try XCTUnwrap(CrashReportFile.parse(report(), url: URL(fileURLWithPath: "/tmp/a.ips"), bundleID: bundleID))
        defer { L10n.use(nil) }
        for language in ["en", "de", "fr", "zh-Hans", "ru", "uk"] {
            L10n.use(language == "en" ? nil : language)
            for (name, reason) in [("crash", CrashPromptReason.crash(crash)), ("memory", .outOfMemory(peak: 77_000_000_000, physical: 36_000_000_000, version: "0.26.3"))] {
                let alert = CrashReporter.makeAlert(for: reason)
                alert.layout()
                let view = try XCTUnwrap(alert.window.contentView)
                let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = URL(fileURLWithPath: path).appendingPathComponent("crash-alert-\(language)-\(name).png")
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
            }
        }
    }

    @MainActor
    func testANormalQuitIsRemembered() throws {
        let suite = "CrashReporterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        CrashReporter.startSession(defaults: defaults)
        XCTAssertEqual(CrashSession.load(from: defaults, key: "crashReporterSession")?.ended, false)
        CrashReporter.endSession()
        XCTAssertEqual(CrashSession.load(from: defaults, key: "crashReporterSession")?.ended, true)
        XCTAssertGreaterThan(CrashSession.currentBootTime, 0)
        XCTAssertGreaterThan(CrashSession.currentFootprint, 0)
    }
}
