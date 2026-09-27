import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import ShotnixCore

/// The export, data, and video-feature surfaces in German, French, and
/// Chinese, rendered offscreen (printed as SNAPSHOT: …, in the shotnix-ux
/// temporary folder) to check that the longer languages fit: the export
/// sheet (MP4, GIF, in and out, running, finished, failed), the export
/// status in the toolbar, the finished-export panel, the post-recording
/// panel, the Clean Up confirmation, the Settings storage row, the caption
/// looks and translation controls, and the Style and Audio sections.
@MainActor
final class VideoFeatureLocalizationSnapshotTests: XCTestCase {
    private static let languages = L10n.translations

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
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-l10n-snaps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        L10n.use(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    private static var output: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-ux", isDirectory: true)
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
        return try write(host, name: name)
    }

    /// An AppKit view as it draws (a panel's or an alert's content).
    @discardableResult
    private func write(_ view: NSView, name: String) throws -> URL {
        view.layoutSubtreeIfNeeded()
        view.display()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        let url = Self.output.appendingPathComponent("l10n-\(name).png")
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

    // MARK: Export

    func testExportSheetInEachLanguage() async throws {
        let model = try await model(seconds: 6)
        model.mutate { $0.captions = [VideoCaptionLine(start: 0.5, end: 2.5, text: "Hello there")] }
        model.setIntroEnabled(true)
        model.setOutroEnabled(true)
        model.selection = .range(VideoDemoTimelineRange(start: 1, end: 3.5))
        let sheet = CGSize(width: 900, height: 900)
        let destination = directory.appendingPathComponent("Onboarding walkthrough (edited).mp4")
        for language in Self.languages {
            L10n.use(language)
            model.exportSettings = VideoExportSettings()
            model.exportSettings.subtitles = .srt
            model.exportPhase = .idle
            try await render(VideoExportSheet(model: model), size: sheet, name: "\(language)-export-mp4")
            try await render(VideoExportSheet(model: model, initialRange: .custom), size: sheet, name: "\(language)-export-in-out")

            // A GIF too big to make, with the lighter suggestion.
            let clips = model.project.timelineClips
            model.mutate { $0.timelineClips = [VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 6, speed: 0.1)] }
            model.exportSettings.format = .gif
            model.exportSettings.gifSize = .large
            model.exportSettings.gifFPS = 24
            try await render(VideoExportSheet(model: model, initialRange: .whole), size: sheet, name: "\(language)-export-gif")
            model.mutate { $0.timelineClips = clips }
            model.exportSettings.format = .mp4

            model.exportPhase = .exporting(progress: 0.42, started: Date().addingTimeInterval(-9), destination: destination, toClipboard: false)
            try await render(VideoExportSheet(model: model), size: CGSize(width: 900, height: 600), name: "\(language)-export-running")
            model.exportPhase = .finished(url: destination, bytes: 9_700_000, copied: false)
            try await render(VideoExportSheet(model: model), size: CGSize(width: 900, height: 600), name: "\(language)-export-finished")
            model.exportPhase = .finished(url: destination, bytes: 9_700_000, copied: true)
            try await render(VideoExportSheet(model: model), size: CGSize(width: 900, height: 600), name: "\(language)-export-copied")
            model.exportPhase = .failed(VideoExportFailure.diskFull)
            try await render(VideoExportSheet(model: model), size: CGSize(width: 900, height: 600), name: "\(language)-export-failed")
            model.exportPhase = .idle
        }
        model.stop()
    }

    /// The status next to Export in the toolbar, while an export runs and
    /// once it's done (the smallest window leaves it the least room), the
    /// list it opens, and the panel a finished export shows when its editor
    /// is closed.
    func testExportStatusInEachLanguage() async throws {
        let model = try await model(seconds: 3)
        model.exportSettings.resolution = .p720
        model.exportSettings.endCard = false
        let smallest = CGSize(width: 1080, height: 700)
        for language in Self.languages {
            L10n.use(language)
            model.enqueueExport(to: directory.appendingPathComponent("\(language) Demo (edited).mp4"), settings: model.exportSettings, toClipboard: false)
            model.isExportPresented = false
            try await render(VideoEditorRootView(model: model), size: smallest, name: "\(language)-toolbar-export-running")
            let job = try XCTUnwrap(model.exportJobs.last)
            let deadline = Date().addingTimeInterval(60)
            while !job.isDone, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            guard case .finished = job.state else { return XCTFail("\(language): the export finishes: \(job.state)") }
            try await Task.sleep(nanoseconds: 300_000_000)
            try await render(VideoEditorRootView(model: model), size: smallest, name: "\(language)-toolbar-export-finished")
            try await render(VideoExportJobsPill(model: model).padding(10).background(Color(white: 0.12)), size: CGSize(width: 340, height: 90), name: "\(language)-toolbar-export-list")

            VideoExportCompletionPanel.show(for: job)
            let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? VideoExportCompletionPanel }.last)
            try await Task.sleep(nanoseconds: 300_000_000)
            try write(try XCTUnwrap(panel.contentView), name: "\(language)-export-finished-panel")
            panel.close()
            VideoExportQueue.shared.dismiss(job)
        }
        model.stop()
    }

    // MARK: Panels and alerts

    /// Buttons as wide as their words; English keeps its exact layout.
    func testPostRecordingPanelInEachLanguage() throws {
        let url = URL(fileURLWithPath: "/tmp/Shotnix 2026-09-27 at 09.41.12.mp4")
        for language in ["en"] + Self.languages {
            L10n.use(language)
            VideoDemoPostRecordingPanel.show(videoURL: url, on: NSScreen.main, openHandler: {})
            let panel = try XCTUnwrap(VideoDemoPostRecordingPanel.visiblePanel)
            let buttons = RecordingUITestSupport.allSubviews(of: try XCTUnwrap(panel.contentView)).compactMap { $0 as? NSButton }.filter { !$0.title.isEmpty }
            XCTAssertEqual(buttons.count, 3)
            for button in buttons {
                XCTAssertLessThanOrEqual(ceil(button.intrinsicContentSize.width), button.frame.width, "\(language): “\(button.title)” fits its button")
                XCTAssertLessThanOrEqual(button.frame.maxX, panel.frame.width - 16, "\(language): “\(button.title)” stays inside the panel")
            }
            if language == "en" {
                XCTAssertEqual(buttons.map(\.frame), [NSRect(x: 16, y: 16, width: 112, height: 30), NSRect(x: 136, y: 16, width: 84, height: 30), NSRect(x: 228, y: 16, width: 98, height: 30)], "the English layout is unchanged")
                XCTAssertEqual(panel.frame.width, 342)
            }
            try write(try XCTUnwrap(panel.contentView), name: "\(language)-post-recording-panel")
            panel.close()
        }
    }

    func testCleanUpConfirmationInEachLanguage() throws {
        func file(_ name: String, megabytes: Double) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(count: Int(megabytes * 1_000_000)).write(to: url)
            return url
        }
        var plan = VideoDataCleanup.Plan()
        plan.missingRecordings = [
            VideoDataCleanup.Recording(key: "id-a", path: "/Users/omar/Movies/Onboarding walkthrough.mov", draft: try file("a-draft.json", megabytes: 0.2), sidecar: try file("a-data.json", megabytes: 1.4)),
            VideoDataCleanup.Recording(key: "id-b", path: "/Volumes/Archive/Talks/Keynote rehearsal.mov", camera: try file("b-camera.mov", megabytes: 6)),
        ]
        plan.unusedCameraFootage = [try file("stray-1.mov", megabytes: 3), try file("stray-2.mov", megabytes: 2)]
        plan.unusedVoice = [try file("voice.m4a", megabytes: 1)]
        plan.unusedAssets = [try file("logo.png", megabytes: 0.3)]
        plan.oldClipboardExports = [try file("Demo.mp4", megabytes: 4), try file("Demo 2.gif", megabytes: 2)]
        plan.staleIDNotes = [try file("note-1", megabytes: 0.01), try file("note-2", megabytes: 0.01)]
        for language in ["en"] + Self.languages {
            L10n.use(language)
            let alert = VideoDataSettingsRow.confirmation(for: plan)
            // Light, so the words show on the snapshot's white (the alert's
            // own material doesn't draw offscreen).
            alert.window.appearance = NSAppearance(named: .aqua)
            alert.layout()
            try write(try XCTUnwrap(alert.window.contentView), name: "\(language)-cleanup-confirmation")
        }
    }

    func testStorageRowInEachLanguage() async throws {
        for language in Self.languages {
            L10n.use(language)
            try await render(RecordingSettingsView().background(Color(white: 0.13)), size: CGSize(width: 620, height: 1180), name: "\(language)-settings-storage")
        }
    }

    // MARK: Inspector sections

    func testCaptionLooksAndTranslationInEachLanguage() async throws {
        let model = try await model()
        let words: [(String, Double)] = [("Open", 1.0), ("the", 1.3), ("settings", 1.45), ("panel.", 1.9), ("Then", 3.0), ("pick", 3.3), ("a", 3.5), ("theme", 3.6)]
        model.mutate { $0.captions = VideoCaptionBuilder.lines(from: words.map { VideoCaptionWord(text: $0.0, start: $0.1, end: $0.1 + 0.3) }) }
        model.mutate { $0.captionStyle.preset = .highlight }
        // A translation, one of its lines edited since.
        let lines = model.project.captions.enumerated().map { index, line in
            VideoCaptionTranslation.Line(id: line.id, text: "Abre el panel", sourceText: index == 0 ? "An older line" : line.text)
        }
        model.storeTranslation(VideoCaptionTranslation(language: "es", lines: lines))
        let previousMode = UserDefaults.standard.string(forKey: "videoScriptMode")
        UserDefaults.standard.set("captions", forKey: "videoScriptMode")
        defer { UserDefaults.standard.set(previousMode ?? "transcript", forKey: "videoScriptMode") }
        model.inspectorTab = .captions
        model.seek(to: 1.6)
        for language in Self.languages {
            L10n.use(language)
            try await render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 1300), name: "\(language)-captions-inspector")
        }
        model.stop()
    }

    func testStyleAndAudioSectionsInEachLanguage() async throws {
        let model = try await model()
        model.setIntroEnabled(true)
        model.setOutroEnabled(true)
        model.seek(to: 6)
        model.splitAtPlayhead()
        model.setStyle { $0.transitions.betweenClips = .dissolve }
        let second = directory.appendingPathComponent("second.mp4")
        try await VideoInspection.writeColorVideo(to: second, size: CGSize(width: 1280, height: 720), colors: [(NSColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1), 3)])
        let appended = await model.appendVideo(second)
        XCTAssertTrue(appended)
        let song = directory.appendingPathComponent("Calm Theme.m4a")
        try VideoInspection.writeTone(to: song, frequency: 330, seconds: 8, amplitude: 0.4)
        await model.addMusic(from: song)
        model.setStyle { $0.clickSounds.enabled = true }
        let logo = directory.appendingPathComponent("Logo.png")
        try VideoInspection.writePNG(to: logo, size: CGSize(width: 300, height: 120), color: NSColor(srgbRed: 1, green: 0.42, blue: 0.2, alpha: 1))
        model.seek(to: 4)
        let image = try XCTUnwrap(model.addImageOverlay(from: logo))
        try await Task.sleep(nanoseconds: 900_000_000)
        for language in Self.languages {
            L10n.use(language)
            model.selection = .none
            model.inspectorTab = .background
            try await render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 1900), name: "\(language)-style-inspector")
            // The longest choice selected (bold): as wide as the inspector's column.
            model.setStyle { $0.transitions.betweenClips = .fadeThroughBlack }
            try await render(VideoTransitionsSection(model: model).padding(.horizontal, 16), size: CGSize(width: 318, height: 300), name: "\(language)-transitions-dip")
            model.setStyle { $0.transitions.betweenClips = .dissolve }
            model.inspectorTab = .audio
            try await render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 1100), name: "\(language)-audio-inspector")
            // Smoothing, click effects, and zoom speeds are named here.
            model.inspectorTab = .cursor
            try await render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 1100), name: "\(language)-cursor-inspector")
            model.inspectorTab = .zoom
            try await render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 900), name: "\(language)-zoom-inspector")
            model.selection = .overlay(image)
            try await render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 900), name: "\(language)-image-inspector")
            if let clip = model.segments.dropFirst().first {
                model.selection = .clip(clip.id)
                try await render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 900), name: "\(language)-clip-transition")
            }
        }
        model.selection = .none
        model.stop()
    }
}
