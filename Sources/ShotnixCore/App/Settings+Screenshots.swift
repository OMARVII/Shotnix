import Foundation

// Screenshots settings added after 0.23 live here, so work on each part of the app stays out of Settings.swift.
extension Settings {

    // MARK: – Capture & history

    /// Area selections capture the moment the mouse is released. Off: the
    /// selection stays adjustable (handles, arrow keys) until Return.
    /// Holding ⇧ while releasing flips this for a single capture.
    static var captureImmediatelyAfterSelecting: Bool {
        get {
            if defaults.object(forKey: "captureImmediatelyAfterSelecting") == nil { return true }
            return defaults.bool(forKey: "captureImmediatelyAfterSelecting")
        }
        set { defaults.set(newValue, forKey: "captureImmediatelyAfterSelecting") }
    }

    /// How long captures stay in History. Forever unless the user picks a
    /// limit — an update must never start deleting someone's history.
    static var historyRetention: HistoryRetention {
        get { HistoryRetention(rawValue: defaults.string(forKey: "historyRetention") ?? "") ?? .forever }
        set { defaults.set(newValue.rawValue, forKey: "historyRetention") }
    }

    /// Text recognition languages as comma-separated BCP-47 codes (a String
    /// so SwiftUI's @AppStorage can bind it). Empty = detect automatically.
    static var ocrLanguagesRaw: String {
        get { defaults.string(forKey: "ocrLanguages") ?? "" }
        set { defaults.set(newValue, forKey: "ocrLanguages") }
    }

    static var ocrLanguages: [String] {
        get {
            ocrLanguagesRaw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set { ocrLanguagesRaw = newValue.joined(separator: ",") }
    }

    /// Fast recognition trades small-text accuracy and language coverage for
    /// speed. Accurate is the default.
    static var ocrFastRecognition: Bool {
        get { defaults.bool(forKey: "ocrFastRecognition") }
        set { defaults.set(newValue, forKey: "ocrFastRecognition") }
    }

    /// Set once the ⌘⇧S / ⌘⇧O migration ran (see ShotnixShortcut).
    static var didMigrateLegacyToolShortcuts: Bool {
        get { defaults.bool(forKey: "didMigrateLegacyToolShortcuts") }
        set { defaults.set(newValue, forKey: "didMigrateLegacyToolShortcuts") }
    }

    /// True when this Mac ran Shotnix before this launch. The welcome window
    /// sets hasLaunchedBefore on first launch, so launch migrations must run
    /// before it shows.
    static var isExistingInstall: Bool {
        hasLaunchedBefore
            || defaults.object(forKey: "onboardingCompleted") != nil
            || captureCount > 0
    }

    /// Launch-time migrations for capture settings. Idempotent.
    static func migrateCaptureSettingsIfNeeded(webPSupported: Bool = ImageExporter.isWebPSupported) {
        // WebP was offered even where macOS can't encode it (every save
        // quietly became a PNG) — make the stored choice match reality.
        if screenshotFormat == "webp" && !webPSupported {
            screenshotFormat = "png"
        }
        ShotnixShortcut.migrateLegacyToolShortcutsIfNeeded()
    }
}
