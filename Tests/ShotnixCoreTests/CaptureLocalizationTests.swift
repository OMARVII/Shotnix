import AppKit
import XCTest
@testable import ShotnixCore

/// Capture, recording, and overlay UI in German, French, and Chinese: strings
/// resolve (plurals, reordered placeholders, list and sentence joining), and
/// the main surfaces render without cut-off words. Each test photographs its
/// surface per language (printed as SNAPSHOT-L10N: <path>) for a look.
@MainActor
final class CaptureLocalizationTests: XCTestCase {
    private static let languages = L10n.translations
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        suiteName = "ShotnixCoreTests.CaptureLocalization.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Settings.defaults = defaults
        Settings.overlayTimeout = -1 // no auto-dismiss mid-snapshot
    }

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        L10n.use(nil)
        defaults.removePersistentDomain(forName: suiteName)
        Settings.defaults = .standard
        super.tearDown()
    }

    // MARK: Strings

    func testStringsResolveInEachLanguage() {
        L10n.use("de")
        XCTAssertEqual(RecordingQuality.balanced.displayName, "Ausgewogen")
        XCTAssertEqual(RecordingTargetKind.area.title, "Bereich", "the same word as Capture Area's")
        XCTAssertEqual(L("\(1) links"), "1 Link")
        XCTAssertEqual(L("\(3) screens"), "3 Bildschirme")
        XCTAssertEqual(L("\(1) lines · found \("eine Tabelle")"), "1 Zeile · gefunden: eine Tabelle", "the count decides the form, the list follows")
        XCTAssertEqual(RecordingEngine.durationText(42), "42 s")
        XCTAssertTrue(RecordingDiskSpace.lowSpaceWarning(secondsLeft: 300).contains("etwa 5 Minuten"))
        XCTAssertTrue(RecordingEngine.startFailureMessage(for: RecordingEngine.RecordingError.windowGone).hasPrefix("Das Fenster"))

        L10n.use("fr")
        XCTAssertEqual(L("\(1) email addresses"), "1 adresse e-mail")
        XCTAssertEqual(L("\(2) email addresses"), "2 adresses e-mail")
        XCTAssertEqual(L("Estimated size \("12 Mo")"), "Taille estimée\u{00A0}: 12 Mo", "a no-break space before the colon")
        XCTAssertTrue(RecordingDiskSpace.lowSpaceWarning(secondsLeft: 45).contains("environ 40 secondes"))

        L10n.use("zh-Hans")
        XCTAssertEqual(L("Links (\(4) of \(9))"), "链接（前 4 个，共 9 个）", "numbered placeholders")
        XCTAssertEqual(QRCodePayload.parse("WIFI:S:Home;T:WPA;P:secret;;").displayText, "网络：Home\n安全性：WPA\n密码：secret")
        XCTAssertEqual(QRCodePayload.parse("https://shotnix.com").kind, "链接")
    }

    func testListsAndSentencesJoinTheWayEachLanguageWrites() {
        let result = OCRResult(lines: [OCRLine(text: "See https://shotnix.com and a@b.co", box: CGRect(x: 0, y: 0, width: 300, height: 18))])
        L10n.use("zh-Hans")
        XCTAssertEqual(OCRResultWindow.extrasSummary(for: result), "1 个链接、1 个电子邮件地址", "Chinese lists use 、")
        let chinese = [L("No camera found."), L("Recording without the camera.")]
        XCTAssertEqual(RecordingEngine.sentences(chinese), "未找到摄像头。本次录制将不含摄像头画面。", "no space after full-width punctuation")
        L10n.use("de")
        XCTAssertEqual(OCRResultWindow.extrasSummary(for: result), "1 Link, 1 E-Mail-Adresse")
        XCTAssertEqual(RecordingEngine.sentences([L("No camera found."), L("Recording without the camera.")]), "Keine Kamera gefunden. Aufzeichnung ohne Kamera.")
        L10n.use(nil)
        XCTAssertEqual(RecordingEngine.sentences(["One.", "Two."]), "One. Two.", "English as before")
    }

    // MARK: Recording bar and options menu

    func testRecordingBarFitsEachLanguage() throws {
        Settings.recordingMicrophone = true
        Settings.recordingSystemAudio = true
        for language in Self.languages {
            L10n.use(language)
            let screen = try XCTUnwrap(NSScreen.main)
            let bar = RecordingControlsWindow(rect: screen.frame, screen: screen, target: .fullscreen, selectedWindow: nil, startHandler: { _, _, _ in }, closeHandler: {})
            bar.setFrameOrigin(RecordingUITestSupport.offscreen)
            bar.orderFrontRegardless()
            defer { bar.closeControls() }
            let root = try XCTUnwrap(bar.contentView)
            XCTAssertEqual(Self.clipped(in: root), [], language)
            let quality = try XCTUnwrap(RecordingUITestSupport.allSubviews(of: root).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == L("Quality") })
            let widest = TextFitting.widest(quality.itemTitles, font: try XCTUnwrap(quality.font))
            XCTAssertLessThanOrEqual(widest + 16, quality.frame.width, "\(language): the quality menu shows its longest name")
            try snapshot(bar, "\(language)/recording-bar")
            let menu = bar.optionsMenu()
            try snapshot(menu: menu, "\(language)/recording-options-menu")
            XCTAssertTrue(menu.items.map(\.title).contains(L("Open Editor After Recording")), language)
            XCTAssertNotEqual(L("Open Editor After Recording"), "Open Editor After Recording", "\(language): translated")
        }
    }

    // MARK: Recording HUD

    func testRecordingHUDFitsEachLanguage() throws {
        for language in Self.languages {
            L10n.use(language)
            let recording = makeHUD()
            XCTAssertEqual(Self.clipped(in: try XCTUnwrap(recording.contentView)), [], language)
            try snapshot(recording, "\(language)/hud-recording")
            recording.closeHUD()

            let paused = makeHUD()
            paused.setPaused(true)
            try snapshot(paused, "\(language)/hud-paused")
            paused.closeHUD()

            for (index, warning) in [L("Camera disconnected"), L("Disk almost full"), L("Window closed"), L("Mic switched")].enumerated() {
                let hud = makeHUD()
                hud.showWarning(warning)
                hud.setMicrophoneSilent(true)
                XCTAssertEqual(Self.clipped(in: try XCTUnwrap(hud.contentView)), [], "\(language): \(warning)")
                if index == 0 { try snapshot(hud, "\(language)/hud-warning") }
                hud.closeHUD()
            }

            let confirming = makeHUD()
            RecordingUITestSupport.click(try XCTUnwrap(RecordingUITestSupport.button(labelled: L("Discard recording"), in: confirming)), in: confirming)
            XCTAssertEqual(confirming.state, .confirmingDiscard)
            let confirmRoot = try XCTUnwrap(confirming.contentView)
            XCTAssertEqual(Self.clipped(in: confirmRoot), [], "\(language): the question and its buttons")
            let discard = try XCTUnwrap(RecordingUITestSupport.button(labelled: L("Discard"), in: confirming))
            let keep = try XCTUnwrap(RecordingUITestSupport.button(labelled: L("Keep"), in: confirming))
            XCTAssertGreaterThan(keep.frame.minX, discard.frame.maxX)
            XCTAssertLessThanOrEqual(keep.frame.maxX, RecordingHUDWindow.size.width)
            try snapshot(confirming, "\(language)/hud-discard")
            confirming.closeHUD()

            let saving = makeHUD()
            saving.showSaving()
            XCTAssertEqual(Self.clipped(in: try XCTUnwrap(saving.contentView)), [], language)
            try snapshot(saving, "\(language)/hud-saving")
            saving.closeHUD()
        }
    }

    func testRecordingHUDKeepsItsEnglishLayout() throws {
        let hud = makeHUD()
        defer { hud.closeHUD() }
        RecordingUITestSupport.click(try XCTUnwrap(RecordingUITestSupport.button(labelled: "Discard recording", in: hud)), in: hud)
        XCTAssertEqual(try XCTUnwrap(RecordingUITestSupport.button(labelled: "Discard", in: hud)).frame, NSRect(x: 262, y: 10, width: 66, height: 24))
        XCTAssertEqual(try XCTUnwrap(RecordingUITestSupport.button(labelled: "Keep", in: hud)).frame, NSRect(x: 334, y: 10, width: 58, height: 24))
    }

    // MARK: Area selection

    func testSelectionHintAndCaptureButtonFitEachLanguage() throws {
        for language in Self.languages {
            L10n.use(language)
            let (window, view) = makeSelection()
            // Before dragging: the hint bar.
            view.mouseMoved(with: mouseEvent(.mouseMoved, at: CGPoint(x: 640, y: 560), in: window))
            try snapshotSelection(view, in: window, "\(language)/selection-idle-hint")
            for immediate in [true, false] {
                view.captureImmediately = immediate
                XCTAssertLessThan(Self.width(view.hintText, .systemFont(ofSize: 12, weight: .medium)) + 28, 1024 - 48, "\(language): fits the narrowest Mac screen")
            }
            // Adjusting: the Capture button and the longest hint.
            view.captureImmediately = false
            drag(view, in: window, from: CGPoint(x: 360, y: 300), to: CGPoint(x: 900, y: 620))
            XCTAssertEqual(view.stage, .adjusting)
            let button = view.confirmButtonRect(for: view.currentRect)
            XCTAssertGreaterThanOrEqual(button.width, Self.width(L("Capture  ⏎"), .systemFont(ofSize: 12.5, weight: .semibold)) + 26)
            XCTAssertLessThan(Self.width(view.hintText, .systemFont(ofSize: 12, weight: .medium)) + 28, 1024 - 48, "\(language): fits the narrowest Mac screen")
            try snapshotSelection(view, in: window, "\(language)/selection-adjust-stage")
            window.orderOut(nil)
        }
    }

    // MARK: Scrolling capture HUD

    func testScrollingHUDFitsEachLanguage() throws {
        for language in Self.languages {
            L10n.use(language)
            let hud = ScrollingCaptureHUD()
            windows.append(hud)
            hud.update(heightPixels: 12480, status: L("Scroll down to capture"), isWarning: false)
            let root = try XCTUnwrap(hud.contentView)
            XCTAssertEqual(Self.clipped(in: root), [], language)
            XCTAssertGreaterThanOrEqual(hud.frame.width, ScrollingCaptureHUD.size.width)
            try snapshot(hud, "\(language)/scrolling-hud")
            hud.update(heightPixels: 30000, status: L("Scroll down to capture more"), isWarning: false)
            XCTAssertEqual(Self.clipped(in: root), [], "\(language): more")
            hud.update(heightPixels: 30000, status: L("Maximum length reached"), isWarning: true)
            XCTAssertEqual(Self.clipped(in: root), [], "\(language): the limit")
            hud.showFinishing()
            XCTAssertEqual(Self.clipped(in: root), [], "\(language): stitching")
        }
        L10n.use(nil)
        let english = ScrollingCaptureHUD()
        windows.append(english)
        XCTAssertEqual(english.frame.size, ScrollingCaptureHUD.size, "English keeps its size")
    }

    // MARK: Quick access thumbnail

    func testQuickAccessThumbnailFitsEachLanguage() throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("ShotnixCoreTests.CaptureLocalization.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let manager = HistoryManager(storageDir: storage)
        let image = HistoryManagerTests.makeImage()
        let item = manager.add(image: image, rect: nil, type: .area)
        for language in ["en"] + Self.languages {
            L10n.use(language == "en" ? nil : language)
            let thumbnail = QuickAccessWindow(image: image, historyItem: item, historyManager: manager)
            thumbnail.setFrameOrigin(RecordingUITestSupport.offscreen)
            thumbnail.setHovered(true)
            RecordingUITestSupport.spinRunLoop(0.3)
            let root = try XCTUnwrap(thumbnail.contentView)
            let titles = [L("Copy"), L("Save"), L("Text")]
            let pills = RecordingUITestSupport.allSubviews(of: root).compactMap { $0 as? NSButton }.filter { titles.contains($0.attributedTitle.string) }
            XCTAssertEqual(pills.count, 3, language)
            for pill in pills {
                let frame = pill.convert(pill.bounds, to: root)
                XCTAssertTrue(root.bounds.insetBy(dx: 8, dy: 0).contains(frame), "\(language): \(pill.attributedTitle.string) stays on the card")
                XCTAssertLessThanOrEqual(pill.attributedTitle.size().width + 12, frame.width, "\(language): \(pill.attributedTitle.string) fits its pill")
            }
            if language == "en" {
                XCTAssertEqual(pills.map { $0.frame.width }, pills.map { ceil($0.attributedTitle.size().width) + 28 }, "English keeps the designed padding")
                XCTAssertEqual(QuickAccessWindow.pillFontSize(titles: titles, available: 216), 13, "and the designed 13 pt")
            }
            try snapshot(thumbnail, "\(language)/quick-access")
            thumbnail.closeFromCommand()
            RecordingUITestSupport.spinRunLoop(0.35)
        }
    }

    // MARK: OCR and QR results

    func testOCRResultWindowFitsEachLanguage() throws {
        let lines: [OCRLine] = [
            ["Item", "Qty", "Price"], ["Pens", "12", "3.50"], ["Paper", "5", "8.00"],
        ].enumerated().flatMap { row, cells in
            cells.enumerated().map { column, text in
                OCRLine(text: text, box: CGRect(x: 20 + column * 160, y: 30 + row * 40, width: text.count * 11, height: 18))
            }
        } + [
            OCRLine(text: "Order online at https://shotnix.com/store", box: CGRect(x: 20, y: 200, width: 420, height: 18)),
            OCRLine(text: "Questions: hello@shotnix.com", box: CGRect(x: 20, y: 240, width: 300, height: 18)),
        ]
        let result = OCRResult(lines: lines)
        for language in Self.languages {
            L10n.use(language)
            let window = OCRResultWindow(result: result)
            windows.append(window)
            let root = try XCTUnwrap(window.contentView)
            XCTAssertEqual(Self.clipped(in: root), [], language)
            let buttons = RecordingUITestSupport.allSubviews(of: root).compactMap { $0 as? NSButton }.filter { $0.controlSize == .regular }.sorted { $0.frame.minX < $1.frame.minX }
            XCTAssertEqual(buttons.count, 3, language)
            for (left, right) in zip(buttons, buttons.dropFirst()) {
                XCTAssertLessThanOrEqual(left.frame.maxX, right.frame.minX, "\(language): \(left.title) and \(right.title) don't overlap")
            }
            XCTAssertGreaterThanOrEqual(buttons.first?.frame.minX ?? 0, 24, language)
            try snapshot(window, "\(language)/ocr-result")
        }
    }

    func testQRResultWindowFitsEachLanguage() throws {
        // English too: its longer actions (Compose Email, Open Messages) now fit their buttons.
        for language in ["en"] + Self.languages {
            L10n.use(language == "en" ? nil : language)
            for (name, payload) in [("sms", "SMSTO:+15551234567:See you at noon"), ("wifi", "WIFI:S:Studio;T:WPA;P:hunter2;;"), ("email", "mailto:hello@shotnix.com?subject=Hi")] {
                QRCodeResultWindow.show(results: [QRCodeResult(payload: payload)])
                let window = try XCTUnwrap(NSApp.windows.compactMap { $0 as? QRCodeResultWindow }.first { $0.isVisible })
                windows.append(window)
                let root = try XCTUnwrap(window.contentView)
                XCTAssertEqual(Self.clipped(in: root), [], "\(language): \(name)")
                try snapshot(window, "\(language)/qr-result-\(name)")
                window.close()
            }
        }
    }

    func testCountdownHintFitsEachLanguage() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        for language in ["en"] + Self.languages {
            L10n.use(language == "en" ? nil : language)
            let countdown = CountdownWindow(seconds: 3, on: screen) { _ in }
            windows.append(countdown)
            if language == "en" { XCTAssertEqual(countdown.frame.width, 220, "English keeps its size") }
            let root = try XCTUnwrap(countdown.contentView)
            XCTAssertEqual(Self.clipped(in: root), [], language)
            for view in RecordingUITestSupport.allSubviews(of: root) where view.superview === root {
                XCTAssertTrue(root.bounds.contains(view.frame), "\(language): the hint stays inside the window")
            }
            try snapshot(countdown, "\(language)/countdown")
        }
    }

    // MARK: - Helpers

    private func makeHUD() -> RecordingHUDWindow {
        let hud = RecordingHUDWindow()
        hud.elapsedProvider = { 83 }
        hud.configure(systemAudio: true, microphone: true, camera: true, keystrokes: true, fps: 60, quality: RecordingQuality.high.displayName)
        hud.setFrameOrigin(RecordingUITestSupport.offscreen)
        hud.orderFrontRegardless()
        return hud
    }

    /// Labels and buttons whose text is wider than they are.
    private static func clipped(in root: NSView) -> [String] {
        RecordingUITestSupport.allSubviews(of: root).compactMap { view -> String? in
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            if let field = view as? NSTextField, !field.isEditable, field.cell?.wraps == false {
                guard !field.stringValue.isEmpty else { return nil }
                let needed = field.intrinsicContentSize.width
                return needed > field.frame.width + 0.5 ? "“\(field.stringValue)” needs \(needed), has \(field.frame.width)" : nil
            }
            if let button = view as? NSButton, !button.title.isEmpty, button.bezelStyle == .rounded {
                let needed = TextFitting.width(of: button.title, font: button.font ?? .systemFont(ofSize: 13)) + (button.controlSize == .small ? 14 : 20)
                return needed > button.frame.width ? "button “\(button.title)” needs \(needed), has \(button.frame.width)" : nil
            }
            if let button = view as? NSButton, button.attributedTitle.length > 0, !button.isBordered {
                let needed = ceil(button.attributedTitle.size().width) + 8
                return needed > button.frame.width ? "button “\(button.attributedTitle.string)” needs \(needed), has \(button.frame.width)" : nil
            }
            return nil
        }
    }

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        TextFitting.width(of: text, font: font)
    }

    private func makeSelection() -> (NSWindow, SelectionOverlayView) {
        // The size of a 13-inch MacBook's screen.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = SelectionOverlayView(mode: .area, frozenImage: nil)
        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window.contentView = view
        windows.append(window)
        return (window, view)
    }

    private func drag(_ view: SelectionOverlayView, in window: NSWindow, from start: CGPoint, to end: CGPoint) {
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: start, in: window))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), in: window))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: end, in: window))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: end, in: window))
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    // MARK: Snapshots

    private static var snapshotFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-l10n-capture", isDirectory: true)
    }

    /// A window's content over a desktop-like backdrop, 2x.
    private func snapshot(_ window: NSWindow, _ name: String) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        view.display()
        try write(view: view, backdrop: NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.52, alpha: 1), name: name)
    }

    /// The selection overlay over a light page, like a screen being captured.
    private func snapshotSelection(_ view: SelectionOverlayView, in window: NSWindow, _ name: String) throws {
        let backdrop = NSImageView(frame: view.bounds)
        backdrop.image = NSImage(size: view.bounds.size, flipped: false) { rect in
            NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: rect, angle: 35)
            NSColor.white.withAlphaComponent(0.9).setFill()
            for row in 0..<16 {
                NSBezierPath(roundedRect: NSRect(x: 80, y: 720 - row * 44, width: 620 - row * 14, height: 14), xRadius: 4, yRadius: 4).fill()
            }
            return true
        }
        let container = NSView(frame: view.bounds)
        container.addSubview(backdrop)
        view.removeFromSuperview()
        container.addSubview(view)
        window.contentView = container
        defer {
            view.removeFromSuperview()
            window.contentView = view
        }
        try write(view: container, backdrop: nil, name: name)
    }

    /// NSMenu can't be photographed offscreen: draw its items as the menu
    /// lays them out (it sizes itself to the longest title, so nothing is cut).
    private func snapshot(menu: NSMenu, _ name: String) throws {
        let font = NSFont.menuFont(ofSize: 0)
        var rows: [(text: String, indent: Int, enabled: Bool, checked: Bool, separator: Bool)] = []
        for item in menu.items {
            if item.isSeparatorItem { rows.append(("", 0, true, false, true)); continue }
            rows.append((item.title + (item.hasSubmenu ? "  ▸" : ""), item.indentationLevel, item.isEnabled, item.state == .on, false))
            for sub in item.submenu?.items ?? [] {
                rows.append((sub.title, 2, true, sub.state == .on, false))
            }
        }
        let rowHeight: CGFloat = 22
        let width = (rows.map { Self.width($0.text, font) + CGFloat($0.indent) * 12 }.max() ?? 100) + 60
        let height = CGFloat(rows.count) * rowHeight + 12
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
        panel.layer?.cornerRadius = 8
        for (index, row) in rows.enumerated() {
            let y = height - 6 - CGFloat(index + 1) * rowHeight
            if row.separator {
                let line = NSView(frame: NSRect(x: 10, y: y + rowHeight / 2, width: width - 20, height: 1))
                line.wantsLayer = true
                line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
                panel.addSubview(line)
                continue
            }
            let label = NSTextField(labelWithString: (row.checked ? "✓ " : "") + row.text)
            label.font = font
            label.textColor = row.enabled ? .white : NSColor.white.withAlphaComponent(0.4)
            label.frame = NSRect(x: 22 + CGFloat(row.indent) * 12 - (row.checked ? 14 : 0), y: y + 2, width: width - 30, height: rowHeight - 4)
            panel.addSubview(label)
        }
        try write(view: panel, backdrop: NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.52, alpha: 1), name: name)
    }

    private func write(view: NSView, backdrop: NSColor?, name: String) throws {
        let size = view.bounds.size
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        let padding: CGFloat = backdrop == nil ? 0 : 16
        let canvas = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((size.width + padding * 2) * scale), pixelsHigh: Int((size.height + padding * 2) * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        if let backdrop {
            backdrop.setFill()
            NSRect(x: 0, y: 0, width: canvas.pixelsWide, height: canvas.pixelsHigh).fill()
        }
        rep.draw(in: NSRect(x: padding * scale, y: padding * scale, width: size.width * scale, height: size.height * scale))
        NSGraphicsContext.restoreGraphicsState()
        let url = Self.snapshotFolder.appendingPathComponent("\(name).png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(canvas.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT-L10N: \(url.path)")
    }
}
