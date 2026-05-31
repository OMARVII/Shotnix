import KeyboardShortcuts
import XCTest
@testable import ShotnixCore

final class ShotnixHealthModelTests: XCTestCase {
    func testRowsReportHealthyConfiguration() {
        let snapshot = ShotnixHealthSnapshot(
            screenRecordingGranted: true,
            nativeShortcutsEnabled: false,
            updatesConfigured: true,
            autoSavePath: "/tmp",
            autoSaveWritable: true,
            configuredShortcutCount: ShotnixShortcut.allCases.count,
            expectedShortcutCount: ShotnixShortcut.allCases.count,
            version: "0.16.0",
            build: "25"
        )

        let rows = ShotnixHealthModel.rows(snapshot: snapshot)

        XCTAssertEqual(Set(rows.map(\.kind)), Set(ShotnixHealthKind.allCases))
        XCTAssertEqual(ShotnixHealthModel.summary(snapshot: snapshot), .ok)
        XCTAssertEqual(rows.first(where: { $0.kind == .updates })?.detail, "Enabled")
        XCTAssertEqual(rows.first(where: { $0.kind == .version })?.detail, "0.16.0 (25)")
    }

    func testRowsReportFixableIssues() {
        let snapshot = ShotnixHealthSnapshot(
            screenRecordingGranted: false,
            nativeShortcutsEnabled: true,
            updatesConfigured: false,
            autoSavePath: "/missing",
            autoSaveWritable: false,
            configuredShortcutCount: 5,
            expectedShortcutCount: 7,
            version: "0.16.0",
            build: "25"
        )

        let rows = ShotnixHealthModel.rows(snapshot: snapshot)

        XCTAssertEqual(ShotnixHealthModel.summary(snapshot: snapshot), .issue)
        XCTAssertEqual(rows.first(where: { $0.kind == .screenRecording })?.actionTitle, "Fix")
        XCTAssertEqual(rows.first(where: { $0.kind == .nativeShortcuts })?.state, .warning)
        XCTAssertEqual(rows.first(where: { $0.kind == .autoSave })?.state, .issue)
        XCTAssertEqual(rows.first(where: { $0.kind == .shortcuts })?.detail, "5/7 configured")
    }

    func testAutoSaveWritableUsesRealFolders() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotnixHealthModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertTrue(ShotnixHealthSnapshot.isWritableAutoSavePath(directory.path))
        XCTAssertFalse(ShotnixHealthSnapshot.isWritableAutoSavePath(directory.appendingPathComponent("missing").path))
    }

    func testShortcutHealthCountsMissingShortcuts() {
        let configuredNames: Set<String> = [
            KeyboardShortcuts.Name.shotnixCaptureArea.rawValue,
            KeyboardShortcuts.Name.shotnixCaptureText.rawValue
        ]

        let count = ShotnixShortcut.configuredShortcutCount { name in
            configuredNames.contains(name.rawValue) ? KeyboardShortcuts.Shortcut(.a, modifiers: [.command]) : nil
        }

        XCTAssertEqual(ShotnixShortcut.allCases.count, 7)
        XCTAssertEqual(count, 2)
    }
}
