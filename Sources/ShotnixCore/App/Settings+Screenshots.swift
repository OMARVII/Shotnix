import Foundation

// Screenshots settings added after 0.23 live here, so work on each part of the app stays out of Settings.swift.
extension Settings {}

// MARK: – Annotation editor

extension Settings {
    /// New rectangles get rounded corners.
    static var annotationRoundedRectangles: Bool {
        get { defaults.bool(forKey: "annotationRoundedRectangles") }
        set { defaults.set(newValue, forKey: "annotationRoundedRectangles") }
    }

    /// Last-used size for text annotations and callouts, in points (8–96, default 18).
    static var annotationTextFontSize: Double {
        get {
            let v = defaults.double(forKey: "annotationTextFontSize")
            return v == 0 ? 18 : min(max(v, 8), 96)
        }
        set { defaults.set(newValue, forKey: "annotationTextFontSize") }
    }

    /// Text starts bold, the only style before sizes and weights were added.
    static var annotationTextBold: Bool {
        get {
            if defaults.object(forKey: "annotationTextBold") == nil { return true }
            return defaults.bool(forKey: "annotationTextBold")
        }
        set { defaults.set(newValue, forKey: "annotationTextBold") }
    }

    /// Blur radius / pixel block size for new redactions, in points (4–40, default 12).
    static var annotationRedactionStrength: Double {
        get {
            let v = defaults.double(forKey: "annotationRedactionStrength")
            return v == 0 ? 12 : min(max(v, 4), 40)
        }
        set { defaults.set(newValue, forKey: "annotationRedactionStrength") }
    }

    /// New spotlights are ellipses rather than rectangles.
    static var annotationSpotlightEllipse: Bool {
        get { defaults.bool(forKey: "annotationSpotlightEllipse") }
        set { defaults.set(newValue, forKey: "annotationSpotlightEllipse") }
    }
}
