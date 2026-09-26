import AppKit
import AVFoundation
import XCTest
@testable import ShotnixCore

/// The new features inside the live editor: the preview player's edit
/// carries the intro hold, the music, and the clicks, and sound-only
/// changes swap the mix without rebuilding the player.
@MainActor
final class VideoFramingEditorTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-framing-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func model(seconds: Double = 3, audio: Bool = false) async throws -> VideoEditorModel {
        let url = directory.appendingPathComponent("recording.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 640, height: 400), seconds: seconds, fps: 30, audioSeconds: audio ? seconds : nil)
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        return model
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: Double = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testIntroCardHoldsTheFirstFrameInThePreview() async throws {
        let model = try await model()
        model.setIntroEnabled(true)
        XCTAssertEqual(model.timelineDuration, 6, accuracy: 0.05, "3 s intro + 3 s of video")
        XCTAssertEqual(model.playback.timelineDuration, 6, accuracy: 0.1, "the player's edit includes the intro")
        XCTAssertEqual(model.segments.first?.timelineStart ?? 0, 3, accuracy: 0.001)
        XCTAssertFalse(model.project.cards.intro.title.isEmpty, "a first title is filled in")
        model.seek(to: 1.0)
        var frame: CVPixelBuffer?
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let found = model.playback.frame(forHostTime: CACurrentMediaTime()) {
                frame = found.buffer
                break
            }
        }
        XCTAssertNotNil(frame, "a frame (the held first frame) shows under the intro card")
        model.setOutroEnabled(true)
        XCTAssertEqual(model.timelineDuration, 9, accuracy: 0.05)
        XCTAssertEqual(model.playback.timelineDuration, 9, accuracy: 0.1)
        model.stop()
    }

    func testMusicAndClicksPlayInThePreviewAndSoundChangesOnlySwapTheMix() async throws {
        let model = try await model(audio: true)
        let song = directory.appendingPathComponent("song.m4a")
        try VideoInspection.writeTone(to: song, frequency: 660, seconds: 2)
        await model.addMusic(from: song)
        try await waitUntil { model.playback.edit?.musicTrack != nil }
        XCTAssertNotNil(model.playback.edit?.musicTrack, "the preview plays the music")
        XCTAssertNotNil(model.media.musicWaveform, "and draws its waveform")
        let params = model.playback.player.currentItem?.audioMix?.inputParameters.count ?? 0
        XCTAssertGreaterThanOrEqual(params, 2, "recording + music in the mix")

        // Volume and ducking changes swap the mix, not the player item.
        let rebuilds = model.playback.itemRebuilds
        model.updateMusic { $0.volume = 0.8 }
        model.updateMusic { $0.duckLevel = 0.1 }
        XCTAssertEqual(model.playback.itemRebuilds, rebuilds)

        model.mutate { $0.clickEvents = [VideoDemoClickEvent(time: 1, x: 0.5, y: 0.5, button: .left, endTime: 1.1)] }
        model.setStyle { $0.clickSounds.enabled = true }
        try await waitUntil { model.playback.edit?.clickTrack != nil }
        XCTAssertNotNil(model.playback.edit?.clickTrack, "click sounds join the preview")

        model.removeMusic()
        XCTAssertNil(model.playback.edit?.musicTrack)
        model.stop()
    }

    /// M mutes the preview only: music and click sounds go quiet with the
    /// rest there, and the export keeps them — nor is it saved.
    func testPreviewMuteSilencesMusicAndClicksOnlyInThePreview() async throws {
        let model = try await model(audio: true)
        let song = directory.appendingPathComponent("song.m4a")
        try VideoInspection.writeTone(to: song, frequency: 660, seconds: 4, amplitude: 0.4)
        await model.addMusic(from: song)
        model.setStyle { $0.clickSounds.enabled = true }
        try await waitUntil { model.playback.edit?.musicTrack != nil }
        let before = model.project
        model.togglePreviewMute()
        XCTAssertTrue(model.previewMuted)
        XCTAssertTrue(model.playback.player.isMuted, "the player — music and clicks included — is silent")
        XCTAssertNotNil(model.playback.edit?.musicTrack, "the music stays in the edit")
        XCTAssertEqual(model.project, before, "nothing about it goes into the draft")

        var settings = VideoInspection.mp4Settings()
        settings.endCard = false
        let output = directory.appendingPathComponent("muted-preview.mp4")
        try await VideoDemoExporter.export(project: model.project, recording: model.recording, destinationURL: output, settings: settings)
        let samples = try VideoInspection.audio(of: output)
        XCTAssertGreaterThan(VideoInspection.toneLevel(samples, frequency: 660, from: 1, to: 2), 0.02, "the export has the music")
        model.togglePreviewMute()
        model.stop()
    }

    func testUndoNamesTheNewEdits() async throws {
        let model = try await model()
        model.setIntroEnabled(true)
        XCTAssertEqual(model.undoLabel, "Add Intro Card")
        let song = directory.appendingPathComponent("song.m4a")
        try VideoInspection.writeTone(to: song, frequency: 440, seconds: 2)
        await model.addMusic(from: song)
        XCTAssertEqual(model.undoLabel, "Add Music")
        let other = directory.appendingPathComponent("other.mp4")
        try await VideoInspection.writeColorVideo(to: other, size: CGSize(width: 640, height: 400), colors: [(.blue, 1)])
        let added = await model.appendVideo(other)
        XCTAssertTrue(added)
        XCTAssertEqual(model.undoLabel, "Add Recording")
        model.stop()
    }

    func testTransitionsPrefetchTheirHeldFrames() async throws {
        let model = try await model()
        model.seek(to: 1.5)
        model.splitAtPlayhead()
        model.setStyle { $0.transitions.betweenClips = .dissolve }
        XCTAssertEqual(model.plan.transitions.count, 1)
        let request = try XCTUnwrap(model.plan.heldFrameRequest(at: 1.4))
        XCTAssertEqual(request.sourceTime, 1.5, accuracy: 0.001, "before the cut, the incoming clip's first frame")
        try await waitUntil { model.heldFrame(at: 1.4) != nil }
        XCTAssertNotNil(model.heldFrame(at: 1.4), "fetched ahead of playback")
        model.stop()
    }

    func testIdleSpeedUpSkipsVideosWithoutPointerData() {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/p.mp4"), duration: 10, sourceSize: CGSize(width: 1280, height: 720))
        project.nativeCursorVisible = false
        project.cursorSamples = [VideoDemoCursorSample(time: 0, x: 0.5, y: 0.5)]
        project.ensurePrimarySource(duration: 10, kinds: [], webcam: nil, pointPixelScale: 2)
        project.appendSource(VideoProjectSource(path: "/tmp/plain.mp4", name: "plain.mp4", duration: 5, width: 1280, height: 720), metadata: nil)
        XCTAssertEqual(project.limitedToPointerCoverage([2...14]), [2...10], "the plain video's part is left alone")
        XCTAssertEqual(VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/one.mp4"), duration: 3).limitedToPointerCoverage([0...2]), [0...2])
    }
}
