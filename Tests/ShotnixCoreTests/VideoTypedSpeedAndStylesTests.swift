import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Any speed typed beside the buttons; a text annotation's font, weight and
/// letter color; how far a spotlight dims, and toward what.
@MainActor
final class VideoTypedSpeedAndStylesTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!
    private var window: KeyWindow?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-styles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        L10n.use(nil)
        if let directory {
            VideoDemoDraftStore.delete(for: directory.appendingPathComponent("rec.mp4"))
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private typealias T = VideoEditorTestModel

    /// Hidden, but key: the field takes typing as it would in the editor.
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    // MARK: Typed speeds

    func testTypedSpeedsReadAnyWayAndShowTheirSecondDecimal() {
        XCTAssertEqual(VideoEditorModel.parseSpeed("1.3"), 1.3)
        XCTAssertEqual(VideoEditorModel.parseSpeed("1,3"), 1.3, "a French or German decimal comma")
        XCTAssertEqual(VideoEditorModel.parseSpeed(" 1.3× "), 1.3)
        XCTAssertEqual(VideoEditorModel.parseSpeed("1.3x"), 1.3)
        XCTAssertEqual(VideoEditorModel.parseSpeed("2"), 2)
        XCTAssertEqual(VideoEditorModel.parseSpeed("1.234"), 1.23, "to the hundredth")
        XCTAssertEqual(VideoEditorModel.parseSpeed("40"), 16, "no faster than a clip plays")
        XCTAssertEqual(VideoEditorModel.parseSpeed("0.1"), 0.25, "no slower either")
        for junk in ["", "fast", "0", "-2", "1.3.4"] {
            XCTAssertNil(VideoEditorModel.parseSpeed(junk), junk)
        }

        XCTAssertEqual(VideoEditorModel.formatSpeed(1.3), "1.3×")
        XCTAssertEqual(VideoEditorModel.formatSpeed(1.25), "1.25×", "a typed speed keeps its second decimal")
        XCTAssertEqual(VideoEditorModel.formatSpeed(2), "2×")
        XCTAssertEqual(VideoEditorModel.formatSpeed(0.5), "0.5×", "the buttons read as before")
        XCTAssertEqual(VideoEditorModel.formatScale(1.75), "1.8×", "a zoom's scale still rounds to one decimal")
        L10n.use("fr")
        XCTAssertEqual(VideoEditorModel.formatSpeed(1.3), "1,3×")
        XCTAssertEqual(VideoEditorModel.speedNumber(1.25), "1,25")
    }

    /// Typed into the clip panel's field and Return: the clip plays at 1.3×,
    /// and the timeline gets shorter by that much.
    func testTypingASpeedInTheFieldSetsTheClip() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 6))
        model.seek(to: 3)
        model.splitAtPlayhead()
        model.endGesture()
        let clip = try XCTUnwrap(model.segments.first?.id)
        model.selectClip(clip)
        let size = CGSize(width: 318, height: 700)
        let host = NSHostingView(rootView: VideoInspectorView(model: model).frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = KeyWindow(contentRect: NSRect(x: -9000, y: -9000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        self.window = window
        await T.settle(0.6)

        let field = try XCTUnwrap(textField(in: host), "the speed field beside the buttons")
        XCTAssertEqual(field.stringValue, "1", "shows the clip's speed")
        window.makeFirstResponder(field)
        await T.settle(0.2)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        for character in "1.3" + "\r" {
            let key = String(character)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "\r" ? 36 : 0)!
            window.sendEvent(event)
        }
        await T.settle(0.3)
        let speed = try XCTUnwrap(model.project.timelineClips.first { $0.id == clip }?.normalizedSpeed)
        XCTAssertEqual(speed, 1.3, accuracy: 0.001)
        XCTAssertEqual(model.timelineDuration, 3 / 1.3 + 3, accuracy: 0.05)
        XCTAssertEqual(VideoEditorModel.formatSpeed(speed), "1.3×", "its badge on the timeline")

        // A part of several clips takes a typed speed too.
        let whole = VideoDemoTimelineRange(start: 0, end: model.timelineDuration)
        model.setRangeSpeed(whole, try XCTUnwrap(VideoEditorModel.parseSpeed("1,3")))
        XCTAssertEqual(Set(model.project.timelineClips.map(\.normalizedSpeed)), [1.3])
        if case .range(let range) = model.selection {
            XCTAssertEqual(model.rangeSpeed(range) ?? 0, 1.3, accuracy: 0.001, "the field shows it")
        }
        model.stop()
    }

    /// A click lands the caret after the "1" the field shows; typing 1.3
    /// there must not make 11.3×. And Esc puts back what was there.
    func testClickingTheSpeedFieldSelectsItsNumberAndEscPutsItBack() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 6))
        model.seek(to: 3)
        model.splitAtPlayhead()
        model.endGesture()
        let clip = try XCTUnwrap(model.segments.first?.id)
        model.selectClip(clip)
        let size = CGSize(width: 318, height: 700)
        let host = NSHostingView(rootView: ZStack {
            // The editor's keys: Esc in a field goes through it.
            VideoKeyboardBridge(model: model)
            VideoInspectorView(model: model)
        }.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = KeyWindow(contentRect: NSRect(x: -9000, y: -9000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        self.window = window
        await T.settle(0.6)

        let field = try XCTUnwrap(textField(in: host), "the speed field beside the buttons")
        func click() async {
            // Near its right end, past the number, as AppKit takes a click
            // (in a hidden test window SwiftUI's hit testing doesn't reach
            // any text field, the text annotation's included). The click's
            // tracking waits for its mouse-up, so that goes in the queue first.
            let point = field.convert(NSPoint(x: field.bounds.maxX - 2, y: field.bounds.midY), to: nil)
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            NSApp.postEvent(up, atStart: false)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            field.mouseDown(with: down)
            await T.settle(0.3)
        }
        func type(_ text: String) async {
            for character in text {
                let key = String(character)
                let code: UInt16 = key == "\r" ? 36 : key == "\u{1b}" ? 53 : 0
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
                // Esc goes through the app, where the editor's key monitor
                // takes it and leaves the field; the rest types straight in.
                if code == 53 { NSApp.sendEvent(event) } else { window.sendEvent(event) }
            }
            await T.settle(0.3)
        }
        var speed: Double { model.project.timelineClips.first { $0.id == clip }?.normalizedSpeed ?? 0 }

        await click()
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the click starts typing in the field")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 1), "the whole number is selected")
        await type("1.3\r")
        XCTAssertEqual(speed, 1.3, accuracy: 0.001, "the typing replaced the 1 it showed")

        // Typed, then Esc: the clip keeps its speed and the field its number.
        await click()
        await type("13")
        await type("\u{1b}")
        XCTAssertFalse(window.firstResponder is NSText, "Esc leaves the field")
        XCTAssertEqual(speed, 1.3, accuracy: 0.001, "Esc drops what was typed")
        XCTAssertEqual(field.stringValue, "1.3")

        // Leaving it another way still takes what was typed.
        await click()
        await type("2.5")
        window.makeFirstResponder(nil)
        await T.settle(0.3)
        XCTAssertEqual(speed, 2.5, accuracy: 0.001)
        model.stop()
    }

    /// ⌘Z takes each of them back, one step each (a slider drag is one).
    func testEachNewChoiceUndoesInOneStep() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 6))
        model.seek(to: 3)
        model.splitAtPlayhead()
        model.endGesture()
        let clip = try XCTUnwrap(model.segments.first?.id)
        model.seek(to: 1)
        model.addOverlay(.text)
        model.endGesture()
        let text = try XCTUnwrap(model.selectedOverlay?.id)
        model.addOverlay(.spotlight)
        model.endGesture()
        let spot = try XCTUnwrap(model.selectedOverlay?.id)
        func overlay(_ id: UUID) throws -> VideoDemoOverlayEffect { try XCTUnwrap(model.project.overlayEffects.first { $0.id == id }) }
        var speed: Double { model.project.timelineClips.first { $0.id == clip }?.normalizedSpeed ?? 0 }
        // New ones start with the last style picked, whatever that was.
        let (font, weight, color, dim) = (try overlay(text).textFont, try overlay(text).textWeight, try overlay(text).textColor, try overlay(spot).spotlightDim)

        model.setClipSpeed(clip, try XCTUnwrap(VideoEditorModel.parseSpeed("1.3")))
        model.endGesture()
        model.setTextFont(font == .serif ? .mono : .serif, of: text)
        model.endGesture()
        model.setTextWeight(weight == .heavy ? .regular : .heavy, of: text)
        model.endGesture()
        model.setTextColor(VideoRGBA(hex: 0x30D158), of: text)
        model.endGesture()
        model.setSpotlightDim(0.9, of: spot)
        model.setSpotlightDim(0.95, of: spot)
        model.endGesture()

        model.undo()
        XCTAssertEqual(try overlay(spot).spotlightDim, dim, accuracy: 0.001, "the whole drag")
        model.undo()
        XCTAssertEqual(try overlay(text).textColor, color)
        model.undo()
        XCTAssertEqual(try overlay(text).textWeight, weight)
        model.undo()
        XCTAssertEqual(try overlay(text).textFont, font)
        XCTAssertEqual(speed, 1.3, accuracy: 0.001, "not yet")
        model.undo()
        XCTAssertEqual(speed, 1, accuracy: 0.001)
        model.stop()
    }

    private func textField(in view: NSView) -> NSTextField? {
        for sub in view.subviews {
            if let field = sub as? NSTextField, field.isEditable, !field.isHiddenOrHasHiddenAncestor { return field }
            if let found = textField(in: sub) { return found }
        }
        return nil
    }

    // MARK: Spotlight

    private func project(_ effects: [VideoDemoOverlayEffect]) -> VideoDemoProject {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/styles.mp4"), duration: 5, sourceSize: CGSize(width: 1920, height: 1080))
        project.cursor.visible = false
        project.padding = 0
        project.overlayEffects = effects
        return project
    }

    private func render(_ effects: [VideoDemoOverlayEffect], source: CIImage) -> CIImage {
        let plan = VideoDemoExporter.makePlan(project: project(effects), sourceDuration: 5, recording: nil)
        return VideoFrameRenderer().render(source: source, timelineTime: 2, plan: plan, outputSize: CGSize(width: 1920, height: 1080))
    }

    /// The average color of a box (top-left origin).
    private func average(_ image: CIImage, _ rect: CGRect) -> (r: Double, g: Double, b: Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let flipped = CGRect(x: rect.minX, y: 1080 - rect.maxY, width: rect.width, height: rect.height)
        CIContext().render(image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: flipped)]), toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    private var gray: CIImage {
        CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testASpotlightDimsAsFarAsSetAndTowardItsColor() {
        var spot = VideoDemoOverlayEffect(kind: .spotlight, time: 0, duration: 5, x: 0.5, y: 0.5, width: 0.4, height: 0.4)
        let corner = CGRect(x: 100, y: 100, width: 40, height: 40)
        let spotMiddle = CGRect(x: 940, y: 520, width: 40, height: 40)
        let standard = average(render([spot], source: gray), corner).r
        XCTAssertEqual(spot.spotlightDim, 0.58, "spotlights from before dim as they did")

        spot.strength = 0.9
        let deep = render([spot], source: gray)
        XCTAssertLessThan(average(deep, corner).r, standard - 0.15, "darker around the spot")
        XCTAssertEqual(average(deep, spotMiddle).r, 0.8, accuracy: 0.03, "the spot itself untouched")

        spot.strength = nil
        spot.color = VideoRGBA(hex: 0xFFFFFF)
        let light = average(render([spot], source: gray), corner)
        XCTAssertGreaterThan(light.r, 0.85, "dims toward white instead")

        spot.strength = 5
        XCTAssertEqual(spot.spotlightDim, 1, "within its range")
    }

    // MARK: Text

    private func textEffect(_ change: (inout VideoDemoOverlayEffect) -> Void = { _ in }) -> VideoDemoOverlayEffect {
        var effect = VideoDemoOverlayEffect(kind: .text, time: 0, duration: 5, x: 0.5, y: 0.5, width: 0.5, height: 0.16, text: "Settings panel")
        change(&effect)
        return effect
    }

    func testTextTakesItsFontWeightAndColor() {
        let box = CGRect(x: 1920 * 0.3, y: 1080 * 0.45, width: 1920 * 0.4, height: 1080 * 0.1)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        func ink(_ effect: VideoDemoOverlayEffect) -> (r: Double, g: Double, b: Double) {
            average(render([effect], source: black), box)
        }
        let regular = ink(textEffect { $0.weight = .regular }).r
        let semibold = ink(textEffect()).r
        let heavy = ink(textEffect { $0.weight = .heavy }).r
        XCTAssertLessThan(regular, semibold, "thinner letters, less white")
        XCTAssertLessThan(semibold, heavy)

        let serif = ink(textEffect { $0.font = .serif })
        XCTAssertNotEqual(serif.r, semibold, accuracy: 0.002, "another typeface draws other letters")

        let red = ink(textEffect { $0.textColor = VideoRGBA(hex: 0xFF453A) })
        XCTAssertGreaterThan(red.r, red.g * 1.5, "red letters")
        let automatic = ink(textEffect())
        XCTAssertEqual(automatic.r, automatic.g, accuracy: 0.02, "white letters when nothing was picked")
    }

    // MARK: Drafts and new annotations

    func testOldDraftsKeepTheirLookAndNewOnesStartWithTheLastStyle() async throws {
        // A text from before these existed.
        var old = textEffect()
        old.font = nil
        old.weight = nil
        old.textColor = nil
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        for key in ["font", "weight", "textColor"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(VideoDemoOverlayEffect.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.textFont, .system)
        XCTAssertEqual(decoded.textWeight, .semibold)
        XCTAssertNil(decoded.textColor)

        let styled = textEffect { $0.font = .mono; $0.weight = .heavy; $0.textColor = VideoRGBA(hex: 0xFFD60A) }
        XCTAssertEqual(try JSONDecoder().decode(VideoDemoOverlayEffect.self, from: JSONEncoder().encode(styled)), styled)

        let saved = (VideoOverlayStyleMemory.textFont, VideoOverlayStyleMemory.textWeight, VideoOverlayStyleMemory.textColor, VideoOverlayStyleMemory.spotlightDim, VideoOverlayStyleMemory.color(for: .spotlight))
        defer {
            VideoOverlayStyleMemory.textFont = saved.0
            VideoOverlayStyleMemory.textWeight = saved.1
            VideoOverlayStyleMemory.textColor = saved.2
            VideoOverlayStyleMemory.spotlightDim = saved.3
            VideoOverlayStyleMemory.setColor(saved.4, for: .spotlight)
        }
        let model = try await T.make(in: directory)
        model.seek(to: 2)
        model.addOverlay(.text)
        let first = try XCTUnwrap(model.selectedOverlay?.id)
        model.setTextFont(.serif, of: first)
        model.setTextWeight(.bold, of: first)
        model.setTextColor(VideoRGBA(hex: 0xFFD60A), of: first)
        model.endGesture()
        model.addOverlay(.text)
        let next = try XCTUnwrap(model.selectedOverlay)
        XCTAssertNotEqual(next.id, first)
        XCTAssertEqual(next.textFont, .serif, "starts with the last font picked")
        XCTAssertEqual(next.textWeight, .bold)
        XCTAssertEqual(next.textColor, VideoRGBA(hex: 0xFFD60A))

        model.addOverlay(.spotlight)
        let spot = try XCTUnwrap(model.selectedOverlay?.id)
        model.setSpotlightDim(0.8, of: spot)
        model.setOverlayColor(spot, VideoRGBA(hex: 0xFFFFFF))
        model.endGesture()
        model.addOverlay(.spotlight)
        let nextSpot = try XCTUnwrap(model.selectedOverlay)
        XCTAssertEqual(nextSpot.spotlightDim, 0.8, accuracy: 0.001)
        XCTAssertEqual(nextSpot.color, VideoRGBA(hex: 0xFFFFFF))
        model.stop()
    }

    // MARK: How it looks

    /// The speed field beside the buttons, and a text's and a spotlight's
    /// new controls, in English and French (it runs longer).
    func testTheNewControlsRenderInEnglishAndFrench() async throws {
        var options = T.Options(seconds: 9, size: CGSize(width: 1440, height: 900))
        options.audio = true
        let model = try await T.make(in: directory, options)
        model.seek(to: 3)
        model.splitAtPlayhead()
        model.endGesture()
        let clip = try XCTUnwrap(model.segments.first?.id)
        model.setClipSpeed(clip, 1.3)
        model.endGesture()
        model.seek(to: 4)
        model.addOverlay(.text)
        let text = try XCTUnwrap(model.selectedOverlay?.id)
        model.setTextFont(.serif, of: text)
        model.setTextColor(VideoRGBA(hex: 0xFFD60A), of: text)
        model.addOverlay(.spotlight)
        let spot = try XCTUnwrap(model.selectedOverlay?.id)
        model.setSpotlightDim(0.8, of: spot)
        model.endGesture()
        // Past their fade-in, so the preview shows them.
        model.seek(to: 5)
        VideoStageView.drawsStills = true
        defer { VideoStageView.drawsStills = false }
        let full = CGSize(width: 1512, height: 944)
        for language in ["en", "fr"] {
            L10n.use(language == "en" ? nil : language)
            model.selectClip(clip)
            try await VideoEditorFixesSnapshotTests.render(VideoEditorRootView(model: model), size: full, name: "styles-speed-field-\(language)")
            model.selection = .range(VideoDemoTimelineRange(start: 0, end: model.timelineDuration))
            try await VideoEditorFixesSnapshotTests.render(VideoEditorRootView(model: model), size: full, name: "styles-part-speed-\(language)")
            model.selection = .overlay(text)
            try await VideoEditorFixesSnapshotTests.render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 900), name: "styles-text-\(language)")
            model.selection = .overlay(spot)
            try await VideoEditorFixesSnapshotTests.render(VideoEditorRootView(model: model), size: full, name: "styles-spotlight-\(language)")
        }
        model.stop()
    }
}
