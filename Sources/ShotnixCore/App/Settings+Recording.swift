import Foundation

// Recording settings added after 0.23 live here, so work on each part of the app stays out of Settings.swift.
extension Settings {
    static let recordingCountdownChoices = [0, 3, 5, 10]

    /// Seconds of countdown between pressing Record and the recording
    /// starting; 0 = start right away.
    static var recordingCountdownSeconds: Int {
        get {
            let value = defaults.integer(forKey: "recordingCountdownSeconds")
            return recordingCountdownChoices.contains(value) ? value : 0
        }
        set { defaults.set(recordingCountdownChoices.contains(newValue) ? newValue : 0, forKey: "recordingCountdownSeconds") }
    }

    /// Display recordings leave the icons and the clock on the right of the
    /// menu bar out of the video. They stay on screen.
    static var recordingHidesMenuBarIcons: Bool {
        get { defaults.bool(forKey: "recordingHidesMenuBarIcons") }
        set { defaults.set(newValue, forKey: "recordingHidesMenuBarIcons") }
    }

    /// Display recordings cover the desktop's files, folders and widgets
    /// until they stop. Its own setting, apart from the screenshot one: a
    /// screenshot hides them for a moment, a recording for as long as it runs.
    static var recordingHidesDesktopIcons: Bool {
        get { defaults.bool(forKey: "recordingHidesDesktopIcons") }
        set { defaults.set(newValue, forKey: "recordingHidesDesktopIcons") }
    }

    /// Where the recording HUD was last dragged to: its top-center, relative
    /// to the top-center of the screen's visible area (y grows downward).
    /// nil = the default spot.
    static var recordingHUDOffset: CGPoint? {
        get {
            guard let values = defaults.array(forKey: "recordingHUDOffset") as? [Double], values.count == 2 else { return nil }
            return CGPoint(x: values[0], y: values[1])
        }
        set {
            if let newValue {
                defaults.set([Double(newValue.x), Double(newValue.y)], forKey: "recordingHUDOffset")
            } else {
                defaults.removeObject(forKey: "recordingHUDOffset")
            }
        }
    }

    /// 0.23.1 made 60 fps the default, but pressing Record used to save
    /// whatever the fps menu showed — so almost everyone who had recorded
    /// before still had a stored 30. Clear those once; from now on only
    /// picking a frame rate stores one.
    static func migrateRecordingFPSIfNeeded() {
        guard !defaults.bool(forKey: "didMigrateRecordingFPSTo60") else { return }
        defaults.set(true, forKey: "didMigrateRecordingFPSTo60")
        if defaults.integer(forKey: "recordingFPS") == 30 {
            defaults.removeObject(forKey: "recordingFPS")
        }
    }
}
