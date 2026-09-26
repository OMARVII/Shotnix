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

    /// Many dissolves: held frames are decoded at preview size, only around
    /// the playhead, within a byte budget — and not while dragging.
    func testHeldFramesStaySmallFewAndNearThePlayhead() async throws {
        let url = directory.appendingPathComponent("big.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 2560, height: 1440), seconds: 20, fps: 5)
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        // 40 clips back to back, each cut dissolving.
        model.mutate { project in
            project.timelineClips = (0..<40).map { VideoDemoTimelineClip(sourceStart: Double($0) * 0.5, sourceEnd: Double($0 + 1) * 0.5) }
            project.transitions.betweenClips = .dissolve
        }
        model.seek(to: 0)
        XCTAssertEqual(model.plan.transitions.count, 39)
        let frames = model.media.frames(for: model.project)
        try await waitUntil { frames.decodeRequests > 0 }
        let near = model.plan.transitions.filter { $0.end >= -1 && $0.start <= VideoEditorModel.heldFrameWindow }.count
        XCTAssertLessThanOrEqual(frames.decodeRequests, near * 2 + 2, "only the dissolves near the playhead (\(frames.decodeRequests) of \(39 * 2))")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertLessThanOrEqual(frames.cachedBytes, VideoEditorMedia.previewFrameBytes)
        let held = try XCTUnwrap(frames.image(at: model.plan.transitions[0].incomingSource))
        XCTAssertLessThanOrEqual(max(held.extent.width, held.extent.height), VideoEditorMedia.previewFrameSize.width, "preview-sized, not the full 2560 px")

        // Dragging far along: nothing more is decoded until it's let go.
        let before = frames.decodeRequests
        model.seek(to: 15, fast: true)
        model.setStyle(coalesce: "drag-padding") { $0.padding += 1 }
        model.setStyle(coalesce: "drag-padding") { $0.padding += 1 }
        XCTAssertEqual(frames.decodeRequests, before, "no fetching mid-drag")
        model.seek(to: 15)
        model.endGesture()
        model.prefetchHeldFrames()
        XCTAssertGreaterThan(frames.decodeRequests, before, "the dissolves at the new spot once it's let go")
        model.stop()
        VideoDemoDraftStore.delete(for: url)
    }

    /// After a clip is moved, dragging or setting an item's window across
    /// the moved clip keeps a sensible length instead of 0.2 s.
    func testWindowsAfterMovingAClipKeepTheirLength() async throws {
        let model = try await model(seconds: 4)
        let a = VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 2)
        let b = VideoDemoTimelineClip(sourceStart: 2, sourceEnd: 4)
        model.mutate { $0.timelineClips = [a, b] }
        model.moveClip(b.id, toIndex: 0)
        // Timeline: B (recording 2–4) then A (recording 0–2).
        XCTAssertEqual(model.segments.first?.clip.sourceStart ?? 0, 2, accuracy: 0.001)

        // An annotation dragged from 1 s to 2.6 s: it stays in B, to B's end.
        model.seek(to: 0.5)
        model.addOverlay(.highlight)
        let overlay = try XCTUnwrap(model.project.overlayEffects.first)
        model.setOverlayWindow(overlay.id, start: 1.0, end: 2.6, coalesce: "drag")
        let moved = try XCTUnwrap(model.project.overlayEffects.first)
        XCTAssertEqual(moved.time, 3.0, accuracy: 0.01)
        XCTAssertEqual(moved.duration, 1.0, accuracy: 0.01, "to the end of its clip, not 0.2 s")

        // A caption, the same.
        model.mutate { $0.captions = [VideoCaptionLine(start: 2.2, end: 2.8, text: "Hi")] }
        let line = try XCTUnwrap(model.project.captions.first)
        model.setCaptionWindow(line.id, timelineStart: 1.0, timelineEnd: 2.6, moveWords: false)
        let caption = try XCTUnwrap(model.project.captions.first)
        XCTAssertEqual(caption.end - caption.start, 1.0, accuracy: 0.01)

        // A zoom made at the playhead near B's end runs to B's end.
        model.seek(to: 1.5)
        _ = model.addZoom(at: 1.5)
        let zoom = try XCTUnwrap(model.project.zoomRegions.first { $0.start >= 2 })
        XCTAssertGreaterThan(zoom.end, zoom.start + 0.3, "\(zoom.start)–\(zoom.end)")
        XCTAssertLessThanOrEqual(zoom.end, 4.0001)

        // An image for the whole video covers all of the recording on it.
        let logo = directory.appendingPathComponent("logo.png")
        try VideoInspection.writePNG(to: logo, size: CGSize(width: 120, height: 60), color: .orange)
        let image = try XCTUnwrap(model.addImageOverlay(from: logo))
        model.showImageForWholeVideo(image)
        let whole = try XCTUnwrap(model.project.overlayEffects.first { $0.id == image })
        XCTAssertEqual(whole.time, 0, accuracy: 0.001)
        XCTAssertEqual(whole.duration, 4, accuracy: 0.001)
        model.stop()
    }

    /// Moving a click (same number of clicks, same pointer path end) or a
    /// recording changes what Shorten Pauses sees at once.
    func testPauseDetectionSeesEditsThatKeepTheCounts() async throws {
        let model = try await model(seconds: 4)
        model.mutate {
            $0.cursorSamples = [VideoDemoCursorSample(time: 0, x: 0.5, y: 0.5), VideoDemoCursorSample(time: 4, x: 0.5, y: 0.5)]
            $0.clickEvents = [VideoDemoClickEvent(time: 1.0, x: 0.5, y: 0.5, button: .left, endTime: 1.05)]
        }
        XCTAssertTrue(model.activityTimes.contains { abs($0 - 1.0) < 0.001 })
        let click = try XCTUnwrap(model.project.clickEvents.first)
        model.moveClick(click.id, toTimeline: 3.0)
        XCTAssertTrue(model.activityTimes.contains { abs($0 - 3.0) < 0.001 }, "the moved click: \(model.activityTimes)")
        XCTAssertFalse(model.activityTimes.contains { abs($0 - 1.0) < 0.001 }, "not where it was")
        model.stop()
    }

    /// A song removed from the video stays while undo can bring it back —
    /// in the open editor, and in a closed editor's kept history.
    func testCleanUpKeepsPicturesAndSongsUndoCanBringBack() async throws {
        let model = try await model(seconds: 2)
        let song = directory.appendingPathComponent("Theme.m4a")
        try VideoInspection.writeTone(to: song, frequency: 440, seconds: 2)
        await model.addMusic(from: song)
        let stored = try XCTUnwrap(model.project.music?.path)
        model.removeMusic()
        XCTAssertNil(model.project.music)
        XCTAssertTrue(model.assetPathsInHistory().contains(stored), "undo still has it")
        model.stop()
        XCTAssertTrue(VideoEditorModel.keptHistoryAssetPaths().contains(stored), "so does the closed editor's kept history")
        // Clean Up leaves it alone even once its grace day is over.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: stored)
        let plan = VideoDataCleanup.plan(finder: .nowhere, inUse: VideoEditorModel.keptHistoryAssetPaths())
        XCTAssertFalse(plan.unusedAssets.map(\.lastPathComponent).contains(URL(fileURLWithPath: stored).lastPathComponent))
    }

    func testHeldFrameCacheKeepsToItsBudget() async throws {
        let url = directory.appendingPathComponent("frames.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 640, height: 400), seconds: 3, fps: 10)
        let perFrame = 640 * 400 * 4
        let frames = VideoSourceFrames(byteLimit: perFrame * 3) { (url, $0) }
        for index in 0..<8 { _ = frames.image(at: Double(index) * 0.3) }
        XCTAssertLessThanOrEqual(frames.cachedBytes, perFrame * 3, "the oldest frames make room")
        XCTAssertGreaterThan(frames.cachedBytes, 0)
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
