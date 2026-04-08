import Foundation

/// Central UserDefaults store for all user-configurable settings.
enum Settings {

    private static let defaults = UserDefaults.standard

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
            let v = defaults.string(forKey: "autoSaveLocation") ?? ""
            return v.isEmpty ? ("~/Desktop" as NSString).expandingTildeInPath : v
        }
        set { defaults.set(newValue, forKey: "autoSaveLocation") }
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
