import Foundation

/// Central UserDefaults store for all user-configurable settings.
enum Settings {

    static var defaults = UserDefaults.standard
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

    /// True once the setup checklist is done — either the user took their
    /// first screenshot or explicitly skipped setup. Until then the welcome
    /// checklist reappears on every launch.
    static var onboardingCompleted: Bool {
        get { defaults.bool(forKey: "onboardingCompleted") }
        set { defaults.set(newValue, forKey: "onboardingCompleted") }
    }

    /// One-time migration: users who finished the old single-screen welcome
    /// flow (any button set hasLaunchedBefore) must not see the new checklist.
    static func migrateOnboardingFlagIfNeeded() {
        guard defaults.object(forKey: "onboardingCompleted") == nil else { return }
        if hasLaunchedBefore {
            onboardingCompleted = true
        }
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

    /// Window captures are isolated (no overlapping windows) and, with this
    /// on, composited over transparent padding with a soft drop shadow.
    static var windowCaptureShadow: Bool {
        get {
            if defaults.object(forKey: "windowCaptureShadow") == nil { return true }
            return defaults.bool(forKey: "windowCaptureShadow")
        }
        set { defaults.set(newValue, forKey: "windowCaptureShadow") }
    }

    /// Countdown length for Timed Capture. Clamped to the offered choices.
    static var timedCaptureDelaySeconds: Int {
        get {
            let v = defaults.integer(forKey: "timedCaptureDelaySeconds")
            return [3, 5, 10].contains(v) ? v : 5
        }
        set { defaults.set([3, 5, 10].contains(newValue) ? newValue : 5, forKey: "timedCaptureDelaySeconds") }
    }

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

    /// Default filename template — renders to the historical
    /// "Shotnix 2026-04-12 at 10.30.48" naming.
    static let defaultFilenameTemplate = "Shotnix %y-%m-%d at %H.%M.%S"

    /// Filename template for screenshots, recordings, and drag exports.
    /// Tokens: %y year, %m month, %d day, %H hour, %M minute, %S second,
    /// %% literal percent. Rendering lives in ImageExporter.
    static var filenameTemplate: String {
        get {
            let v = defaults.string(forKey: "filenameTemplate") ?? ""
            return v.trimmingCharacters(in: .whitespaces).isEmpty ? defaultFilenameTemplate : v
        }
        set { defaults.set(newValue, forKey: "filenameTemplate") }
    }

    // MARK: – Recording

    /// 60 unless someone picked 30: the editor exports at 60 fps, and a 30 fps
    /// recording would leave scrolling and animations at half that.
    static var recordingFPS: Int {
        get {
            let value = defaults.integer(forKey: "recordingFPS")
            return value == 30 ? 30 : 60
        }
        set { defaults.set(newValue == 30 ? 30 : 60, forKey: "recordingFPS") }
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

    /// Record the pointer as data instead of pixels so the video editor can
    /// redraw it smoothed, resized, and crisp at any zoom. On by default;
    /// off bakes the system cursor into the raw file like a plain recorder.
    static var recordingEditableCursor: Bool {
        get {
            if defaults.object(forKey: "recordingEditableCursor") == nil { return true }
            return defaults.bool(forKey: "recordingEditableCursor")
        }
        set { defaults.set(newValue, forKey: "recordingEditableCursor") }
    }

    /// Record keyboard shortcuts (⌘/⌃/⌥ combos, never plain typing) so the
    /// editor can show them. Needs the Accessibility permission.
    static var recordingKeystrokes: Bool {
        get { defaults.bool(forKey: "recordingKeystrokes") }
        set { defaults.set(newValue, forKey: "recordingKeystrokes") }
    }

    /// Language for generated captions (BCP-47; empty = the Mac's language).
    static var videoCaptionLanguage: String {
        get { defaults.string(forKey: "videoCaptionLanguage") ?? "" }
        set { defaults.set(newValue, forKey: "videoCaptionLanguage") }
    }

    /// Record the camera alongside the screen.
    static var recordingCamera: Bool {
        get { defaults.bool(forKey: "recordingCamera") }
        set { defaults.set(newValue, forKey: "recordingCamera") }
    }

    static var recordingCameraDeviceID: String {
        get { defaults.string(forKey: "recordingCameraDeviceID") ?? "" }
        set { defaults.set(newValue, forKey: "recordingCameraDeviceID") }
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

    static var openVideoEditorAfterRecording: Bool {
        get {
            if defaults.object(forKey: "openVideoEditorAfterRecording") == nil { return true }
            return defaults.bool(forKey: "openVideoEditorAfterRecording")
        }
        set { defaults.set(newValue, forKey: "openVideoEditorAfterRecording") }
    }

    static var lastRecordingPath: String {
        get { defaults.string(forKey: "lastRecordingPath") ?? "" }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: "lastRecordingPath")
            } else {
                defaults.set(newValue, forKey: "lastRecordingPath")
            }
        }
    }

    static var lastRecordingURL: URL? {
        let path = lastRecordingPath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static var latestRecordingURL: URL? {
        let directories = Array(Set([
            autoSaveLocation,
            defaultAutoSaveLocation,
        ]))

        return directories
            .compactMap { latestRecordingURL(in: URL(fileURLWithPath: $0, isDirectory: true)) }
            .max { lhs, rhs in
                modificationDate(for: lhs) < modificationDate(for: rhs)
            }
    }

    static var resolvedLastRecordingURL: URL? {
        if let lastRecordingURL {
            return lastRecordingURL
        }
        guard let latestRecordingURL else { return nil }
        lastRecordingPath = latestRecordingURL.path
        return latestRecordingURL
    }

    private static func latestRecordingURL(in directory: URL) -> URL? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        // The actual last-recording URL is persisted via lastRecordingPath when
        // a recording finishes; this fallback is best-effort recovery. Match the
        // legacy "Shotnix " prefix plus the current template's static leading
        // segment so unrelated .mp4 files in the save folder (e.g. downloads)
        // are never mistaken for a Shotnix recording. If the template starts
        // with a token (no static prefix), the fallback simply finds nothing.
        let templatePrefix = String(filenameTemplate.prefix(while: { $0 != "%" })).trimmingCharacters(in: .whitespaces)
        return urls
            .filter { url in
                guard url.pathExtension.lowercased() == "mp4" else { return false }
                let name = url.lastPathComponent
                return name.hasPrefix("Shotnix ")
                    || (!templatePrefix.isEmpty && name.hasPrefix(templatePrefix))
            }
            .filter { url in
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .max { lhs, rhs in
                modificationDate(for: lhs) < modificationDate(for: rhs)
            }
    }

    private static func modificationDate(for url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: – GitHub star nudge

    /// Successful screenshots taken on this Mac. Drives the one-time star nudge (see StarNudge).
    static var captureCount: Int {
        get { defaults.integer(forKey: "captureCount") }
        set { defaults.set(newValue, forKey: "captureCount") }
    }

    /// Raw `StarNudge.State`. Empty until the nudge machinery first runs.
    static var starNudgeState: String {
        get { defaults.string(forKey: "starNudgeState") ?? "" }
        set { defaults.set(newValue, forKey: "starNudgeState") }
    }

    // MARK: – Video export

    /// "mp4" or "gif" — last format chosen in the export save panel.
    static var videoExportFormat: String {
        get { defaults.string(forKey: "videoExportFormat") ?? "mp4" }
        set { defaults.set(newValue == "gif" ? "gif" : "mp4", forKey: "videoExportFormat") }
    }

    /// 24, 30, or 60 — defaults to 60 for silky screen motion.
    static var videoExportFPS: Int {
        get {
            let v = defaults.integer(forKey: "videoExportFPS")
            return [24, 30, 60].contains(v) ? v : 60
        }
        set { defaults.set([24, 30, 60].contains(newValue) ? newValue : 60, forKey: "videoExportFPS") }
    }

    static var videoExportHalfResolution: Bool {
        get { defaults.bool(forKey: "videoExportHalfResolution") }
        set { defaults.set(newValue, forKey: "videoExportHalfResolution") }
    }

    /// Appends the short "Made with Shotnix" outro to MP4 exports.
    static var videoExportEndCard: Bool {
        get {
            if defaults.object(forKey: "videoExportEndCard") == nil { return true }
            return defaults.bool(forKey: "videoExportEndCard")
        }
        set { defaults.set(newValue, forKey: "videoExportEndCard") }
    }

    /// Auto-generate click-following zooms when a fresh recording opens in the
    /// video editor (the recording feels "produced" with zero editing).
    static var autoZoomNewRecordings: Bool {
        get {
            if defaults.object(forKey: "autoZoomNewRecordings") == nil { return true }
            return defaults.bool(forKey: "autoZoomNewRecordings")
        }
        set { defaults.set(newValue, forKey: "autoZoomNewRecordings") }
    }

    // MARK: – Annotation editor

    /// Raw value of the last-used annotation tool (AnnotationTool.rawValue).
    static var annotationLastTool: String {
        get { defaults.string(forKey: "annotationLastTool") ?? "arrow" }
        set { defaults.set(newValue, forKey: "annotationLastTool") }
    }

    /// Last-used annotation line width in points. 0 = never set, so fall back to 3.
    static var annotationLastLineWidth: Double {
        get {
            let v = defaults.double(forKey: "annotationLastLineWidth")
            return v == 0 ? 3 : v
        }
        set { defaults.set(newValue, forKey: "annotationLastLineWidth") }
    }

    /// Last-used annotation color as archived NSColor data (secure coding).
    /// Archiving/unarchiving lives in the annotation editor so this file stays AppKit-free.
    static var annotationLastColorData: Data? {
        get { defaults.data(forKey: "annotationLastColorData") }
        set {
            if let newValue {
                defaults.set(newValue, forKey: "annotationLastColorData")
            } else {
                defaults.removeObject(forKey: "annotationLastColorData")
            }
        }
    }
}
