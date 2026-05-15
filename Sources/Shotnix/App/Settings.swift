import Foundation

/// Central UserDefaults store for all user-configurable settings.
enum Settings {

    private static let defaults = UserDefaults.standard
    private static let autoSaveLocationKey = "autoSaveLocation"

    static var defaultAutoSaveLocation: String {
        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            return desktop.path
        }
        return ("~/Desktop" as NSString).expandingTildeInPath
    }

    // MARK: – First Launch

    static var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: "hasLaunchedBefore") }
        set { defaults.set(newValue, forKey: "hasLaunchedBefore") }
    }

    static var didRequestScreenRecordingPermission: Bool {
        get { defaults.bool(forKey: "didRequestScreenRecordingPermission") }
        set { defaults.set(newValue, forKey: "didRequestScreenRecordingPermission") }
    }

    static var didConfirmScreenRecordingPermission: Bool {
        get { defaults.bool(forKey: "didConfirmScreenRecordingPermission") }
        set { defaults.set(newValue, forKey: "didConfirmScreenRecordingPermission") }
    }

    static var didShowReadyToast: Bool {
        get { defaults.bool(forKey: "didShowReadyToast") }
        set { defaults.set(newValue, forKey: "didShowReadyToast") }
    }

    // MARK: – Overlay

    /// Auto-dismiss timeout in seconds. -1 = never dismiss automatically.
    static var overlayTimeout: Double {
        get {
            let v = defaults.double(forKey: "overlayTimeout")
            return v == 0 ? 6 : v
        }
        set { defaults.set(newValue, forKey: "overlayTimeout") }
    }

    /// true = show overlay on the left side (default), false = right side
    static var overlayOnLeft: Bool {
        get {
            if defaults.object(forKey: "overlayOnLeft") == nil { return true }
            return defaults.bool(forKey: "overlayOnLeft")
        }
        set { defaults.set(newValue, forKey: "overlayOnLeft") }
    }

    // MARK: – General

    static var playSounds: Bool {
        get {
            if defaults.object(forKey: "playSounds") == nil { return true }
            return defaults.bool(forKey: "playSounds")
        }
        set { defaults.set(newValue, forKey: "playSounds") }
    }

    static var showMenuBarIcon: Bool {
        get {
            if defaults.object(forKey: "showMenuBarIcon") == nil { return true }
            return defaults.bool(forKey: "showMenuBarIcon")
        }
        set { defaults.set(newValue, forKey: "showMenuBarIcon") }
    }

    static var hideDesktopIconsWhileCapturing: Bool {
        get { defaults.bool(forKey: "hideDesktopIconsWhileCapturing") }
        set { defaults.set(newValue, forKey: "hideDesktopIconsWhileCapturing") }
    }

    // MARK: – After Capture

    static var afterCaptureShowOverlay: Bool {
        get {
            if defaults.object(forKey: "afterCaptureShowOverlay") == nil { return true }
            return defaults.bool(forKey: "afterCaptureShowOverlay")
        }
        set { defaults.set(newValue, forKey: "afterCaptureShowOverlay") }
    }

    static var afterCaptureCopyToClipboard: Bool {
        get {
            if defaults.object(forKey: "afterCaptureCopyToClipboard") == nil { return true }
            return defaults.bool(forKey: "afterCaptureCopyToClipboard")
        }
        set { defaults.set(newValue, forKey: "afterCaptureCopyToClipboard") }
    }

    static var afterCaptureSaveAutomatically: Bool {
        get { defaults.bool(forKey: "afterCaptureSaveAutomatically") }
        set { defaults.set(newValue, forKey: "afterCaptureSaveAutomatically") }
    }

    static var autoSaveLocation: String {
        get {
            let v = defaults.string(forKey: autoSaveLocationKey) ?? ""
            guard !v.isEmpty else { return defaultAutoSaveLocation }
            return normalizedWritableDirectoryPath(v) ?? defaultAutoSaveLocation
        }
        set { _ = setAutoSaveLocation(newValue) }
    }

    @discardableResult
    static func setAutoSaveLocation(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            defaults.removeObject(forKey: autoSaveLocationKey)
            return true
        }
        guard let normalized = normalizedWritableDirectoryPath(trimmed) else { return false }
        defaults.set(normalized, forKey: autoSaveLocationKey)
        return true
    }

    private static func normalizedWritableDirectoryPath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        guard !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }

        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else { return nil }
        return url.path
    }

    // MARK: – Screenshots

    static var screenshotFormat: String {
        get { defaults.string(forKey: "screenshotFormat") ?? "png" }
        set { defaults.set(newValue, forKey: "screenshotFormat") }
    }

    static var jpegQuality: Double {
        get {
            let v = defaults.double(forKey: "jpegQuality")
            return v == 0 ? 0.95 : v
        }
        set { defaults.set(newValue, forKey: "jpegQuality") }
    }

    // MARK: – Recording

    static var recordingFPS: Int {
        get {
            let value = defaults.integer(forKey: "recordingFPS")
            return value == 60 ? 60 : 30
        }
        set { defaults.set(newValue == 60 ? 60 : 30, forKey: "recordingFPS") }
    }

    static var recordingQuality: String {
        get {
            let value = defaults.string(forKey: "recordingQuality") ?? "high"
            return ["balanced", "high", "max"].contains(value) ? value : "high"
        }
        set {
            let value = ["balanced", "high", "max"].contains(newValue) ? newValue : "high"
            defaults.set(value, forKey: "recordingQuality")
        }
    }

    static var recordingShowsCursor: Bool {
        get {
            if defaults.object(forKey: "recordingShowsCursor") == nil { return true }
            return defaults.bool(forKey: "recordingShowsCursor")
        }
        set { defaults.set(newValue, forKey: "recordingShowsCursor") }
    }

    static var recordingSystemAudio: Bool {
        get { defaults.bool(forKey: "recordingSystemAudio") }
        set { defaults.set(newValue, forKey: "recordingSystemAudio") }
    }

    static var recordingMicrophone: Bool {
        get { defaults.bool(forKey: "recordingMicrophone") }
        set { defaults.set(newValue, forKey: "recordingMicrophone") }
    }

    static var recordingMicrophoneDeviceID: String {
        get { defaults.string(forKey: "recordingMicrophoneDeviceID") ?? "" }
        set { defaults.set(newValue, forKey: "recordingMicrophoneDeviceID") }
    }
}
