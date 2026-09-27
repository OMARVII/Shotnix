import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// The longer languages fit: the editor toolbar keeps its aligned layout in
/// every language (and English keeps its design widths), and snapshots of
/// Settings, the menu, the welcome window, and the editor's toolbar and
/// popovers render in English, German, French, and Chinese to look at.
@MainActor
final class LocalizedLayoutTests: XCTestCase {
    private static let languages = ["en"] + L10n.translations
    private var suiteName: String!

    override func setUp() async throws {
        _ = NSApplication.shared
        suiteName = "ShotnixCoreTests.LocalizedLayout.\(UUID().uuidString)"
        Settings.defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        L10n.use(nil)
        UserDefaults().removePersistentDomain(forName: suiteName)
        Settings.defaults = .standard
    }

    // MARK: The editor toolbar

    func testEnglishToolbarKeepsItsDesignWidths() {
        L10n.use("en")
        // Tool groups 612, options group 204, Background 110, Copy and Save 54 each, gaps and insets.
        XCTAssertEqual(AnnotationToolbar.requiredWidth, 1070, "English looks exactly as designed")

        // The options area, control by control, as designed.
        let toolbar = AnnotationToolbar(frame: NSRect(x: 0, y: 0, width: AnnotationToolbar.requiredWidth, height: AnnotationToolbar.height))
        let design: [(AnnotationToolOptions.Context, [NSRect])] = [
            (.stroke, [NSRect(x: 0, y: 17, width: 30, height: 16), NSRect(x: 32, y: 11, width: 122, height: 28)]),
            (.rectangle, [NSRect(x: 0, y: 17, width: 30, height: 16), NSRect(x: 32, y: 11, width: 84, height: 28), NSRect(x: 124, y: 10, width: 30, height: 30)]),
            (.redaction, [NSRect(x: 0, y: 17, width: 50, height: 16), NSRect(x: 52, y: 11, width: 102, height: 28)]),
            (.spotlight, [NSRect(x: 0, y: 17, width: 38, height: 16), NSRect(x: 42, y: 13, width: 84, height: 24)]),
            (.crop, [NSRect(x: 0, y: 10, width: 74, height: 30), NSRect(x: 80, y: 10, width: 74, height: 30)]),
            (.none, [NSRect(x: 0, y: 17, width: 154, height: 16)]),
        ]
        for (context, frames) in design {
            toolbar.showOptions(AnnotationToolOptions(context: context))
            XCTAssertEqual(toolbar.visibleOptionControls.map(\.frame), frames, "\(context)")
        }
    }

    func testToolbarStaysAlignedAndFitsItsTitlesInEveryLanguage() throws {
        for language in Self.languages {
            L10n.use(language)
            let toolbar = AnnotationToolbar(frame: NSRect(x: 0, y: 0, width: AnnotationToolbar.requiredWidth, height: AnnotationToolbar.height))
            let groups = toolbar.groupFrames
            XCTAssertEqual(groups.first?.minX ?? 0, 8, accuracy: 0.001, language)
            for (left, right) in zip(groups, groups.dropFirst()) {
                XCTAssertEqual(right.minX - left.maxX, 8, accuracy: 0.001, "\(language): even gaps between groups")
            }
            XCTAssertEqual(AnnotationToolbar.requiredWidth - toolbar.trailingControlMaxX, 8, accuracy: 0.001, "\(language): same margin on the right")

            // Every text button's title fits inside it (tool buttons are icons).
            for button in Self.subviews(of: toolbar).compactMap({ $0 as? NSButton }) where button.image == nil && !button.title.isEmpty && !button.isHidden {
                let text = (button.title as NSString).size(withAttributes: [.font: button.font ?? .systemFont(ofSize: 11)]).width
                XCTAssertLessThanOrEqual(text + 8, button.frame.width, "\(language): “\(button.title)” fits its button")
            }

            // The options area: labels and crop buttons fit, controls stay inside it.
            let contexts: [AnnotationToolOptions.Context] = [.stroke, .rectangle, .redaction, .spotlight, .crop, .none]
            for context in contexts {
                toolbar.showOptions(AnnotationToolOptions(context: context, canApplyCrop: true, canResetCrop: true))
                for control in toolbar.visibleOptionControls {
                    XCTAssertLessThanOrEqual(control.frame.maxX, 154.5, "\(language) \(context): \(type(of: control)) stays in the options area")
                    if let label = control as? NSTextField, label.maximumNumberOfLines != 2 {
                        XCTAssertLessThanOrEqual(ceil(label.intrinsicContentSize.width), label.frame.width, "\(language) \(context): “\(label.stringValue)” isn't cut off")
                    }
                    if let button = control as? NSButton, button.image == nil, !button.title.isEmpty {
                        let text = (button.title as NSString).size(withAttributes: [.font: button.font ?? .systemFont(ofSize: 11)]).width
                        XCTAssertLessThanOrEqual(text + 8, button.frame.width, "\(language) \(context): “\(button.title)” fits")
                    }
                }
            }
        }
    }

    func testRenderEditorToolbarInEveryLanguage() throws {
        let states: [(AnnotationTool, AnnotationToolOptions)] = [
            (.select, AnnotationToolOptions(context: .none)),
            (.numberedStep, AnnotationToolOptions(context: .none)),
            (.arrow, AnnotationToolOptions(context: .stroke)),
            (.rectangle, AnnotationToolOptions(context: .rectangle, roundedCorners: true)),
            (.text, AnnotationToolOptions(context: .text)),
            (.blur, AnnotationToolOptions(context: .redaction)),
            (.spotlight, AnnotationToolOptions(context: .spotlight)),
            (.crop, AnnotationToolOptions(context: .crop, canApplyCrop: true, canResetCrop: true)),
        ]
        for language in Self.languages {
            L10n.use(language)
            let width = AnnotationToolbar.requiredWidth + 32
            let rowHeight = AnnotationToolbar.height + 14
            let stage = Self.stage(size: NSSize(width: width, height: CGFloat(states.count) * rowHeight + 18))
            for (index, state) in states.enumerated() {
                let toolbar = AnnotationToolbar(frame: NSRect(
                    x: 16,
                    y: stage.bounds.height - 16 - CGFloat(index + 1) * rowHeight + 14,
                    width: AnnotationToolbar.requiredWidth,
                    height: AnnotationToolbar.height
                ))
                toolbar.selectToolExternally(state.0)
                toolbar.showOptions(state.1)
                stage.addSubview(toolbar)
            }
            try Self.write(stage, name: "editor-toolbar-\(language)", dark: true)
        }
    }

    func testRenderEditorPopoversInEveryLanguage() throws {
        for language in Self.languages {
            L10n.use(language)
            var styles: [ScreenshotBackgroundOptions] = []
            for style in [ScreenshotBackgroundOptions.Style.gradient, .solid, .image] {
                var options = ScreenshotBackgroundOptions.editorDefault
                options.isEnabled = true
                options.style = style
                styles.append(options)
            }
            let views = styles.map { BackgroundPopoverController(options: $0).view } + [ColorPopoverController().view]
            let width = views.reduce(0) { $0 + $1.frame.width + 16 } + 16
            let height = (views.map(\.frame.height).max() ?? 0) + 32
            let stage = Self.stage(size: NSSize(width: width, height: height), color: .windowBackgroundColor)
            var x: CGFloat = 16
            for view in views {
                view.setFrameOrigin(NSPoint(x: x, y: height - 16 - view.frame.height))
                stage.addSubview(view)
                x += view.frame.width + 16
            }
            try Self.write(stage, name: "editor-popovers-\(language)", dark: true)
        }
    }

    // MARK: Settings, menu, welcome window

    func testSettingsTabsKeepTheirDesignWidthUnlessATitleNeedsMore() {
        // The window's default width leaves 442 pt for the tabs.
        L10n.use("en")
        XCTAssertEqual(PreferencesTabStrip.tabWidth(fitting: 442), 74, "English looks exactly as designed")
        L10n.use("zh-Hans")
        XCTAssertEqual(PreferencesTabStrip.tabWidth(fitting: 442), 74)
        L10n.use("de")
        XCTAssertGreaterThan(PreferencesTabStrip.tabWidth(fitting: 442), 74, "„Bildschirmfotos“ gets more room")
        XCTAssertEqual(PreferencesTabStrip.tabWidth(fitting: 402), 74, "never wider than the narrowest window allows")
        L10n.use("ru")
        XCTAssertGreaterThan(PreferencesTabStrip.tabWidth(fitting: 442), 74, "«Снимки экрана» gets more room")
    }

    func testHistoryCardButtonsFitEveryLanguage() {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        L10n.use("en")
        XCTAssertTrue(HistoryCollectionItem.buttonWidths(copy: L("Copy"), edit: L("Edit")) == (74, 74), "English looks exactly as designed")
        for language in Self.languages {
            L10n.use(language)
            let (copy, edit) = HistoryCollectionItem.buttonWidths(copy: L("Copy"), edit: L("Edit"))
            XCTAssertLessThanOrEqual(copy + edit, 148.5, "\(language): both stay on the card, 14 pt apart")
            XCTAssertLessThanOrEqual(TextFitting.width(of: L("Copy"), font: font) + 8, copy, "\(language): “\(L("Copy"))” fits")
            XCTAssertLessThanOrEqual(TextFitting.width(of: L("Edit"), font: font) + 8, edit, "\(language): “\(L("Edit"))” fits")
        }
    }

    func testRenderSettingsInEveryLanguage() async throws {
        for language in Self.languages {
            L10n.use(language)
            for tab in PreferencesTab.allCases {
                let selection = PreferencesSelectionModel()
                selection.selectedTab = tab
                // The narrowest the window gets, tall enough to show every row.
                let size = NSSize(width: 520, height: tab == .screenshots || tab == .recording ? 2000 : 1100)
                try await Self.render(PreferencesRootView(selection: selection), size: size, name: "settings-\(tab)-\(language)")
            }
            // The window's default size, for the tab strip.
            let selection = PreferencesSelectionModel()
            try await Self.render(PreferencesRootView(selection: selection), size: NSSize(width: 560, height: 620), name: "settings-default-size-\(language)")
        }
    }

    func testLanguagePopUpFitsAtTheNarrowestWidth() {
        // The narrowest window leaves 452 pt inside a row (520, less 22 pt of
        // pane and 12 pt of row padding on each side); the title, the row's
        // gaps and its spacer come first.
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        for language in Self.languages {
            L10n.use(language)
            let title = ceil((L("Language") as NSString).size(withAttributes: [.font: font]).width)
            for system in AppLanguage.all {
                let width = PreferenceMenuSelector.width(fitting: GeneralSettingsView.languageOptions(system: system))
                XCTAssertLessThanOrEqual(title + 36 + width, 452, "\(language) on a Mac in \(system)")
            }
        }
    }

    func testRenderLanguagePopUpInEveryLanguage() async throws {
        for language in Self.languages {
            L10n.use(language)
            // One row per Mac language, for every System Default title.
            let rows = PreferenceSection(L("Language")) {
                ForEach(AppLanguage.all, id: \.self) { system in
                    let options = GeneralSettingsView.languageOptions(system: system)
                    PreferenceRow(L("Language")) {
                        PreferenceMenuSelector(selection: .constant(nil), options: options, width: PreferenceMenuSelector.width(fitting: options))
                    }
                    if system != AppLanguage.all.last {
                        PreferenceDivider()
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ShotnixHUDBackground())
            try await Self.render(rows, size: NSSize(width: 520, height: 260), name: "settings-language-\(language)")
        }
    }

    func testRenderCommandCenterInEveryLanguage() async throws {
        let delegate = AppDelegate()
        let broken = ShotnixHealthSnapshot(
            screenRecordingGranted: false, nativeShortcutsEnabled: true, updatesConfigured: false,
            autoSavePath: "/nonexistent", autoSaveWritable: false,
            configuredShortcutCount: 5, expectedShortcutCount: 7, optionalUnassignedShortcutCount: 3,
            version: "0.24.1", build: "62"
        )
        let healthy = ShotnixHealthSnapshot(
            screenRecordingGranted: true, nativeShortcutsEnabled: false, updatesConfigured: true,
            autoSavePath: "/tmp", autoSaveWritable: true,
            configuredShortcutCount: 7, expectedShortcutCount: 7, optionalUnassignedShortcutCount: 3,
            version: "0.24.1", build: "62"
        )
        for language in Self.languages {
            L10n.use(language)
            for (name, snapshot) in [("healthy", healthy), ("issues", broken)] {
                let view = ShotnixCommandCenterView(
                    sections: delegate.commandCenterSections(screenCount: 2),
                    healthRows: ShotnixHealthModel.rows(snapshot: snapshot),
                    healthActions: [.screenRecording: {}, .nativeShortcuts: {}, .updates: {}, .autoSave: {}, .shortcuts: {}],
                    dismiss: {}
                )
                let size = NSSize(width: ShotnixMenuMetrics.commandCenterWidth, height: 620)
                try await Self.render(view, size: size, name: "menu-\(name)-\(language)")
                try await Self.render(view, size: size, name: "menu-\(name)-\(language)-scrolled", scrollToEnd: true)
            }
        }
    }

    func testRenderWelcomeWindowInEveryLanguage() throws {
        typealias State = WelcomeWindowController.SetupState
        let states: [(String, State)] = [
            ("fresh", State(hasPermission: false, requestedPermission: false, nativeShortcutsEnabled: true, onboardingCompleted: false, captureAreaShortcut: "⇧⌘4")),
            ("requested", State(hasPermission: false, requestedPermission: true, nativeShortcutsEnabled: true, onboardingCompleted: false, captureAreaShortcut: "⇧⌘4")),
            ("granted", State(hasPermission: true, requestedPermission: true, nativeShortcutsEnabled: false, onboardingCompleted: false, captureAreaShortcut: "⇧⌘4")),
            ("done", State(hasPermission: true, requestedPermission: true, nativeShortcutsEnabled: false, onboardingCompleted: true, captureAreaShortcut: nil)),
        ]
        for language in Self.languages {
            L10n.use(language)
            for (name, state) in states {
                let content = WelcomeWindowController().makeContent(state: state)
                let stage = Self.stage(size: content.frame.size, color: .windowBackgroundColor)
                stage.addSubview(content)
                try Self.write(stage, name: "welcome-\(name)-\(language)", dark: false)
            }
        }
    }

    // MARK: Rendering

    private static func subviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(subviews(of:))
    }

    private static func stage(size: NSSize, color: NSColor = ShotnixColors.editorStageTop) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        return view
    }

    private static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-l10n-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An AppKit view in an offscreen window, at 2x.
    private static func write(_ view: NSView, name: String, dark: Bool) throws {
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.appearance = window.appearance
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = try directory().appendingPathComponent("\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT-L10N: \(url.path)")
        window.contentView = nil
    }

    /// A SwiftUI view in an offscreen dark window, like Settings and the menu.
    private static func render<V: View>(_ view: V, size: NSSize, name: String, scrollToEnd: Bool = false) async throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = ShotnixColors.editorStageTop
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded()
        if scrollToEnd, let scroll = subviews(of: host).compactMap({ $0 as? NSScrollView }).first, let document = scroll.documentView {
            let end = max(0, document.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? end : 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = try directory().appendingPathComponent("\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT-L10N: \(url.path)")
        window.contentView = nil
    }
}
