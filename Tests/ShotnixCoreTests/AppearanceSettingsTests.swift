import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Settings > General > Appearance: what it says in every language, what
/// picking one does to the app, and what stays dark whatever is picked.
@MainActor
final class AppearanceSettingsTests: XCTestCase {

    private static let languages = ["en"] + L10n.translations
    private let light = NSAppearance(named: .aqua)!
    private let dark = NSAppearance(named: .darkAqua)!

    override func tearDown() {
        L10n.use(nil)
        // Back to the appearance the other tests draw in.
        NSApplication.shared.appearance = NSAppearance(named: TestAppearance.name)
        super.tearDown()
    }

    private func matches(_ appearance: NSAppearance) -> NSAppearance.Name? {
        appearance.bestMatch(from: [.aqua, .darkAqua])
    }

    // MARK: The words

    func testEnglishUsesTheWordsMacOSUses() {
        L10n.use("en")
        XCTAssertEqual(ShotnixAppearance.system.title, "Auto")
        XCTAssertEqual(ShotnixAppearance.light.title, "Light")
        XCTAssertEqual(ShotnixAppearance.dark.title, "Dark")
        XCTAssertEqual(L("Shotnix appearance"), "Appearance")
    }

    func testEveryLanguageNamesTheThreeChoicesApart() {
        for language in Self.languages {
            L10n.use(language)
            let titles = ShotnixAppearance.allCases.map(\.title)
            XCTAssertEqual(Set(titles).count, 3, "\(language): \(titles)")
            for title in titles + [L("Shotnix appearance")] {
                XCTAssertFalse(title.isEmpty, language)
                XCTAssertFalse(title.lowercased().contains("appearance") && language != "en", "\(language): “\(title)” was left in English")
            }
        }
    }

    /// The row holds its title and the three pictures side by side. At the
    /// narrowest Settings window that's 452 pt, less the 12 pt between them.
    func testTheTitleAndThePicturesFitTheNarrowestWindowInEveryLanguage() {
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        // The widest a name gets: semibold, when it's the one picked.
        let nameFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let picture = PreferenceAppearancePicker.thumbnailSize.width + 6
        for language in Self.languages {
            L10n.use(language)
            let names = ShotnixAppearance.allCases.map { max(picture, TextFitting.width(of: $0.title, font: nameFont)) }
            let picker = names.reduce(0, +) + 12 * 2
            let title = TextFitting.width(of: L("Shotnix appearance"), font: titleFont)
            XCTAssertLessThanOrEqual(title + picker, 440, "\(language): the title takes \(title), the pictures \(picker)")
        }
    }

    // MARK: Picking one

    func testPickingAnAppearancePutsTheWholeAppInIt() {
        ShotnixAppearance.apply(.light)
        XCTAssertEqual(NSApplication.shared.appearance?.name, .aqua)
        XCTAssertEqual(matches(NSApplication.shared.effectiveAppearance), .aqua)

        ShotnixAppearance.apply(.dark)
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)

        ShotnixAppearance.apply(.system)
        XCTAssertNil(NSApplication.shared.appearance, "nothing pinned: the app follows the Mac, and keeps following it")
    }

    /// A window that's already open turns with the app.
    func testAnOpenWindowTurnsWithTheApp() throws {
        ShotnixAppearance.apply(.dark)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSView(frame: window.frame)
        window.contentView = view
        XCTAssertEqual(matches(view.effectiveAppearance), .darkAqua)
        ShotnixAppearance.apply(.light)
        XCTAssertEqual(matches(view.effectiveAppearance), .aqua)
    }

    // MARK: Layers

    /// A layer keeps the color it was given. `themed` gives it the new
    /// appearance's color when its view turns.
    func testALayerIsColoredAgainWhenItsViewTurnsLightOrDark() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = dark
        let view = NSView(frame: window.frame)
        view.wantsLayer = true
        window.contentView = view
        var runs = 0
        view.themed { view in
            runs += 1
            view.layer?.backgroundColor = ShotnixTheme.inkColor(1).cgColor
        }
        XCTAssertEqual(runs, 1, "colored at once")
        XCTAssertEqual(try red(of: view), 1, accuracy: 0.01, "white ink in the dark")

        window.appearance = light
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertGreaterThanOrEqual(runs, 2)
        XCTAssertLessThan(try red(of: view), 0.2, "near-black ink in the light")

        window.appearance = dark
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(try red(of: view), 1, accuracy: 0.01)
    }

    func testAColorResolvesForTheViewItIsAskedFor() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSView(frame: window.frame)
        window.contentView = view
        window.appearance = light
        let inLight = try XCTUnwrap(ShotnixTheme.inkColor(1).cgColor(in: view).components)
        window.appearance = dark
        let inDark = try XCTUnwrap(ShotnixTheme.inkColor(1).cgColor(in: view).components)
        XCTAssertLessThan(inLight[0], 0.2)
        XCTAssertEqual(inDark[0], 1, accuracy: 0.01)
    }

    private func red(of view: NSView) throws -> CGFloat {
        let color = try XCTUnwrap(view.layer?.backgroundColor)
        let srgb = try XCTUnwrap(color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil))
        return try XCTUnwrap(srgb.components)[0]
    }

    // MARK: What stays dark

    /// What floats over the screen while it's captured is drawn for a dark
    /// surface. In a light Shotnix it stays dark, with its system controls.
    func testCaptureOverlaysStayDarkInALightShotnix() throws {
        ShotnixAppearance.apply(.light)
        let hud = RecordingHUDWindow()
        XCTAssertEqual(matches(hud.effectiveAppearance), .darkAqua, "the recording HUD")
        if let content = hud.contentView {
            XCTAssertEqual(matches(content.effectiveAppearance), .darkAqua, "and what's in it")
        }
        if let screen = NSScreen.main {
            let countdown = CountdownWindow(seconds: 3, on: screen) { _ in }
            XCTAssertEqual(matches(countdown.effectiveAppearance), .darkAqua, "the countdown")
            // Never shown, so there's nothing to close (a closed window frees itself).
            countdown.isReleasedWhenClosed = false
        }

        let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        XCTAssertEqual(matches(plain.effectiveAppearance), .aqua, "any other window is light")
        plain.staysDark()
        XCTAssertEqual(matches(plain.effectiveAppearance), .darkAqua)
    }

    // MARK: Settings

    /// Settings draws light in a light Shotnix and dark in a dark one: its
    /// window, its cards and its text all come from the theme.
    func testSettingsFollowTheAppearance() throws {
        let lightPixels = try Self.render(GeneralSettingsView(), appearance: light)
        let darkPixels = try Self.render(GeneralSettingsView(), appearance: dark)
        XCTAssertGreaterThan(lightPixels.background, 0.75, "a light page")
        XCTAssertLessThan(darkPixels.background, 0.2, "a dark page")
        XCTAssertLessThan(lightPixels.darkest, 0.25, "with dark text on it")
        XCTAssertGreaterThan(darkPixels.lightest, 0.75, "and light text on the dark one")
    }

    private static func render<V: View>(_ view: V, appearance: NSAppearance) throws -> (background: CGFloat, darkest: CGFloat, lightest: CGFloat) {
        let size = NSSize(width: 560, height: 420)
        let host = NSHostingView(rootView: ZStack { ShotnixTheme.stageBottom; view }.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        func brightness(_ x: Int, _ y: Int) -> CGFloat {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
            return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        }
        var darkest: CGFloat = 1, lightest: CGFloat = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                let value = brightness(x, y)
                darkest = min(darkest, value)
                lightest = max(lightest, value)
            }
        }
        // The page's own margin, clear of every card.
        return (brightness(4, rep.pixelsHigh - 4), darkest, lightest)
    }
}
