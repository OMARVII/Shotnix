import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import ShotnixCore

/// The new editor surfaces rendered offscreen (printed as SNAPSHOT: …):
/// cards, transitions, recordings, music, click sounds, images, caption
/// looks, the export sheet and its pill, and the storage row.
@MainActor
final class VideoFeatureSnapshotTests: XCTestCase {
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
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-feature-snaps-\(UUID().uuidString)", isDirectory: true)
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
        try await Task.sleep(nanoseconds: 400_000_000)
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

    private func model(seconds: Double = 12) async throws -> VideoEditorModel {
        let url = directory.appendingPathComponent("recording.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 1440, height: 900), seconds: seconds, fps: 30, audioSeconds: seconds)
        let (samples, clicks) = VideoTestSupport.scriptedPointer(duration: seconds)
        var metadata = VideoDemoRecordingMetadata(videoURLPath: url.path, createdAt: Date(), duration: seconds, sourceWidth: 1440, sourceHeight: 900, fps: 30, nativeCursorVisible: false, cursorSamples: samples, clickEvents: clicks, pointPixelScale: 2, renderCursor: true)
        metadata.audioTracks = [.microphone]
        XCTAssertTrue(VideoDemoSidecarStore.save(metadata, for: url))
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        try await Task.sleep(nanoseconds: 600_000_000)
        return model
    }

    func testFramingSurfaces() async throws {
        let model = try await model()
        let full = CGSize(width: 1512, height: 944)

        // Cards, a dissolve at a cut, and a second recording.
        model.setIntroEnabled(true)
        model.setOutroEnabled(true)
        model.seek(to: 6)
        model.splitAtPlayhead()
        model.setStyle { $0.transitions.betweenClips = .dissolve }
        let second = directory.appendingPathComponent("second.mp4")
        try await VideoInspection.writeColorVideo(to: second, size: CGSize(width: 1280, height: 720), colors: [(NSColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1), 3)])
        let appended = await model.appendVideo(second)
        XCTAssertTrue(appended)
        model.selection = .none
        model.inspectorTab = .background
        model.seek(to: 1.2)
        try await render(VideoEditorRootView(model: model), size: full, name: "80-style-cards-transitions")
        try await render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 1900), name: "81-style-inspector-tall")

        // Music (a short tone) and click sounds.
        let song = directory.appendingPathComponent("Calm Theme.m4a")
        try VideoInspection.writeTone(to: song, frequency: 330, seconds: 8, amplitude: 0.4)
        await model.addMusic(from: song)
        model.setStyle { $0.clickSounds.enabled = true }
        try await Task.sleep(nanoseconds: 900_000_000)
        model.inspectorTab = .audio
        try await render(VideoEditorRootView(model: model), size: full, name: "82-audio-music")
        try await render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 1100), name: "83-audio-inspector-tall")
        let height = 44 + 1 + VideoTimelineMetrics.contentHeight(model.project) + 10
        try await render(VideoTimelineView(model: model), size: CGSize(width: 1400, height: height), name: "84-timeline-extras")

        // An image annotation, selected.
        let logo = directory.appendingPathComponent("Logo.png")
        try VideoInspection.writePNG(to: logo, size: CGSize(width: 300, height: 120), color: NSColor(srgbRed: 1, green: 0.42, blue: 0.2, alpha: 1))
        model.seek(to: 4)
        let image = model.addImageOverlay(from: logo)
        XCTAssertNotNil(image)
        try await render(VideoEditorRootView(model: model), size: full, name: "85-image-selected")

        // A cut's transition in the clip inspector.
        if let clip = model.segments.dropFirst().first {
            model.selection = .clip(clip.id)
            try await render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 900), name: "86-clip-transition")
        }
        model.selection = .none
    }

    func testCaptionLooksAndTranslation() async throws {
        let model = try await model()
        let words: [(String, Double)] = [("Open", 1.0), ("the", 1.3), ("settings", 1.45), ("panel.", 1.9), ("Then", 3.0), ("pick", 3.3), ("a", 3.5), ("theme", 3.6)]
        model.mutate { $0.captions = VideoCaptionBuilder.lines(from: words.map { VideoCaptionWord(text: $0.0, start: $0.1, end: $0.1 + 0.3) }) }
        model.mutate { $0.captionStyle.preset = .highlight }
        UserDefaults.standard.set("captions", forKey: "videoScriptMode")
        model.inspectorTab = .captions
        model.seek(to: 1.6)
        try await render(VideoEditorRootView(model: model), size: CGSize(width: 1512, height: 944), name: "87-captions-looks")
        try await render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 1200), name: "88-captions-inspector-tall")
        UserDefaults.standard.set("transcript", forKey: "videoScriptMode")
    }

    func testExportSheetStatesAndPill() async throws {
        let model = try await model(seconds: 6)
        let full = CGSize(width: 1512, height: 944)
        model.mutate { $0.captions = [VideoCaptionLine(start: 0.5, end: 2.5, text: "Hello there")] }
        model.selection = .range(VideoDemoTimelineRange(start: 1, end: 3.5))
        model.isExportPresented = true
        try await render(VideoEditorRootView(model: model), size: full, name: "90-export-options")
        // Captions hidden in the editor: the burn-in switch stands down.
        model.setStyle { $0.captionStyle.visible = false }
        try await render(VideoExportSheet(model: model), size: CGSize(width: 900, height: 900), name: "97-export-captions-hidden")
        model.setStyle { $0.captionStyle.visible = true }
        model.selection = .none
        model.exportSettings.format = .gif
        model.exportSettings.gifSize = .large
        model.exportSettings.gifFPS = 24
        model.mutate { project in
            project.timelineClips = [VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 6, speed: 0.25)]
        }
        try await render(VideoExportSheet(model: model), size: CGSize(width: 900, height: 900), name: "91-export-gif-warning")
        model.exportSettings.format = .mp4

        // A real background export: the pill, then the finished sheet.
        model.exportSettings.resolution = .p720
        model.exportSettings.endCard = false
        model.enqueueExport(to: directory.appendingPathComponent("Pill Demo.mp4"), settings: model.exportSettings, toClipboard: false)
        model.isExportPresented = false
        try await render(VideoEditorRootView(model: model), size: full, name: "92-export-pill-running")
        let job = try XCTUnwrap(model.exportJobs.last)
        let deadline = Date().addingTimeInterval(60)
        while !job.isDone, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        try await Task.sleep(nanoseconds: 300_000_000)
        try await render(VideoEditorRootView(model: model), size: full, name: "93-export-pill-finished")
        XCTAssertEqual(model.exportPhase, .idle, "finished with the sheet closed: the pill has it")
        model.isExportPresented = true
        model.exportPhase = .finished(url: job.destination, bytes: 9_700_000, copied: false)
        try await render(VideoExportSheet(model: model), size: CGSize(width: 900, height: 700), name: "94-export-finished-share")
        VideoExportQueue.shared.dismiss(job)
        model.stop()
    }

    func testStorageRow() async throws {
        try await render(RecordingSettingsView().background(Color(white: 0.13)), size: CGSize(width: 620, height: 1180), name: "95-settings-storage")
    }

    func testExportSheetFitsTheSmallestWindow() async throws {
        let model = try await model(seconds: 4)
        model.mutate { $0.captions = [VideoCaptionLine(start: 0.5, end: 2.5, text: "Hello there")] }
        model.isExportPresented = true
        try await render(VideoEditorRootView(model: model), size: CGSize(width: 1080, height: 700), name: "96-export-min-window")
        model.isExportPresented = false
        model.stop()
    }
}
