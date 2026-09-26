import Foundation

// VideoEditor settings added after 0.23 live here, so work on each part of the app stays out of Settings.swift.
extension Settings {}

extension Settings {
    // MARK: – Editor

    /// Recordings (by path) whose "transcribe for captions" suggestion was
    /// waved away — newest last, only the latest few hundred kept.
    static var videoTranscribeHintDismissed: [String] {
        get { defaults.stringArray(forKey: "videoTranscribeHintDismissed") ?? [] }
        set { defaults.set(Array(newValue.suffix(200)), forKey: "videoTranscribeHintDismissed") }
    }

    /// Which page of editor tips shows next (they take turns).
    static var videoEditorTipPage: Int {
        get { defaults.integer(forKey: "videoEditorTipPage") }
        set { defaults.set(newValue, forKey: "videoEditorTipPage") }
    }
}
