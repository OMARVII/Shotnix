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

    // MARK: – Overlay

    /// Auto-dismiss timeout in seconds. -1 = never dismiss automatically.
    static var overlayTimeout: Double {
        get {
            let v = defaults.double(forKey: "overlayTimeout")
            return v == 0 ? 6 : v
        }
        set { defaults.set(newValue, forKey: "overlayTimeout") }
    }

    /// true = show overlay on the left side, false = right side (default)
    static var overlayOnLeft: Bool {
        get { defaults.bool(forKey: "overlayOnLeft") }
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
        get { defaults.bool(forKey: "afterCaptureCopyToClipboard") }
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
}
