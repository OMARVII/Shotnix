import Foundation
import KeyboardShortcuts

enum ShotnixHealthKind: String, CaseIterable {
    case screenRecording
    case nativeShortcuts
    case updates
    case autoSave
    case shortcuts
    case version
}

enum ShotnixHealthState: String {
    case ok
    case warning
    case issue
    case info

    var isHealthy: Bool {
        switch self {
        case .ok, .info: return true
        case .warning, .issue: return false
        }
    }
}

struct ShotnixHealthRow: Identifiable, Equatable {
    let kind: ShotnixHealthKind
    let title: String
    let detail: String
    let symbolName: String
    let state: ShotnixHealthState
    let actionTitle: String?

    var id: String { kind.rawValue }
}

struct ShotnixHealthSnapshot: Equatable {
    let screenRecordingGranted: Bool
    let nativeShortcutsEnabled: Bool
    let updatesConfigured: Bool
    let autoSavePath: String
    let autoSaveWritable: Bool
    let configuredShortcutCount: Int
    let expectedShortcutCount: Int
    let version: String
    let build: String

    static func live(updatesConfigured: Bool = AppUpdateConfiguration.current != nil) -> ShotnixHealthSnapshot {
        let autoSavePath = Settings.autoSaveLocation
        return ShotnixHealthSnapshot(
            screenRecordingGranted: PermissionsManager.hasScreenRecordingPermission,
            nativeShortcutsEnabled: NativeShortcutManager.nativeShortcutsEnabled,
            updatesConfigured: updatesConfigured,
            autoSavePath: autoSavePath,
            autoSaveWritable: isWritableAutoSavePath(autoSavePath),
            configuredShortcutCount: ShotnixShortcut.configuredShortcutCount(),
            expectedShortcutCount: ShotnixShortcut.allCases.count,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.16.0",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "25"
        )
    }

    static func isWritableAutoSavePath(_ path: String, fileManager: FileManager = .default) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        return fileManager.isWritableFile(atPath: path)
    }
}

enum ShotnixHealthModel {
    static func rows(snapshot: ShotnixHealthSnapshot) -> [ShotnixHealthRow] {
        [
            screenRecordingRow(snapshot),
            nativeShortcutsRow(snapshot),
            updatesRow(snapshot),
            autoSaveRow(snapshot),
            shortcutsRow(snapshot),
            versionRow(snapshot)
        ]
    }

    static func summary(snapshot: ShotnixHealthSnapshot) -> ShotnixHealthState {
        let rows = rows(snapshot: snapshot).filter { $0.kind != .version }
        if rows.contains(where: { $0.state == .issue }) { return .issue }
        if rows.contains(where: { $0.state == .warning }) { return .warning }
        return .ok
    }

    private static func screenRecordingRow(_ snapshot: ShotnixHealthSnapshot) -> ShotnixHealthRow {
        ShotnixHealthRow(
            kind: .screenRecording,
            title: "Screen Recording",
            detail: snapshot.screenRecordingGranted ? "Ready" : "Permission needed",
            symbolName: snapshot.screenRecordingGranted ? "checkmark.shield" : "exclamationmark.triangle",
            state: snapshot.screenRecordingGranted ? .ok : .issue,
            actionTitle: snapshot.screenRecordingGranted ? nil : "Fix"
        )
    }

    private static func nativeShortcutsRow(_ snapshot: ShotnixHealthSnapshot) -> ShotnixHealthRow {
        ShotnixHealthRow(
            kind: .nativeShortcuts,
            title: "Apple Shortcuts",
            detail: snapshot.nativeShortcutsEnabled ? "Conflict detected" : "No conflict",
            symbolName: snapshot.nativeShortcutsEnabled ? "keyboard.badge.exclamationmark" : "keyboard",
            state: snapshot.nativeShortcutsEnabled ? .warning : .ok,
            actionTitle: snapshot.nativeShortcutsEnabled ? "Fix" : nil
        )
    }

    private static func updatesRow(_ snapshot: ShotnixHealthSnapshot) -> ShotnixHealthRow {
        ShotnixHealthRow(
            kind: .updates,
            title: "Updates",
            detail: snapshot.updatesConfigured ? "Enabled" : "Disabled",
            symbolName: snapshot.updatesConfigured ? "arrow.triangle.2.circlepath.circle" : "arrow.triangle.2.circlepath.circle.fill",
            state: snapshot.updatesConfigured ? .ok : .warning,
            actionTitle: snapshot.updatesConfigured ? "Check" : nil
        )
    }

    private static func autoSaveRow(_ snapshot: ShotnixHealthSnapshot) -> ShotnixHealthRow {
        ShotnixHealthRow(
            kind: .autoSave,
            title: "Save Folder",
            detail: snapshot.autoSaveWritable ? "Writable" : "Choose folder",
            symbolName: snapshot.autoSaveWritable ? "folder.badge.gearshape" : "folder.badge.questionmark",
            state: snapshot.autoSaveWritable ? .ok : .issue,
            actionTitle: snapshot.autoSaveWritable ? nil : "Fix"
        )
    }

    private static func shortcutsRow(_ snapshot: ShotnixHealthSnapshot) -> ShotnixHealthRow {
        let ready = snapshot.configuredShortcutCount == snapshot.expectedShortcutCount
        return ShotnixHealthRow(
            kind: .shortcuts,
            title: "Shortcuts",
            detail: ready ? "All configured" : "\(snapshot.configuredShortcutCount)/\(snapshot.expectedShortcutCount) configured",
            symbolName: ready ? "command.circle" : "command.circle.fill",
            state: ready ? .ok : .warning,
            actionTitle: ready ? nil : "Fix"
        )
    }

    private static func versionRow(_ snapshot: ShotnixHealthSnapshot) -> ShotnixHealthRow {
        ShotnixHealthRow(
            kind: .version,
            title: "Version",
            detail: "\(snapshot.version) (\(snapshot.build))",
            symbolName: "info.circle",
            state: .info,
            actionTitle: nil
        )
    }
}

extension ShotnixShortcut {
    static func configuredShortcutCount(getShortcut: (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut? = KeyboardShortcuts.getShortcut) -> Int {
        allCases.reduce(0) { count, shortcut in
            getShortcut(shortcut.name) == nil ? count : count + 1
        }
    }
}
