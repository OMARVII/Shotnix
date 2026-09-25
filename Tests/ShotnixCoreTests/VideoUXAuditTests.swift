import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Renders the whole editor in every state a user can reach — each tab,
/// each kind of selection, the overlays, the smallest window — into PNGs
/// (printed as SNAPSHOT: …) for a visual pass before a release.
@MainActor
final class VideoUXAuditTests: XCTestCase {
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

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-ux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func render<V: View>(_ view: V, size: CGSize, name: String) async throws -> URL {
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
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-ux", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = out.appendingPathComponent("\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT: \(url.path)")
        return url
    }

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
        context?.setFillColor(NSColor(srgbRed: 0.2, green: 0.3, blue: 0.55, alpha: 1).cgColor)
        context?.fillEllipse(in: CGRect(x: 95, y: -40, width: 130, height: 110))
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

    private func richModel(size: CGSize = CGSize(width: 1440, height: 900), seconds: Double = 12, camera: Bool = true) async throws -> VideoEditorModel {
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
        if camera {
            let footage = try await recordCamera(seconds: seconds + 0.5)
            metadata.webcam = VideoWebcamRecording(path: footage.url.path, offset: -0.2, width: Double(footage.size.width), height: Double(footage.size.height))
        }
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

    func testEveryEditorState() async throws {
        let model = try await richModel()
        let full = CGSize(width: 1512, height: 944)
        model.selection = .none
        model.inspectorTab = .background
        try await render(VideoEditorRootView(model: model), size: full, name: "01-fresh-style")
        try await render(VideoEditorRootView(model: model), size: CGSize(width: 1080, height: 700), name: "02-min-window")
        try await render(VideoEditorRootView(model: model), size: CGSize(width: 1280, height: 800), name: "03-laptop")

        for (index, tab) in [VideoEditorModel.InspectorTab.cursor, .zoom, .camera, .captions, .audio].enumerated() {
            model.inspectorTab = tab
            try await render(VideoEditorRootView(model: model), size: full, name: "1\(index)-tab-\(tab)")
        }

        addWords(model)
        model.seek(to: 1.7)
        model.inspectorTab = .captions
        UserDefaults.standard.set("transcript", forKey: "videoScriptMode")
        try await render(VideoEditorRootView(model: model), size: full, name: "20-script-transcript")
        UserDefaults.standard.set("captions", forKey: "videoScriptMode")
        try await render(VideoEditorRootView(model: model), size: full, name: "21-script-captions")
        UserDefaults.standard.set("transcript", forKey: "videoScriptMode")

        // Selections.
        model.seek(to: 3)
        model.addOverlay(.text)
        try await render(VideoEditorRootView(model: model), size: full, name: "30-select-text")
        model.seek(to: 5)
        model.addOverlay(.arrow)
        try await render(VideoEditorRootView(model: model), size: full, name: "31-select-arrow")
        model.seek(to: 6.5)
        model.addOverlay(.highlight)
        try await render(VideoEditorRootView(model: model), size: full, name: "32-select-highlight")
        model.seek(to: 8.5)
        model.addOverlay(.blur)
        try await render(VideoEditorRootView(model: model), size: full, name: "33-select-blur")
        if let zoom = model.project.zoomRegions.first {
            model.selection = .zoom(zoom.id)
            try await render(VideoEditorRootView(model: model), size: full, name: "34-select-zoom")
        }
        if let clip = model.project.timelineClips.first {
            model.selection = .clip(clip.id)
            try await render(VideoEditorRootView(model: model), size: full, name: "35-select-clip")
        }
        if let caption = model.project.captions.first {
            model.selection = .caption(caption.id)
            try await render(VideoEditorRootView(model: model), size: full, name: "36-select-caption")
        }
        if let key = model.project.keystrokes.first {
            model.selection = .keystroke(key.id)
            try await render(VideoEditorRootView(model: model), size: full, name: "37-select-keystroke")
        }
        model.addCameraIntroOutro()
        if let layout = model.project.cameraLayouts.first {
            model.selection = .cameraLayout(layout.id)
            try await render(VideoEditorRootView(model: model), size: full, name: "38-select-camera-layout")
        }
        if let click = model.project.clickEvents.first {
            model.selection = .click(click.id)
            try await render(VideoEditorRootView(model: model), size: full, name: "39-select-click")
        }
        model.selection = .none

        // Modes and overlays.
        model.beginCrop()
        try await render(VideoEditorRootView(model: model), size: full, name: "40-crop")
        model.endCrop()
        model.isExportPresented = true
        try await render(VideoEditorRootView(model: model), size: full, name: "41-export-mp4")
        model.exportSettings.format = .gif
        try await render(VideoEditorRootView(model: model), size: full, name: "42-export-gif")
        model.exportSettings.format = .mp4
        model.isExportPresented = false
        model.isCommandPalettePresented = true
        try await render(VideoEditorRootView(model: model), size: full, name: "43-command-palette")
        model.isCommandPalettePresented = false
        model.isShortcutsPresented = true
        try await render(VideoEditorRootView(model: model), size: full, name: "44-shortcuts")
        model.isShortcutsPresented = false

        model.setAspect(.vertical)
        try await render(VideoEditorRootView(model: model), size: full, name: "45-vertical-reframe")
        try await render(VideoEditorRootView(model: model), size: CGSize(width: 1080, height: 700), name: "46-vertical-min-window")
    }

    func testProgressAndResultStates() async throws {
        let model = try await richModel(camera: false)
        let full = CGSize(width: 1512, height: 944)
        model.isExportPresented = true
        model.exportPhase = .running(progress: 0.42, started: Date().addingTimeInterval(-6), destination: directory.appendingPathComponent("out.mp4"), toClipboard: false)
        try await render(VideoEditorRootView(model: model), size: full, name: "60-export-running")
        model.exportPhase = .finished(url: directory.appendingPathComponent("out.mp4"), bytes: 18_400_000, copied: false)
        try await render(VideoEditorRootView(model: model), size: full, name: "61-export-finished")
        model.exportPhase = .finished(url: directory.appendingPathComponent("out.mp4"), bytes: 18_400_000, copied: true)
        try await render(VideoEditorRootView(model: model), size: full, name: "62-export-copied")
        model.exportPhase = .failed("The disk is full.")
        try await render(VideoEditorRootView(model: model), size: full, name: "63-export-failed")
        model.exportPhase = .idle
        model.isExportPresented = false

        model.inspectorTab = .captions
        model.captionJob = VideoCaptionJob(stage: .transcribing(0.35))
        try await render(VideoEditorRootView(model: model), size: full, name: "64-transcribing")
        model.captionJob = VideoCaptionJob(stage: .transcribing(0.35), error: "Speech recognition isn't allowed. Turn it on in System Settings → Privacy & Security → Speech Recognition.")
        try await render(VideoEditorRootView(model: model), size: full, name: "65-transcribe-failed")
        model.captionJob = nil

        model.inspectorTab = .audio
        model.voiceJob = 0.6
        try await render(VideoEditorRootView(model: model), size: full, name: "66-voice-enhancing")
        model.voiceJob = nil
        model.voiceError = "Couldn't enhance the voice: the audio couldn't be read."
        try await render(VideoEditorRootView(model: model), size: full, name: "67-voice-failed")
        model.voiceError = nil
    }

    func testPortraitAndSilentRecordings() async throws {
        let model = try await richModel(size: CGSize(width: 1080, height: 1920), seconds: 6, camera: false)
        XCTAssertEqual(model.project.aspectPreset, .source, "a tall recording keeps its own shape")
        try await render(VideoEditorRootView(model: model), size: CGSize(width: 1512, height: 944), name: "50-portrait-recording")
        model.inspectorTab = .camera
        try await render(VideoEditorRootView(model: model), size: CGSize(width: 1512, height: 944), name: "51-no-camera-tab")
        model.inspectorTab = .captions
        try await render(VideoEditorRootView(model: model), size: CGSize(width: 1512, height: 944), name: "52-script-empty")
    }
}
