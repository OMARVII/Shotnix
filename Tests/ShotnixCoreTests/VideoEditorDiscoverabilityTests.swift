import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Finding things: file names, recent exports, the File menu, the command
/// palette and shortcut list, friendly failures, and the transcript hint.
@MainActor
final class VideoEditorDiscoverabilityTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-find-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory {
            for name in ["rec.mp4", "Onboarding demo.mp4"] {
                VideoDemoDraftStore.delete(for: directory.appendingPathComponent(name))
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private typealias T = VideoEditorTestModel

    func testExportsAndSubtitlesShareTheRecordingsCurrentName() async throws {
        let model = try await T.make(in: directory)
        XCTAssertEqual(model.exportBaseName, "rec (edited)", "never the recording's own name (the save panel would offer to replace it)")
        // Renamed in Finder while the editor is open.
        let renamed = directory.appendingPathComponent("Onboarding demo.mp4")
        try FileManager.default.moveItem(at: model.project.sourceURL, to: renamed)
        XCTAssertEqual(model.recordingName, "Onboarding demo")
        XCTAssertEqual(model.exportBaseName, "Onboarding demo (edited)")
        model.setStyle { $0.padding = 0.1 }
        model.followRenamedRecording()
        XCTAssertEqual(VideoFileIdentity.canonicalURL(model.project.sourceURL), VideoFileIdentity.canonicalURL(renamed), "exports read the file where it is now")
        model.undo()
        XCTAssertEqual(VideoFileIdentity.canonicalURL(model.project.sourceURL), VideoFileIdentity.canonicalURL(renamed), "undo doesn't send it back to the old name")
    }

    func testMissingCameraFootageIsNotTheSameAsNoCamera() async throws {
        let model = try await T.make(in: directory)
        XCTAssertNil(model.missingWebcamFile, "recorded without a camera")

        let url = directory.appendingPathComponent("rec.mp4")
        var metadata = try XCTUnwrap(VideoDemoSidecarStore.load(for: url))
        metadata.webcam = VideoWebcamRecording(path: directory.appendingPathComponent("camera.mov").path, offset: 0, width: 320, height: 180)
        XCTAssertTrue(VideoDemoSidecarStore.save(metadata, for: url))
        let reopened = VideoEditorModel(videoURL: url)
        await reopened.load()
        XCTAssertNil(reopened.webcamRecording)
        XCTAssertEqual(reopened.missingWebcamFile?.lastPathComponent, "camera.mov")
        XCTAssertFalse(reopened.hasWebcamFootage)
    }

    func testRecentExportsShowUpInThePaletteAndTheFileMenu() async throws {
        let model = try await T.make(in: directory)
        let exported = directory.appendingPathComponent("rec (edited).mp4")
        try Data("video".utf8).write(to: exported)
        let gone = directory.appendingPathComponent("gone.mp4")
        VideoDemoRecentExportStore.add(exportURL: gone, sourceURL: model.project.sourceURL)
        VideoDemoRecentExportStore.add(exportURL: exported, sourceURL: model.project.sourceURL)
        XCTAssertEqual(model.recentExports.map(\.exportURL.lastPathComponent), ["rec (edited).mp4"], "only files still on disk")

        let palette = VideoCommandPalette(model: model)
        XCTAssertTrue(palette.commands.contains { $0.title.contains("rec (edited).mp4") })

        let menu = NSMenu(title: "File")
        VideoEditorFileMenu.shared.addItems(to: menu)
        XCTAssertEqual(menu.items.map(\.title), ["Export Video…", "Save Subtitles (.srt)…", "Recent Exports"])
        let recent = try XCTUnwrap(menu.items.last?.submenu)
        VideoEditorFileMenu.shared.menuNeedsUpdate(recent)
        XCTAssertTrue(recent.items.contains { $0.title == "rec (edited).mp4" })
        XCTAssertFalse(recent.items.contains { $0.title == "gone.mp4" })
    }

    func testCaptionCommandsWorkWithoutSound() async throws {
        let model = try await T.make(in: directory)
        XCTAssertFalse(model.hasAudio)
        var ids = VideoCommandPalette(model: model).commands.map(\.id)
        XCTAssertTrue(ids.contains("caption-line"), "typed captions need no sound")
        XCTAssertFalse(ids.contains("transcribe"))
        XCTAssertFalse(ids.contains("srt"))
        model.addCaptionAtPlayhead()
        ids = VideoCommandPalette(model: model).commands.map(\.id)
        XCTAssertTrue(ids.contains("srt"))
        XCTAssertFalse(ids.contains("fillers"), "nothing spoken to clean up")
    }

    func testShortcutListCoversEveryKey() {
        let keys = VideoShortcutsSheet.groups.flatMap(\.1).map(\.0).joined(separator: " ")
        for key in ["⌘B", "C", "=", "−", "⌘=", "⌘−", "Home", "End", "⌘F", "⌥←", "M", "⌘E", "⌘K"] {
            XCTAssertTrue(keys.contains(key), "\(key) is listed")
        }
    }

    func testCommandFFindsInTheTranscript() async throws {
        let model = try await T.make(in: directory)
        XCTAssertTrue(model.handleKey(T.key("f", code: 3, modifiers: [.command])))
        XCTAssertFalse(model.wantsTranscriptFind, "nothing to find yet")
        model.mutate { $0.captions = VideoCaptionBuilder.lines(from: [VideoCaptionWord(text: "Hello", start: 1, end: 1.4)]) }
        model.inspectorTab = .background
        XCTAssertTrue(model.handleKey(T.key("f", code: 3, modifiers: [.command])))
        XCTAssertEqual(model.inspectorTab, .captions)
        XCTAssertTrue(model.wantsTranscriptFind)
    }

    func testFilesThatCantOpenSayWhyInPlainWords() async throws {
        let text = directory.appendingPathComponent("notes.mp4")
        try Data("not a video".utf8).write(to: text)
        let unreadable = VideoEditorModel(videoURL: text)
        await unreadable.load()
        XCTAssertEqual(unreadable.loadFailure?.kind, .unreadable)
        XCTAssertFalse(unreadable.loadFailure?.message.isEmpty ?? true)

        let missing = VideoEditorModel(videoURL: directory.appendingPathComponent("moved.mp4"))
        await missing.load()
        XCTAssertEqual(missing.loadFailure?.kind, .missing)

        // Sound only (the file is finished once it's closed).
        let audio = directory.appendingPathComponent("voice.m4a")
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
            let file = try AVAudioFile(forWriting: audio, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
            buffer.frameLength = 44_100
            try file.write(from: buffer)
        }
        let soundOnly = VideoEditorModel(videoURL: audio)
        await soundOnly.load()
        XCTAssertEqual(soundOnly.loadFailure?.kind, .noVideo)

        VideoStageView.drawsStills = true
        defer { VideoStageView.drawsStills = false }
        try await VideoEditorFixesSnapshotTests.render(VideoEditorRootView(model: unreadable), size: CGSize(width: 1280, height: 800), name: "fix-11-unreadable-file")
    }

    func testNarratedRecordingsSuggestATranscript() async throws {
        var options = T.Options(seconds: 4, size: CGSize(width: 1440, height: 900))
        options.audio = true
        options.audioTracks = [.microphone]
        let model = try await T.make(in: directory, options)
        Settings.videoTranscribeHintDismissed = []
        XCTAssertTrue(model.suggestsTranscript)
        VideoStageView.drawsStills = true
        defer { VideoStageView.drawsStills = false }
        try await VideoEditorFixesSnapshotTests.render(VideoEditorRootView(model: model), size: CGSize(width: 1512, height: 944), name: "fix-11-transcribe-suggestion")
        model.dismissTranscriptSuggestion()
        XCTAssertFalse(model.suggestsTranscript, "waved away for this video")
        Settings.videoTranscribeHintDismissed = []
        model.addCaptionAtPlayhead()
        XCTAssertFalse(model.suggestsTranscript, "it has captions")

        // No voice, no suggestion.
        var silent = T.Options(seconds: 3)
        silent.audioTracks = nil
        let quiet = try await T.make(in: directory, name: "quiet.mp4", silent)
        XCTAssertFalse(quiet.suggestsTranscript)
        VideoDemoDraftStore.delete(for: directory.appendingPathComponent("quiet.mp4"))
    }

    // MARK: Parts of the timeline

    func testCommandASelectsTheWholeVideoSoSpeedAndSoundCoverEveryClip() async throws {
        var options = T.Options(seconds: 6)
        options.audio = true
        let model = try await T.make(in: directory, options)
        model.seek(to: 2)
        model.splitAtPlayhead()
        model.seek(to: 4)
        model.splitAtPlayhead()
        XCTAssertEqual(model.segments.count, 3)

        XCTAssertTrue(model.handleKey(T.key("a", code: 0, modifiers: [.command])))
        guard case .range(let range) = model.selection else { return XCTFail("⌘A selects a part: \(model.selection)") }
        XCTAssertEqual(range.start, 0, accuracy: 0.001)
        XCTAssertEqual(range.end, model.timelineDuration, accuracy: 0.001)
        XCTAssertTrue(model.isWholeVideo(range))
        XCTAssertEqual(model.project.timelineClips.count, 3, "selecting cuts nothing")

        // "Same speed everywhere" is two keystrokes and a click.
        model.setRangeSpeed(range, 2)
        XCTAssertEqual(Set(model.project.timelineClips.map(\.speed)), [2], "every clip")
        XCTAssertEqual(model.timelineDuration, 3, accuracy: 0.05)
        guard case .range(let faster) = model.selection else { return XCTFail("still selected") }
        XCTAssertTrue(model.isWholeVideo(faster), "the selection follows the shorter video")
        model.setRangeVolume(faster, \.volume, 0.25)
        XCTAssertEqual(Set(model.project.timelineClips.map(\.volume)), [0.25])
        XCTAssertEqual(model.project.timelineClips.count, 3, "no clip split at the edges")

        // A video can't be cut down to nothing.
        model.deleteSelection()
        XCTAssertEqual(model.project.timelineClips.count, 3)
        // Part of it can.
        let part = VideoDemoTimelineRange(start: 0.5, end: 1)
        XCTAssertFalse(model.isWholeVideo(part))

        // Not behind the export sheet (Select All there is the sheet's).
        model.selection = .none
        model.isExportPresented = true
        XCTAssertFalse(model.handleKey(T.key("a", code: 0, modifiers: [.command])))
        XCTAssertEqual(model.selection, .none)
        model.isExportPresented = false

        // Listed with the shortcuts, in the command palette and the tips.
        XCTAssertTrue(VideoShortcutsSheet.groups.flatMap(\.1).contains { $0.0 == "⌘A" && $0.1 == "Select the whole video" })
        XCTAssertTrue(VideoShortcutsSheet.groups.flatMap(\.1).contains { $0.1 == "Select a part to cut, or to change its speed or sound" })
        XCTAssertTrue(VideoCommandPalette(model: model).commands.contains { $0.id == "select-all" && $0.shortcut == "⌘A" })
        XCTAssertTrue(VideoTipsBar.pages.joined().contains { $0.1 == "select a part: cut, speed, sound" })
    }

    /// The clip panel says it changes one clip and how to change more; the
    /// caption lines have Remove all in sight. Rendered in English and
    /// French (it runs longer).
    func testPartsAndCaptionsRenderInEnglishAndFrench() async throws {
        var options = T.Options(seconds: 12, size: CGSize(width: 1440, height: 900))
        options.audio = true
        options.audioTracks = [.microphone]
        let model = try await T.make(in: directory, options)
        let words: [(String, Double)] = [("So", 0.6), ("open", 1.2), ("the", 1.45), ("settings", 1.6), ("panel.", 2.0), ("Then", 4.2), ("pick", 4.45), ("a", 4.65), ("theme", 4.75), ("and", 5.2), ("save", 5.9), ("it.", 6.15)]
        model.mutate { $0.captions = VideoCaptionBuilder.lines(from: words.map { VideoCaptionWord(text: $0.0, start: $0.1, end: $0.1 + 0.22) }) }
        model.seek(to: 4)
        model.splitAtPlayhead()
        model.endGesture()
        let clip = try XCTUnwrap(model.segments.last?.id)
        let mode = UserDefaults.standard.string(forKey: "videoScriptMode")
        VideoStageView.drawsStills = true
        defer {
            VideoStageView.drawsStills = false
            L10n.use(nil)
            UserDefaults.standard.set(mode, forKey: "videoScriptMode")
        }
        let full = CGSize(width: 1512, height: 944)
        for language in ["en", "fr"] {
            L10n.use(language == "en" ? nil : language)
            // The captions tab leaves the clip panel the least room.
            UserDefaults.standard.set("transcript", forKey: "videoScriptMode")
            model.inspectorTab = .captions
            model.selectClip(clip)
            try await VideoEditorFixesSnapshotTests.render(VideoEditorRootView(model: model), size: full, name: "parts-clip-panel-\(language)")
            model.selection = .none
            UserDefaults.standard.set("captions", forKey: "videoScriptMode")
            try await VideoEditorFixesSnapshotTests.render(VideoEditorRootView(model: model), size: full, name: "parts-caption-lines-\(language)")
            model.isShortcutsPresented = true
            try await VideoEditorFixesSnapshotTests.render(VideoEditorRootView(model: model), size: full, name: "parts-shortcuts-\(language)")
            model.isShortcutsPresented = false
        }
        model.stop()
    }
}
