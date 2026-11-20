import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// The colors behind light and dark: each follows the appearance of the
/// view it's drawn in, and the dark values are the ones Shotnix always had.
@MainActor
final class ThemeTests: XCTestCase {

    private let light = NSAppearance(named: .aqua)!
    private let dark = NSAppearance(named: .darkAqua)!

    private func components(_ color: NSColor, in appearance: NSAppearance) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var resolved = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? .clear
        }
        return (resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent)
    }

    // MARK: Ink

    func testInkIsWhiteInTheDarkAtTheOpacityAskedFor() {
        for opacity in [0.045, 0.08, 0.45, 0.58, 0.86, 0.93, 1.0] {
            let ink = components(ShotnixTheme.inkColor(CGFloat(opacity)), in: dark)
            XCTAssertEqual(ink.red, 1, accuracy: 0.0001)
            XCTAssertEqual(ink.green, 1, accuracy: 0.0001)
            XCTAssertEqual(ink.blue, 1, accuracy: 0.0001)
            XCTAssertEqual(ink.alpha, CGFloat(opacity), accuracy: 0.0001, "dark keeps the design's own opacity")
        }
    }

    func testInkIsNearBlackInTheLight() {
        let ink = components(ShotnixTheme.inkColor(0.93), in: light)
        XCTAssertLessThan(max(ink.red, ink.green, ink.blue), 0.12)
        XCTAssertGreaterThan(ink.alpha, 0.85)
    }

    func testLightInkGetsStrongerAsTheDarkOneDoes() {
        var last = -1.0
        for step in 0...100 {
            let opacity = Double(step) / 100
            let mapped = ShotnixTheme.lightInkOpacity(opacity)
            XCTAssertGreaterThanOrEqual(mapped, last, "no step back at \(opacity)")
            XCTAssertLessThanOrEqual(mapped, 1)
            last = mapped
        }
        XCTAssertEqual(ShotnixTheme.lightInkOpacity(0), 0)
    }

    /// Text on the light window keeps at least the contrast it has on the
    /// dark one, and the three text strengths the interface uses stay
    /// readable (4.5:1 for body text).
    func testTextKeepsItsContrastOnTheLightWindow() {
        let lightWindow = components(ShotnixTheme.stageBottomColor, in: light)
        for (opacity, minimum) in [(0.93, 7.0), (0.86, 7.0), (0.58, 4.5), (0.5, 4.5), (0.45, 4.5)] {
            let ink = components(ShotnixTheme.inkColor(CGFloat(opacity)), in: light)
            let ratio = Self.contrast(of: ink, over: (lightWindow.red, lightWindow.green, lightWindow.blue))
            XCTAssertGreaterThanOrEqual(ratio, minimum, "ink \(opacity) on the light window is \(String(format: "%.2f", ratio)):1")
        }
    }

    // MARK: Shade, shadow, surfaces

    func testShadeAndShadowAreFainterInTheLight() {
        XCTAssertEqual(components(ShotnixTheme.shadeColor(0.18), in: dark).alpha, 0.18, accuracy: 0.0001)
        XCTAssertLessThan(components(ShotnixTheme.shadeColor(0.18), in: light).alpha, 0.06)
        XCTAssertEqual(components(ShotnixTheme.shadowColor(0.4), in: dark).alpha, 0.4, accuracy: 0.0001)
        XCTAssertLessThan(components(ShotnixTheme.shadowColor(0.4), in: light).alpha, 0.2)
    }

    func testTheStageIsLightInTheLightAndDarkInTheDark() {
        for color in [ShotnixTheme.stageTopColor, ShotnixTheme.stageBottomColor] {
            XCTAssertGreaterThan(Self.luminance(components(color, in: light)), 0.8)
            XCTAssertLessThan(Self.luminance(components(color, in: dark)), 0.02)
        }
    }

    // MARK: SwiftUI

    /// A themed color in SwiftUI follows the window it's in, and a color
    /// scheme set on the view.
    func testASwiftUIViewDrawsInkForItsAppearance() throws {
        let lightPixel = try Self.pixel(of: Rectangle().fill(ShotnixTheme.ink(1)), appearance: light)
        let darkPixel = try Self.pixel(of: Rectangle().fill(ShotnixTheme.ink(1)), appearance: dark)
        XCTAssertLessThan(lightPixel.red, 0.2, "near-black in a light window")
        XCTAssertGreaterThan(darkPixel.red, 0.95, "white in a dark window")

        let forcedDark = try Self.pixel(of: Rectangle().fill(ShotnixTheme.ink(1)).environment(\.colorScheme, .dark), appearance: light)
        XCTAssertGreaterThan(forcedDark.red, 0.95, "a view kept dark draws dark ink in a light window")
    }

    // MARK: The setting

    func testAppearanceIsMatchSystemUntilPicked() {
        let suite = "ThemeTests-\(UUID().uuidString)"
        let previous = Settings.defaults
        Settings.defaults = UserDefaults(suiteName: suite)!
        defer {
            Settings.defaults.removePersistentDomain(forName: suite)
            Settings.defaults = previous
        }
        XCTAssertEqual(ShotnixAppearance.current, .system)
        XCTAssertNil(ShotnixAppearance.system.appearance, "the app follows the Mac")
        ShotnixAppearance.current = .light
        XCTAssertEqual(ShotnixAppearance.current, .light)
        XCTAssertEqual(ShotnixAppearance.light.appearance?.name, .aqua)
        XCTAssertEqual(ShotnixAppearance.dark.appearance?.name, .darkAqua)
        Settings.defaults.set("sepia", forKey: ShotnixAppearance.defaultsKey)
        XCTAssertEqual(ShotnixAppearance.current, .system, "an unknown value falls back to the Mac's")
    }

    // MARK: Helpers

    private static func pixel<V: View>(of view: V, appearance: NSAppearance) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let host = NSHostingView(rootView: view.frame(width: 20, height: 20))
        host.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let color = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        window.contentView = nil
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    private static func linear(_ value: CGFloat) -> Double {
        let value = Double(value)
        return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    static func luminance(_ color: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)) -> Double {
        0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// WCAG contrast of a translucent color over an opaque backdrop.
    static func contrast(of color: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat), over backdrop: (CGFloat, CGFloat, CGFloat)) -> Double {
        let mixed = (
            red: color.red * color.alpha + backdrop.0 * (1 - color.alpha),
            green: color.green * color.alpha + backdrop.1 * (1 - color.alpha),
            blue: color.blue * color.alpha + backdrop.2 * (1 - color.alpha),
            alpha: CGFloat(1)
        )
        let a = luminance(mixed)
        let b = luminance((backdrop.0, backdrop.1, backdrop.2, 1))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
