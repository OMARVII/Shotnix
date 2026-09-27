import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import ShotnixCore

/// The video editor in German, French, and Simplified Chinese, where longer
/// words crowd first: the toolbar and the dock, each inspector tab and
/// selection, the timeline's lanes, the command palette, the shortcuts
/// sheet, every page of tips, and cropping. Written to
/// shotnix-ux-l10n/<language>/ (printed as SNAPSHOT: …) for a visual pass;
/// VideoUXAuditTests renders the same states in English.
@MainActor
final class VideoEditorLocalizedSnapshotTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
        VideoStageView.drawsStills = true
    }

    override class func tearDown() {
        VideoStageView.drawsStills = false
        super.tearDown()
    }

    private var directory: URL!
    /// The editor's defaults these renders change, put back afterwards.
    private static let defaultsKeys = ["videoEditorTipsDismissed", "videoEditorTipPage", "videoScriptMode"]
    private var savedDefaults: [String: Any] = [:]

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-l10n-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for key in Self.defaultsKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
    }

    override func tearDown() async throws {
        L10n.use(nil)
        for key in Self.defaultsKeys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testGerman() async throws { try await renderEveryState(in: "de") }
    func testFrench() async throws { try await renderEveryState(in: "fr") }
    func testChinese() async throws { try await renderEveryState(in: "zh-Hans") }
    /// The same states in English, to set beside the others.
    func testEnglish() async throws { try await renderEveryState(in: "en") }

    private let full = CGSize(width: 1512, height: 944)
    private let smallest = CGSize(width: 1080, height: 700)

    // MARK: The states

    private func renderEveryState(in language: String) async throws {
        L10n.use(language)
        if language != "en" {
            XCTAssertNotEqual(L("Keyboard Shortcuts"), "Keyboard Shortcuts", "\(language) resolves")
        }
        let model = try await richModel()
        func render<V: View>(_ view: V, _ name: String, size: CGSize? = nil, tipPage: Int = 0) async throws {
            // The tips bar shows the next page in each new window: start
            // every render on a known page so renders can be compared.
            UserDefaults.standard.set(tipPage, forKey: "videoEditorTipPage")
            try await Self.render(view, size: size ?? full, language: language, name: name)
        }
        let editor = { VideoEditorRootView(model: model) }
        let defaults = UserDefaults.standard

        // The toolbar, the dock, the transcription suggestion, and the Style tab.
        model.selection = .none
        model.inspectorTab = .background
        defaults.set(false, forKey: "videoEditorTipsDismissed")
        try await render(editor(), "01-editor")
        try await render(editor(), "02-smallest-window", size: smallest)

        // Every tab, and the Style tab scrolled to its end.
        for (index, tab) in VideoEditorModel.InspectorTab.allCases.enumerated() {
            model.inspectorTab = tab
            try await render(VideoInspectorView(model: model), "1\(index)-tab-\(tab.rawValue)", size: CGSize(width: 318, height: 1500))
        }
        model.inspectorTab = .audio
        model.voiceJob = 0.6
        try await render(VideoInspectorView(model: model), "16-voice-enhancing", size: CGSize(width: 318, height: 900))
        model.voiceJob = nil
        model.inspectorTab = .captions
        model.captionJob = VideoCaptionJob(stage: .transcribing(0.4), started: Date().addingTimeInterval(-65))
        try await render(VideoInspectorView(model: model), "17-transcribing", size: CGSize(width: 318, height: 560))
        model.captionJob = nil

        // Words: edit by text, captions, and the tips (no suggestion once transcribed).
        addWords(model)
        model.seek(to: 1.7)
        defaults.set("transcript", forKey: "videoScriptMode")
        try await render(editor(), "20-edit-by-text")
        defaults.set("captions", forKey: "videoScriptMode")
        try await render(VideoInspectorView(model: model), "21-captions", size: CGSize(width: 318, height: 1100))
        defaults.set("transcript", forKey: "videoScriptMode")
        model.inspectorTab = .background
        for page in 0..<VideoTipsBar.pages.count {
            try await render(editor(), "2\(page + 2)-tips-page-\(page + 1)", size: smallest, tipPage: page)
        }

        // Selections, one kind at a time: in the editor, and the whole of
        // their settings in a tall inspector.
        let tall = CGSize(width: 318, height: 1500)
        func renderSelection(_ name: String) async throws {
            try await render(editor(), "3\(name)")
            try await render(VideoInspectorView(model: model), "3\(name)-inspector", size: tall)
        }
        model.seek(to: 3)
        model.addOverlay(.text)
        try await renderSelection("0-select-text")
        model.seek(to: 5)
        model.addOverlay(.arrow)
        try await renderSelection("1-select-arrow")
        model.seek(to: 6.5)
        model.addOverlay(.spotlight)
        try await renderSelection("2-select-spotlight")
        model.seek(to: 8.5)
        model.addOverlay(.blur)
        if let zoom = model.project.zoomRegions.first {
            model.selection = .zoom(zoom.id)
            try await renderSelection("3-select-zoom")
        }
        if let clip = model.project.timelineClips.first {
            model.selection = .clip(clip.id)
            try await renderSelection("4-select-clip")
        }
        if let caption = model.project.captions.first {
            model.selection = .caption(caption.id)
            try await renderSelection("5-select-caption")
        }
        if let key = model.project.keystrokes.first {
            model.selection = .keystroke(key.id)
            try await renderSelection("6-select-shortcut")
        }
        model.addCameraIntroOutro()
        if let layout = model.project.cameraLayouts.first {
            model.selection = .cameraLayout(layout.id)
            try await renderSelection("7-select-camera-layout")
        }
        if let click = model.project.clickEvents.first {
            model.selection = .click(click.id)
            try await renderSelection("8-select-click")
        }
        model.selection = .range(VideoDemoTimelineRange(start: 8, end: 10))
        try await renderSelection("9-select-range")
        if let text = model.project.overlayEffects.first?.id, let zoom = model.project.zoomRegions.first?.id {
            model.selection = .overlay(text)
            model.toggleSelection(.zoom(zoom))
            if let clip = model.project.timelineClips.first?.id { model.toggleSelection(.clip(clip)) }
            try await render(editor(), "40-select-several")
        }
        model.selection = .none

        // The timeline with every lane: captions, shortcuts, camera layouts,
        // annotations, zooms, clicks, cards, and a cut.
        model.setIntroEnabled(true)
        model.setOutroEnabled(true)
        model.mutate { _ = $0.removeSourceRanges([9.0...9.6], totalDuration: 12) }
        model.endGesture()
        let height = 44 + 1 + VideoTimelineMetrics.contentHeight(model.project) + 10
        try await render(VideoTimelineView(model: model), "41-timeline-lanes", size: CGSize(width: 1512, height: height))
        try await render(VideoTimelineView(model: model), "42-timeline-lanes-narrow", size: CGSize(width: 1080, height: height))

        // Overlays: the palette, the shortcuts (with the way back to the tips), cropping.
        model.isCommandPalettePresented = true
        try await render(editor(), "50-command-palette")
        try await render(editor(), "51-command-palette-smallest-window", size: smallest)
        model.isCommandPalettePresented = false
        defaults.set(true, forKey: "videoEditorTipsDismissed")
        model.isShortcutsPresented = true
        try await render(editor(), "52-shortcuts")
        try await render(editor(), "53-shortcuts-smallest-window", size: smallest)
        model.isShortcutsPresented = false
        defaults.set(false, forKey: "videoEditorTipsDismissed")
        model.beginCrop()
        try await render(editor(), "54-crop")
        try await render(editor(), "55-crop-smallest-window", size: smallest)
        model.endCrop()

        // A file that isn't a video.
        let text = directory.appendingPathComponent("notes.mp4")
        try Data("not a video".utf8).write(to: text)
        let unreadable = VideoEditorModel(videoURL: text)
        await unreadable.load()
        try await render(VideoEditorRootView(model: unreadable), "56-unreadable-file", size: smallest)

        // The dock with the annotation names in this language (the video
        // features area names them; its words, as agreed, stand in here).
        let names = Self.dockNames[language] ?? []
        let dock = HStack(spacing: 2) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                VideoDockButton(title: name, symbol: VideoDemoOverlayEffectKind.allCases[index].icon, tint: .purple, active: index == 0, help: "") {}
            }
        }
        .padding(8)
        .background(Color.black)
        try await render(dock, "57-dock-names", size: CGSize(width: 560, height: 60))
    }

    /// Text, arrow, highlight, blur, spotlight, image.
    private static let dockNames = [
        "en": ["Text", "Arrow", "Highlight", "Blur", "Spotlight", "Image"],
        "de": ["Text", "Pfeil", "Markierung", "Weichzeichnen", "Fokus", "Bild"],
        "fr": ["Texte", "Flèche", "Surlignage", "Flouter", "Projecteur", "Image"],
        "zh-Hans": ["文字", "箭头", "高亮", "模糊", "聚光灯", "图像"],
    ]

    /// The command palette's rows, one per command in this language.
    func testPaletteTitlesAreTranslated() async throws {
        let model = try await VideoEditorTestModel.make(in: directory)
        for language in L10n.translations {
            L10n.use(language)
            let english = Set(["Export…", "Split at Playhead", "Keyboard Shortcuts", "Go to Start", "Show Recording in Finder"])
            let titles = VideoCommandPalette(model: model).commands.map(\.title)
            XCTAssertTrue(english.isDisjoint(with: titles), "\(language): \(english.intersection(titles))")
            XCTAssertEqual(Set(titles).count, titles.count, "\(language): two commands share a title")
        }
    }

    // MARK: Rendering

    private static func render<V: View>(_ view: V, size: CGSize, language: String, name: String) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 350_000_000)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-ux-l10n/\(language)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = out.appendingPathComponent("\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT: \(url.path)")
    }

    // MARK: A recording with everything

    /// Camera footage through the recorder's own pipeline.
    private func recordCamera(seconds: Double) async throws -> CameraPipeline.Result {
        let pipeline = CameraPipeline()
        let url = directory.appendingPathComponent("camera.mov")
        pipeline.begin(url: url)
        let size = CGSize(width: 320, height: 180)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let frame = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(frame), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(frame), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.setFillColor(NSColor(srgbRed: 0.36, green: 0.42, blue: 0.5, alpha: 1).cgColor)
        context?.fill(CGRect(origin: .zero, size: size))
        context?.setFillColor(NSColor(srgbRed: 0.93, green: 0.75, blue: 0.62, alpha: 1).cgColor)
        context?.fillEllipse(in: CGRect(x: 125, y: 70, width: 70, height: 80))
        CVPixelBufferUnlockBaseAddress(frame, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame, formatDescriptionOut: &format)
        for index in 0..<Int(seconds * 30) {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: 500 + Double(index) / 30, preferredTimescale: 60000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: frame, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
            nonisolated(unsafe) let ready = sample!
            try await Task.sleep(nanoseconds: 2_000_000)
            pipeline.queue.sync { pipeline.append(ready) }
        }
        let result = await pipeline.finish()
        return try XCTUnwrap(result)
    }

    private func richModel(seconds: Double = 12) async throws -> VideoEditorModel {
        let size = CGSize(width: 1440, height: 900)
        let url = directory.appendingPathComponent("recording.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: size, seconds: seconds, fps: 30, audioSeconds: seconds)
        let (samples, clicks) = VideoTestSupport.scriptedPointer(duration: seconds)
        var metadata = VideoDemoRecordingMetadata(videoURLPath: url.path, createdAt: Date(), duration: seconds, sourceWidth: Double(size.width), sourceHeight: Double(size.height), fps: 30, nativeCursorVisible: false, cursorSamples: samples, clickEvents: clicks, pointPixelScale: 2, renderCursor: true)
        metadata.keystrokes = [
            VideoKeystrokeEvent(time: 2.0, keys: ["⌘", ","]),
            VideoKeystrokeEvent(time: 5.2, keys: ["⇧", "⌘", "S"]),
            VideoKeystrokeEvent(time: 8.0, keys: ["⌘", "Z"]),
        ]
        metadata.audioTracks = [.microphone]
        let footage = try await recordCamera(seconds: seconds + 0.5)
        metadata.webcam = VideoWebcamRecording(path: footage.url.path, offset: -0.2, width: Double(footage.size.width), height: Double(footage.size.height))
        XCTAssertTrue(VideoDemoSidecarStore.save(metadata, for: url))
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        try await Task.sleep(nanoseconds: 700_000_000)
        return model
    }

    private func addWords(_ model: VideoEditorModel) {
        let words: [(String, Double)] = [
            ("So", 0.6), ("um,", 0.8), ("open", 1.2), ("the", 1.45), ("settings", 1.6), ("panel.", 2.0),
            ("Then", 4.2), ("pick", 4.45), ("a", 4.65), ("theme", 4.75), ("and", 5.2), ("uh", 5.45), ("save", 5.9), ("it.", 6.15),
            ("That's", 8.6), ("all", 8.9), ("there", 9.1), ("is", 9.35), ("to", 9.5), ("it.", 9.65),
        ]
        let timed = words.map { VideoCaptionWord(text: $0.0, start: $0.1, end: $0.1 + 0.22) }
        model.mutate { $0.captions = VideoCaptionBuilder.lines(from: timed) }
        model.endGesture()
    }
}
