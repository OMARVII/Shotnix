import Foundation

// VideoEditor settings added after 0.23 live here, so work on each part of the app stays out of Settings.swift.
extension Settings {
    // MARK: – Editor features

    /// Draw the captions into exported videos (a subtitles file is separate).
    static var videoExportBurnCaptions: Bool {
        get {
            if defaults.object(forKey: "videoExportBurnCaptions") == nil { return true }
            return defaults.bool(forKey: "videoExportBurnCaptions")
        }
        set { defaults.set(newValue, forKey: "videoExportBurnCaptions") }
    }

    /// Subtitles saved next to each export: "" (none), "srt", or "vtt".
    static var videoExportSubtitles: String {
        get {
            let value = defaults.string(forKey: "videoExportSubtitles") ?? ""
            return ["srt", "vtt"].contains(value) ? value : ""
        }
        set { defaults.set(["srt", "vtt"].contains(newValue) ? newValue : "", forKey: "videoExportSubtitles") }
    }

    /// The language captions were last translated into (BCP-47).
    static var videoCaptionTranslationTarget: String {
        get { defaults.string(forKey: "videoCaptionTranslationTarget") ?? "" }
        set { defaults.set(newValue, forKey: "videoCaptionTranslationTarget") }
    }

    /// When leftover video data was last swept.
    static var videoDataLastSweep: Date? {
        get { defaults.object(forKey: "videoDataLastSweep") as? Date }
        set { defaults.set(newValue, forKey: "videoDataLastSweep") }
    }
}
