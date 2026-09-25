import AppKit
import AVFoundation
import XCTest
@testable import ShotnixCore

/// Drives the real editor model (playback, edits, undo, zooms, overlays)
/// headlessly against a synthesized recording.
@MainActor
final class VideoEditorModelTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory {
            VideoDemoDraftStore.delete(for: directory.appendingPathComponent("rec.mp4"))
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeModel(seconds: Double = 4, withPointer: Bool = true) async throws -> VideoEditorModel {
        let url = directory.appendingPathComponent("rec.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 960, height: 600), seconds: seconds, fps: 30)
        if withPointer {
            let waypoints: [VideoTestSupport.Waypoint] = [
                .init(x: 0.5, y: 0.5, arrive: 0, click: false),
                .init(x: 0.2, y: 0.3, arrive: 1.2, click: true),
                .init(x: 0.7, y: 0.6, arrive: 2.6, click: true),
            ]
            let (samples, clicks) = VideoTestSupport.scriptedPointer(waypoints: waypoints, duration: seconds)
            let metadata = VideoDemoRecordingMetadata(
                videoURLPath: url.path, createdAt: Date(), duration: seconds, sourceWidth: 960, sourceHeight: 600,
                fps: 30, nativeCursorVisible: false, cursorSamples: samples, clickEvents: clicks,
                pointPixelScale: 2, cursorShapes: nil, cursorShapeEvents: nil, renderCursor: true
            )
            XCTAssertTrue(VideoDemoSidecarStore.save(metadata, for: url))
        }
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        XCTAssertTrue(model.isReady, model.loadError ?? "not ready")
        return model
    }

    /// Suspends (instead of spinning a nested run loop) so the main queue
    /// stays free for AVFoundation's callbacks.
    private func spin(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testPlaybackAdvancesAndDeliversFrames() async throws {
        let model = try await makeModel()
        XCTAssertEqual(model.timelineDuration, 4, accuracy: 0.1)
        model.togglePlay()
        await spin(1.2)
        XCTAssertTrue(model.isPlaying)
        XCTAssertGreaterThan(model.clock.time, 0.5, "playhead should move while playing")
        let frame = model.playback.frame(forHostTime: CACurrentMediaTime())
        _ = frame // a frame may or may not be "new" at this exact instant
        model.togglePlay()
        await spin(0.3)
        XCTAssertFalse(model.isPlaying)

        // Seeking while paused yields the frame at that time.
        model.seek(to: 2.0)
        await spin(0.5)
        let seeked = model.playback.frame(forHostTime: CACurrentMediaTime())
        XCTAssertNotNil(seeked)
        XCTAssertEqual(seeked?.time ?? 0, 2.0, accuracy: 0.1)
    }

    func testRecordingWithSoundOpensPlaysAndMutes() async throws {
        let url = directory.appendingPathComponent("rec.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 640, height: 400), seconds: 3, fps: 30, audioSeconds: 2.8)
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        XCTAssertTrue(model.isReady, model.loadError ?? "")
        XCTAssertTrue(model.hasAudio)
        XCTAssertNotNil(model.playback.edit?.audioMix)
        model.togglePlay()
        await spin(0.6)
        XCTAssertGreaterThan(model.clock.time, 0.2)
        model.pause()
        model.seek(to: 1.5)
        model.splitAtPlayhead()
        guard case .clip(let id) = model.selection else { return XCTFail() }
        model.setClipMuted(id, true)
        XCTAssertEqual(model.playback.edit?.audioTracks.count, 1)
        model.setStyle { $0.audio.muted = true }
        XCTAssertNil(model.playback.edit?.audioMix, "muting the video drops its audio")
        await spin(0.8)
        XCTAssertNotNil(model.waveform)
    }

    func testFreshRecordingOpensWithAutoZoomAndCursor() async throws {
        let model = try await makeModel()
        XCTAssertFalse(model.project.zoomRegions.isEmpty, "fresh recordings open already zoomed")
        XCTAssertTrue(model.project.zoomRegions.allSatisfy(\.isAuto))
        XCTAssertTrue(model.project.rendersCursor)
        XCTAssertNotNil(model.plan.cursorTrack)
        XCTAssertFalse(model.plan.camera.isStatic)
    }

    func testSplitSpeedDeleteAndUndo() async throws {
        let model = try await makeModel()
        model.seek(to: 1.0)
        model.splitAtPlayhead()
        XCTAssertEqual(model.segments.count, 2)
        guard case .clip(let second) = model.selection else { return XCTFail("new clip selected") }

        model.setClipSpeed(second, 2)
        model.endGesture()
        XCTAssertEqual(model.timelineDuration, 1 + 3 / 2.0, accuracy: 0.05)
        XCTAssertEqual(model.playback.timelineDuration, model.timelineDuration, accuracy: 0.05, "player plays the edit")

        model.deleteClip(second)
        XCTAssertEqual(model.segments.count, 1)
        XCTAssertEqual(model.timelineDuration, 1, accuracy: 0.05)

        model.undo()
        XCTAssertEqual(model.segments.count, 2)
        model.undo()
        XCTAssertEqual(model.timelineDuration, 4, accuracy: 0.05)
        model.redo()
        XCTAssertEqual(model.timelineDuration, 2.5, accuracy: 0.05)
    }

    func testCutGapRestoreBringsMaterialBack() async throws {
        let model = try await makeModel()
        model.deleteRange(VideoDemoTimelineRange(start: 1, end: 2))
        XCTAssertEqual(model.timelineDuration, 3, accuracy: 0.05)
        let gap = try XCTUnwrap(model.cutGaps.first)
        XCTAssertEqual(gap.duration, 1, accuracy: 0.05)
        model.restore(gap)
        XCTAssertEqual(model.timelineDuration, 4, accuracy: 0.05)
        XCTAssertEqual(model.segments.count, 1, "restoring a seamless cut merges the clips")
    }

    func testZoomEditingNeverOverlapsAndCoalescesUndo() async throws {
        let model = try await makeModel(withPointer: false)
        XCTAssertTrue(model.project.zoomRegions.isEmpty)
        let a = try XCTUnwrap(model.addZoom(at: 0.5, length: 1))
        let b = try XCTUnwrap(model.addZoom(at: 2.5, length: 1))
        XCTAssertEqual(model.project.zoomRegions.count, 2)

        // Dragging A to the right stops at B.
        for step in 1...20 {
            model.setZoomWindow(a, start: 0.3 + Double(step) * 0.15, end: 1.3 + Double(step) * 0.15, coalesce: "drag-a")
        }
        model.endGesture()
        let rangeA = try XCTUnwrap(model.project.zoomRegions.first { $0.id == a }.flatMap { model.zoomTimelineRange($0) })
        let rangeB = try XCTUnwrap(model.project.zoomRegions.first { $0.id == b }.flatMap { model.zoomTimelineRange($0) })
        XCTAssertLessThanOrEqual(rangeA.upperBound, rangeB.lowerBound + 0.001)

        // The whole drag is one undo step.
        model.undo()
        let restored = try XCTUnwrap(model.project.zoomRegions.first { $0.id == a }.flatMap { model.zoomTimelineRange($0) })
        XCTAssertLessThan(restored.upperBound, 1.6)

        model.removeAllZooms()
        XCTAssertTrue(model.project.zoomRegions.isEmpty)
        model.undo()
        XCTAssertEqual(model.project.zoomRegions.count, 2)
    }

    func testAutoZoomKeepsHandPlacedZooms() async throws {
        let model = try await makeModel()
        model.removeAllZooms()
        let manual = try XCTUnwrap(model.addZoom(at: 3.4, length: 0.5))
        model.autoZoom()
        XCTAssertTrue(model.project.zoomRegions.contains { $0.id == manual })
        XCTAssertTrue(model.project.zoomRegions.contains { $0.isAuto })
        // No overlaps.
        let ranges = model.project.zoomRegions.compactMap { model.zoomTimelineRange($0) }.sorted { $0.lowerBound < $1.lowerBound }
        for (x, y) in zip(ranges, ranges.dropFirst()) {
            XCTAssertLessThanOrEqual(x.upperBound, y.lowerBound + 0.001)
        }
    }

    func testOverlappingAnnotationsStackUpward() async throws {
        let model = try await makeModel(withPointer: false)
        model.seek(to: 0.5)
        model.addOverlay(.highlight)
        model.addOverlay(.arrow)
        model.addOverlay(.text)
        let layers = model.project.overlayEffects.map(\.layer).sorted()
        XCTAssertEqual(layers, [0, 1, 2], "each overlapping annotation gets its own lane")
        // Render order follows lanes: the newest (highest) draws last, in front.
        let drawOrder = model.plan.overlays.map(\.effect.layer)
        XCTAssertEqual(drawOrder, drawOrder.sorted())
        guard case .overlay(let textID) = model.selection else { return XCTFail() }
        XCTAssertEqual(model.project.overlayEffects.first { $0.id == textID }?.layer, 2)
    }

    func testStyleEditsAreUndoableAndSaveAsDefault() async throws {
        let model = try await makeModel(withPointer: false)
        let original = model.project.padding
        model.setStyle(coalesce: "padding") { $0.padding = 0.12 }
        model.setStyle(coalesce: "padding") { $0.padding = 0.15 }
        model.endGesture()
        XCTAssertEqual(model.project.padding, 0.15, accuracy: 0.0001)
        model.undo()
        XCTAssertEqual(model.project.padding, original, accuracy: 0.0001, "a slider drag is one undo step")

        let saved = VideoStylePreset.savedDefault
        defer { VideoStylePreset.saveAsDefault(saved) }
        model.setStyle { $0.background = .gradient("violet") }
        model.saveStyleAsDefault()
        XCTAssertTrue(model.styleMatchesDefault)
        XCTAssertEqual(VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/new.mp4")).background, .gradient("violet"))
    }

    func testIdleSpeedUpFindsStillStretches() async throws {
        let url = directory.appendingPathComponent("rec.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 640, height: 400), seconds: 10, fps: 30)
        // Moves for 2s, then nothing for 6s, then moves again.
        let waypoints: [VideoTestSupport.Waypoint] = [
            .init(x: 0.2, y: 0.2, arrive: 0, click: false),
            .init(x: 0.6, y: 0.6, arrive: 1.5, click: true),
            .init(x: 0.6, y: 0.6, arrive: 8.2, click: false),
            .init(x: 0.3, y: 0.7, arrive: 9.5, click: true),
        ]
        var (samples, clicks) = VideoTestSupport.scriptedPointer(waypoints: waypoints, duration: 10)
        // Remove tremor during the still stretch.
        samples = samples.map { sample in
            var copy = sample
            if sample.time > 2, sample.time < 8.5 { copy.x = 0.6; copy.y = 0.6 }
            return copy
        }
        clicks = clicks.filter { $0.time < 2 || $0.time > 9 }
        let metadata = VideoDemoRecordingMetadata(videoURLPath: url.path, createdAt: Date(), duration: 10, sourceWidth: 640, sourceHeight: 400, fps: 30, nativeCursorVisible: false, cursorSamples: samples, clickEvents: clicks)
        VideoDemoSidecarStore.save(metadata, for: url)
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()

        let idle = model.idleRanges()
        XCTAssertEqual(idle.count, 1)
        model.speedUpIdle(speed: 8)
        XCTAssertLessThan(model.timelineDuration, 6)
        XCTAssertTrue(model.segments.contains { abs($0.clip.normalizedSpeed - 8) < 0.01 })
    }
}
