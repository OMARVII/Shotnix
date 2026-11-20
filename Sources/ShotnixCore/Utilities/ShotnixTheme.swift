import AppKit
import SwiftUI

// MARK: - Appearance

/// How Shotnix looks: like the Mac, or always light or always dark.
enum ShotnixAppearance: String, CaseIterable, Sendable {
    /// Light or dark with the Mac, and it follows when the Mac changes.
    case system
    case light
    case dark

    static let defaultsKey = "appAppearance"

    /// What was picked in Settings. Until something is, Shotnix matches the Mac.
    static var current: ShotnixAppearance {
        get { ShotnixAppearance(rawValue: Settings.defaults.string(forKey: defaultsKey) ?? "") ?? .system }
        set { Settings.defaults.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// nil lets every window follow the Mac.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Puts the choice on the whole app. Every window that doesn't pin its
    /// own appearance redraws at once, open ones included.
    @MainActor
    static func apply(_ choice: ShotnixAppearance = current) {
        NSApp.appearance = choice.appearance
    }
}

// MARK: - Colors

/// Shotnix's colors, each with a light and a dark value.
///
/// Every color here follows the appearance of the view it's drawn in, so a
/// window turns light or dark as a whole and nothing has to be told. The
/// dark values are the ones Shotnix has always had.
///
/// Three rules cover nearly all of the interface:
/// - What's drawn ON a surface (text, icons, hairlines, the faint fill of a
///   card or a hovered row) is `ink`: white in the dark, near-black in the
///   light, at the opacity the design asks for. A stronger fill is a `wash`.
/// - What darkens a surface (a recessed strip, the track of a control) is
///   `shade`, and what falls under a floating one is `shadow`. Both are
///   black in either appearance, and much fainter in the light.
/// - What sits on a color of its own (white text on a blue button, a label
///   on a timeline block, anything over a screenshot or a video) is not
///   themed: it stays the color it is.
enum ShotnixTheme {

    // MARK: Building blocks

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// A color with a value for each appearance.
    static func dynamic(light: @autoclosure @escaping () -> NSColor, dark: @autoclosure @escaping () -> NSColor) -> NSColor {
        NSColor(name: nil) { isDark($0) ? dark() : light() }
    }

    /// A SwiftUI color with a value for each appearance.
    static func color(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: dynamic(light: light, dark: dark))
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    // MARK: Ink

    /// The light appearance's ink: a cool near-black, softer than pure black.
    private static let lightInk = (red: CGFloat(0.075), green: CGFloat(0.078), blue: CGFloat(0.098))

    /// The opacity near-black ink needs in the light to do what white ink at
    /// `opacity` does in the dark.
    ///
    /// Faint fills and hairlines (up to 0.2) carry over a little lighter.
    /// Text needs more: gray on white reads weaker than the same gray on
    /// black, so helper and secondary text is lifted until it has the
    /// contrast it has in the dark (4.5:1 and up from 0.45). Full-strength
    /// text stops short of solid black.
    static func lightInkOpacity(_ opacity: Double) -> Double {
        let opacity = min(max(opacity, 0), 1)
        let stops = lightInkStops
        guard let upper = stops.firstIndex(where: { $0.dark >= opacity }), upper > 0 else { return stops[0].light }
        let from = stops[upper - 1], to = stops[upper]
        return from.light + (opacity - from.dark) / (to.dark - from.dark) * (to.light - from.light)
    }

    private static let lightInkStops: [(dark: Double, light: Double)] = [
        (0, 0), (0.2, 0.17), (0.3, 0.4), (0.45, 0.62), (0.6, 0.7), (0.8, 0.845), (0.93, 0.93), (1, 0.96),
    ]

    /// A wash's opacity in the light: a little lighter all the way up.
    static let lightWashShare = 0.85

    private static let inkCache = ThemeColorCache()
    private static let washCache = ThemeColorCache()
    private static let shadeCache = ThemeColorCache()
    private static let shadowCache = ThemeColorCache()

    /// Text, icons, hairlines and faint fills on Shotnix's own surfaces.
    static func inkColor(_ opacity: CGFloat = 1) -> NSColor {
        inkCache.color(for: opacity) {
            let light = rgb(lightInk.red, lightInk.green, lightInk.blue, CGFloat(lightInkOpacity(Double(opacity))))
            let dark = rgb(1, 1, 1, opacity)
            return dynamic(light: light, dark: dark)
        }
    }

    /// Text, icons, hairlines and faint fills on Shotnix's own surfaces.
    static func ink(_ opacity: Double = 1) -> Color {
        Color(nsColor: inkColor(CGFloat(opacity)))
    }

    /// A fill or an outline stronger than a faint one (above 0.2), where
    /// `ink` would come out as heavy as text: a pressed button, a thumb.
    static func washColor(_ opacity: CGFloat) -> NSColor {
        washCache.color(for: opacity) {
            dynamic(light: rgb(lightInk.red, lightInk.green, lightInk.blue, opacity * CGFloat(lightWashShare)), dark: rgb(1, 1, 1, opacity))
        }
    }

    /// A fill or an outline stronger than a faint one (above 0.2), where
    /// `ink` would come out as heavy as text: a pressed button, a thumb.
    static func wash(_ opacity: Double) -> Color {
        Color(nsColor: washColor(CGFloat(opacity)))
    }

    private static let solidInkCache = ThemeColorCache()

    /// Ink at exactly this opacity in either appearance, for a surface made
    /// of it: the primary button, white on the dark window and near-black on
    /// the light one.
    static func solidInkColor(_ opacity: CGFloat) -> NSColor {
        solidInkCache.color(for: opacity) {
            dynamic(light: rgb(lightInk.red, lightInk.green, lightInk.blue, opacity), dark: NSColor.white.withAlphaComponent(opacity))
        }
    }

    /// Ink at exactly this opacity in either appearance (see `solidInkColor`).
    static func solidInk(_ opacity: Double) -> Color {
        Color(nsColor: solidInkColor(CGFloat(opacity)))
    }

    /// Letters on a surface of solid ink: dark on white, white on near-black.
    static let onSolidInkColor = dynamic(light: rgb(1, 1, 1, 0.96), dark: NSColor.black.withAlphaComponent(0.88))
    static let onSolidInk = Color(nsColor: onSolidInkColor)

    // MARK: Shade and shadow

    /// How much of a dark surface's darkening a light one takes.
    static let lightShadeShare = 0.24
    /// Shadows are far softer on a light surface.
    static let lightShadowShare = 0.36

    /// Darkens a surface a little: a recessed strip, a control's track.
    static func shadeColor(_ opacity: CGFloat) -> NSColor {
        shadeCache.color(for: opacity) {
            dynamic(light: rgb(0, 0, 0, opacity * CGFloat(lightShadeShare)), dark: rgb(0, 0, 0, opacity))
        }
    }

    /// Darkens a surface a little: a recessed strip, a control's track.
    static func shade(_ opacity: Double) -> Color {
        Color(nsColor: shadeColor(CGFloat(opacity)))
    }

    /// The shadow under something that floats above the interface.
    static func shadowColor(_ opacity: CGFloat) -> NSColor {
        shadowCache.color(for: opacity) {
            dynamic(light: rgb(0.1, 0.1, 0.16, opacity * CGFloat(lightShadowShare)), dark: rgb(0, 0, 0, opacity))
        }
    }

    /// The shadow under something that floats above the interface.
    static func shadow(_ opacity: Double) -> Color {
        Color(nsColor: shadowColor(CGFloat(opacity)))
    }

    // MARK: Surfaces

    /// The window behind Settings, History, the command center and the
    /// screenshot editor: a soft gradient from `stageTop` to `stageBottom`.
    static let stageTopColor = dynamic(
        light: rgb(0.969, 0.973, 0.984),
        dark: NSColor(calibratedRed: 0.045, green: 0.049, blue: 0.062, alpha: 1)
    )
    static let stageBottomColor = dynamic(
        light: rgb(0.933, 0.931, 0.957),
        dark: NSColor(calibratedRed: 0.105, green: 0.096, blue: 0.13, alpha: 1)
    )
    static let stageTop = Color(nsColor: stageTopColor)
    static let stageBottom = Color(nsColor: stageBottomColor)

    /// The same gradient for a surface that lets a little of what's behind
    /// the window through (`ShotnixHUDBackground`).
    static let veilTop = color(
        light: rgb(0.969, 0.973, 0.984),
        dark: NSColor(calibratedRed: 0.045, green: 0.049, blue: 0.062, alpha: 0.96)
    )
    static let veilBottom = color(
        light: rgb(0.933, 0.931, 0.957),
        dark: NSColor(calibratedRed: 0.105, green: 0.096, blue: 0.13, alpha: 0.96)
    )

    /// A card lying on the window (a capture in History): near-black on the
    /// dark window, white on the light one, more solid while it's hovered or
    /// selected.
    static func cardColor(raised: Bool) -> NSColor {
        raised ? raisedCardColor : restingCardColor
    }

    private static let restingCardColor = dynamic(light: rgb(1, 1, 1, 0.88), dark: NSColor(calibratedWhite: 0.045, alpha: 0.86))
    private static let raisedCardColor = dynamic(light: rgb(1, 1, 1, 0.98), dark: NSColor(calibratedWhite: 0.045, alpha: 0.94))

    // MARK: Signals

    /// Text and icons that warn of losing something: readable on either surface.
    static let destructiveColor = dynamic(light: rgb(0.80, 0.14, 0.15), dark: rgb(1, 0.45, 0.45))
    static let destructive = Color(nsColor: destructiveColor)

    /// Something is wrong: the system red, deepened for text on white.
    static let dangerColor = dynamic(light: rgb(0.83, 0.15, 0.13), dark: NSColor.systemRed)
    static let danger = Color(nsColor: dangerColor)

    /// A warning's text and icon. The system yellow is unreadable on white.
    static let warningColor = dynamic(light: rgb(0.66, 0.43, 0.0), dark: NSColor.systemYellow)
    static let warning = Color(nsColor: warningColor)

    /// Something went well. The system green is too pale for text on white.
    static let successColor = dynamic(light: rgb(0.10, 0.55, 0.24), dark: NSColor.systemGreen)
    static let success = Color(nsColor: successColor)
}

/// Dynamic colors by opacity, made once each. Views ask for the same few
/// opacities on every redraw.
private final class ThemeColorCache: @unchecked Sendable {
    private var colors: [Int: NSColor] = [:]
    private let lock = NSLock()

    func color(for opacity: CGFloat, make: () -> NSColor) -> NSColor {
        let key = Int((opacity * 10_000).rounded())
        lock.lock()
        defer { lock.unlock() }
        if let color = colors[key] { return color }
        let color = make()
        colors[key] = color
        return color
    }
}

// MARK: - AppKit layers

/// A layer keeps the `CGColor` it's given, so it doesn't turn light or dark
/// with its view. These give a view's layers their colors again whenever
/// the view's appearance changes.
@MainActor
protocol Themeable: NSView {}
extension NSView: Themeable {}

extension Themeable {
    /// Runs `apply` now, and again each time this view turns light or dark,
    /// with the view's appearance current: the place to set layer colors.
    /// The view keeps the closure; don't capture the view in it, use the
    /// one it's handed.
    func themed(_ apply: @escaping @MainActor (Self) -> Void) {
        let observation = observe(\.effectiveAppearance, options: [.initial, .new]) { view, _ in
            MainActor.assumeIsolated {
                view.effectiveAppearance.performAsCurrentDrawingAppearance { apply(view) }
            }
        }
        var kept = objc_getAssociatedObject(self, &themeObservationsKey) as? [NSKeyValueObservation] ?? []
        kept.append(observation)
        objc_setAssociatedObject(self, &themeObservationsKey, kept, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

nonisolated(unsafe) private var themeObservationsKey: UInt8 = 0

extension NSColor {
    /// This color as a `CGColor` for `view`'s appearance.
    func cgColor(in view: NSView) -> CGColor {
        var resolved = cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = self.cgColor }
        return resolved
    }
}

// MARK: - Windows that stay dark

extension NSWindow {
    /// Keeps this window dark whatever Shotnix is set to. What floats over
    /// the screen while it's being captured (the selection, the recording
    /// bar, the countdown, a toast) is drawn for a dark surface in either
    /// appearance, like macOS's own capture tools.
    func staysDark() {
        appearance = NSAppearance(named: .darkAqua)
    }
}

extension NSColor {
    /// This color as a `CGColor` for a window that stays dark. A system
    /// color turned into one outside of drawing comes out for the app's
    /// appearance, which is the wrong one for such a window in a light
    /// Shotnix.
    var hudCGColor: CGColor {
        var resolved = cgColor
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { resolved = self.cgColor }
        return resolved
    }
}
