import Foundation

/// Central UserDefaults store for all user-configurable settings.
enum Settings {

    // MARK: – Overlay

    /// Auto-dismiss timeout in seconds. -1 = never dismiss automatically.
    static var overlayTimeout: Double {
        get {
            let v = UserDefaults.standard.double(forKey: "overlayTimeout")
            return v == 0 ? 6 : v   // 0 means key not set yet → default 6s
        }
        set { UserDefaults.standard.set(newValue, forKey: "overlayTimeout") }
    }

    /// true = show overlay on the left side, false = right side (default)
    static var overlayOnLeft: Bool {
        get { UserDefaults.standard.bool(forKey: "overlayOnLeft") }
        set { UserDefaults.standard.set(newValue, forKey: "overlayOnLeft") }
    }
}
