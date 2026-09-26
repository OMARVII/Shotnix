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
            configuredShortcutCount: ShotnixShortcut.requiredShortcutCount,
            expectedShortcutCount: ShotnixShortcut.requiredShortcutCount,
            optionalUnassignedShortcutCount: 0,
            version: "0.16.0",
            build: "25"
        )

        let rows = ShotnixHealthModel.rows(snapshot: snapshot)

        XCTAssertEqual(Set(rows.map(\.kind)), Set(ShotnixHealthKind.allCases))
        XCTAssertEqual(ShotnixHealthModel.summary(snapshot: snapshot), .ok)
        XCTAssertEqual(rows.first(where: { $0.kind == .updates })?.detail, "Enabled")
        XCTAssertEqual(rows.first(where: { $0.kind == .version })?.detail, "0.16.0 (25)")
        XCTAssertEqual(rows.first(where: { $0.kind == .shortcuts })?.detail, "All configured")
    }

    func testUnassignedOptionalShortcutsAreHealthy() {
        let snapshot = ShotnixHealthSnapshot(
            screenRecordingGranted: true,
            nativeShortcutsEnabled: false,
            updatesConfigured: true,
            autoSavePath: "/tmp",
            autoSaveWritable: true,
            configuredShortcutCount: ShotnixShortcut.requiredShortcutCount,
            expectedShortcutCount: ShotnixShortcut.requiredShortcutCount,
            optionalUnassignedShortcutCount: 5,
            version: "0.20.2",
            build: "51"
        )

        let rows = ShotnixHealthModel.rows(snapshot: snapshot)
        let shortcuts = rows.first(where: { $0.kind == .shortcuts })

        XCTAssertEqual(ShotnixHealthModel.summary(snapshot: snapshot), .ok)
        XCTAssertEqual(shortcuts?.state, .ok)
        XCTAssertNil(shortcuts?.actionTitle)
        XCTAssertEqual(shortcuts?.detail, "Ready · 5 optional off")
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
            optionalUnassignedShortcutCount: 5,
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

    func testShortcutHealthCountsOnlyRequiredShortcuts() {
        let configuredNames: Set<String> = [
            KeyboardShortcuts.Name.shotnixCaptureArea.rawValue,
            KeyboardShortcuts.Name.shotnixCaptureWindow.rawValue,
            // Optional since 0.24 — assigned or not, it never affects health.
            KeyboardShortcuts.Name.shotnixCaptureText.rawValue
        ]

        let required = ShotnixShortcut.requiredConfiguredCount { name in
            configuredNames.contains(name.rawValue) ? KeyboardShortcuts.Shortcut(.a, modifiers: [.command]) : nil
        }
        let optionalOff = ShotnixShortcut.optionalUnassignedCount { _ in nil }

        XCTAssertEqual(ShotnixShortcut.allCases.count, 14)
        XCTAssertEqual(ShotnixShortcut.requiredShortcutCount, 5)
        XCTAssertEqual(required, 2)
        XCTAssertEqual(optionalOff, 9)
        XCTAssertFalse(ShotnixShortcut.captureArea.isOptional)
        XCTAssertTrue(ShotnixShortcut.recordArea.isOptional)
        XCTAssertTrue(ShotnixShortcut.stopRecording.isOptional)
        XCTAssertTrue(ShotnixShortcut.captureTimed.isOptional)
        XCTAssertTrue(ShotnixShortcut.captureText.isOptional)
        XCTAssertTrue(ShotnixShortcut.captureScrolling.isOptional)
        XCTAssertTrue(ShotnixShortcut.captureAllDisplays.isOptional)
    }
}
