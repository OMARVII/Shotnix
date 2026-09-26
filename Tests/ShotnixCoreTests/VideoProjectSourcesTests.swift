import AppKit
import AVFoundation
import XCTest
@testable import ShotnixCore

/// Projects with several recordings: appended after each other on one
/// source axis, each keeping its own pointer and clicks.
final class VideoProjectSourcesTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-sources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let yellow = NSColor(srgbRed: 1, green: 0.85, blue: 0, alpha: 1)
    private let green = NSColor(srgbRed: 0, green: 0.8, blue: 0.2, alpha: 1)

    /// A: 2 s of yellow at 1280×800 with a still pointer in the middle.
    /// B: 1.5 s of green, square, a plain video.
    private func twoRecordings() async throws -> (project: VideoDemoProject, a: URL, b: URL, metadata: VideoDemoRecordingMetadata) {
        let a = directory.appendingPathComponent("a.mp4")
        let b = directory.appendingPathComponent("b.mp4")
        try await VideoInspection.writeColorVideo(to: a, size: CGSize(width: 1280, height: 800), colors: [(yellow, 2)])
        try await VideoInspection.writeColorVideo(to: b, size: CGSize(width: 800, height: 800), colors: [(green, 1.5)])
        let samples = stride(from: 0.0, through: 2.0, by: 0.05).map { VideoDemoCursorSample(time: $0, x: 0.5, y: 0.5) }
        let clicks = [VideoDemoClickEvent(time: 1.0, x: 0.5, y: 0.5, button: .left, endTime: 1.1)]
        let metadata = VideoDemoRecordingMetadata(videoURLPath: a.path, createdAt: Date(), duration: 2, sourceWidth: 1280, sourceHeight: 800, fps: 30, nativeCursorVisible: false, cursorSamples: samples, clickEvents: clicks, pointPixelScale: 2, renderCursor: true)
        var project = VideoInspection.project(for: a, seconds: 2, size: CGSize(width: 1280, height: 800))
        project.apply(metadata: metadata)
        project.cursor.visible = true
        project.cursor.hideWhenIdle = false
        project.cursor.tidyEnding = false
        project.cursor.motionBlur = false
        project.cursor.clickEffect = .none
        project.ensurePrimarySource(duration: 2, kinds: [], webcam: nil, pointPixelScale: 2)
        project.appendSource(VideoProjectSource(path: b.path, name: "b.mp4", duration: 1.5, width: 800, height: 800), metadata: nil)
        return (project, a, b, metadata)
    }

    func testSingleRecordingProjectsHaveNoSources() {
        let project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/one.mp4"), duration: 4, sourceSize: CGSize(width: 1280, height: 720))
        XCTAssertFalse(project.hasAppendedSources)
        XCTAssertNil(project.sourceAxisDuration)
        XCTAssertNil(project.pointerCoverage)
        XCTAssertEqual(project.primaryOffset, 0)
        XCTAssertTrue(project.sourceBoundaries(segments: project.timelineSegments(totalDuration: 4)).isEmpty)
    }

    func testAppendingPlacesTheRecordingAfterTheTimeline() async throws {
        let (project, _, b, _) = try await twoRecordings()
        XCTAssertTrue(project.hasAppendedSources)
        XCTAssertEqual(project.sources.count, 2)
        XCTAssertEqual(project.sources[1].offset, 2, accuracy: 0.001)
        XCTAssertEqual(project.sourceAxisDuration ?? 0, 3.5, accuracy: 0.001)
        let segments = project.timelineSegments(totalDuration: 3.5)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(project.timelineDuration(totalDuration: 3.5), 3.5, accuracy: 0.001)
        let boundaries = project.sourceBoundaries(segments: segments)
        XCTAssertEqual(boundaries.count, 1)
        XCTAssertEqual(boundaries.first?.time ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(boundaries.first?.name, "b.mp4")
        XCTAssertEqual(project.source(at: 2.5)?.path, b.path)
        XCTAssertEqual(project.source(at: 1.0)?.isPrimary, true)
        // A clip crossing the boundary splits into one piece per recording.
        let pieces = project.sourcePieces(from: 1.5, to: 2.5)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[1].localStart, 0, accuracy: 0.001)
        XCTAssertEqual(pieces[1].length, 0.5, accuracy: 0.001)
    }

    func testPointerIsDrawnOnlyWhereARecordingHasOne() async throws {
        let (project, _, _, _) = try await twoRecordings()
        XCTAssertEqual(project.pointerCoverage?.count, 1)
        let track = try XCTUnwrap(VideoSourcesPointer.cursorTrack(project: project, duration: 3.5))
        XCTAssertGreaterThan(track.alpha(at: 1.0), 0.9, "the first recording's pointer shows")
        XCTAssertLessThan(track.alpha(at: 2.8), 0.01, "the plain video has none")
        XCTAssertEqual(Double(track.position(at: 1.0).x), 0.5, accuracy: 0.01)
    }

    func testExportPlaysBothRecordingsWithThePointerOnlyInTheFirst() async throws {
        let (project, _, _, metadata) = try await twoRecordings()
        let output = directory.appendingPathComponent("joined.mp4")
        try await VideoDemoExporter.export(project: project, recording: metadata, destinationURL: output, settings: VideoInspection.mp4Settings())
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 3.5, accuracy: 0.1, "both recordings, back to back")

        let first = try VideoInspection.frame(of: output, at: 0.5)
        let second = try VideoInspection.frame(of: output, at: 3.0)
        let firstEdge = VideoInspection.color(of: first, x: 0.2, y: 0.2)
        let secondCenter = VideoInspection.color(of: second, x: 0.5, y: 0.8)
        let secondBar = VideoInspection.color(of: second, x: 0.08, y: 0.5)
        XCTAssertTrue(VideoInspection.isClose(firstEdge, (1, 0.85, 0), tolerance: 0.12), "the first recording plays first: \(firstEdge)")
        XCTAssertTrue(VideoInspection.isClose(secondCenter, (0, 0.8, 0.2), tolerance: 0.12), "then the second: \(secondCenter)")
        XCTAssertLessThan(secondBar.r + secondBar.g + secondBar.b, 0.15, "the square video is letterboxed, not stretched: \(secondBar)")

        // The pointer (a dark arrow) sits in the middle of the first
        // recording only.
        func darkest(_ image: CGImage) -> Double {
            var lowest = 3.0
            for dx in stride(from: 0.0, through: 0.02, by: 0.004) {
                for dy in stride(from: 0.0, through: 0.04, by: 0.004) {
                    let c = VideoInspection.color(of: image, x: 0.5 + dx, y: 0.5 + dy, radius: 1)
                    lowest = min(lowest, c.r + c.g + c.b)
                }
            }
            return lowest
        }
        XCTAssertLessThan(darkest(first), 0.6, "the pointer is drawn over the first recording")
        XCTAssertGreaterThan(darkest(second), 0.6, "and not over the plain video")
    }

    func testReorderingMovesClipsAndTimedThings() async throws {
        var (project, _, _, metadata) = try await twoRecordings()
        project.zoomRegions = [VideoZoomRegion(start: 0.5, end: 1.5, scale: 2)]
        project.captions = [VideoCaptionLine(start: 0.2, end: 1.0, text: "First", words: [VideoCaptionWord(text: "First", start: 0.2, end: 0.6)])]
        project.moveSource(from: 1, to: 0)
        XCTAssertEqual(project.sources.map(\.name), ["b.mp4", project.sourceURL.lastPathComponent])
        XCTAssertEqual(project.primaryOffset, 1.5, accuracy: 0.001)
        XCTAssertEqual(project.zoomRegions.first?.start ?? 0, 2.0, accuracy: 0.001, "the zoom moved with its recording")
        XCTAssertEqual(project.captions.first?.start ?? 0, 1.7, accuracy: 0.001)
        XCTAssertEqual(project.captions.first?.words.first?.start ?? 0, 1.7, accuracy: 0.001)
        XCTAssertEqual(project.clickEvents.first?.time ?? 0, 2.5, accuracy: 0.001)
        XCTAssertEqual(project.timelineClips.first?.sourceStart ?? 9, 0, accuracy: 0.001, "the square video's clip comes first")
        XCTAssertEqual(VideoSourcesPointer.cursorTrack(project: project, duration: 3.5)?.alpha(at: 0.5) ?? 1, 0, accuracy: 0.01)

        let output = directory.appendingPathComponent("reordered.mp4")
        try await VideoDemoExporter.export(project: project, recording: metadata, destinationURL: output, settings: VideoInspection.mp4Settings())
        let opening = VideoInspection.color(of: try VideoInspection.frame(of: output, at: 0.5), x: 0.5, y: 0.8)
        XCTAssertTrue(VideoInspection.isClose(opening, (0, 0.8, 0.2), tolerance: 0.12), "the moved recording now opens the video: \(opening)")
    }

    func testRemovingARecordingClosesTheGap() async throws {
        var (project, _, _, _) = try await twoRecordings()
        let added = project.sources[1].id
        XCTAssertFalse(project.removeSource(id: project.sources[0].id), "the project's own recording stays")
        XCTAssertTrue(project.removeSource(id: added))
        XCTAssertFalse(project.hasAppendedSources)
        XCTAssertEqual(project.timelineClips.count, 1)
        XCTAssertEqual(project.timelineDuration(totalDuration: 2), 2, accuracy: 0.001)
    }

    func testSourcesRoundTripInDrafts() async throws {
        let (project, _, _, _) = try await twoRecordings()
        let decoded = try JSONDecoder().decode(VideoDemoProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.sources, project.sources)
        XCTAssertEqual(decoded.timelineClips, project.timelineClips)
        XCTAssertEqual(decoded.sourceAxisDuration ?? 0, 3.5, accuracy: 0.001)
    }

    func testAddedRecordingsAreFoundAfterAMove() async throws {
        let (project, _, b, _) = try await twoRecordings()
        var added = project.sources[1]
        added.bookmark = VideoSourceLocator.bookmark(for: b)
        let moved = directory.appendingPathComponent("moved-b.mp4")
        try FileManager.default.moveItem(at: b, to: moved)
        XCTAssertEqual(VideoSourceLocator.resolve(added)?.resolvingSymlinksInPath().path, moved.resolvingSymlinksInPath().path)
    }

    @MainActor
    func testEditorAppendsAVideoAndPlaysAcrossIt() async throws {
        let a = directory.appendingPathComponent("editor-a.mp4")
        let b = directory.appendingPathComponent("editor-b.mp4")
        try await VideoInspection.writeColorVideo(to: a, size: CGSize(width: 640, height: 400), colors: [(yellow, 2)])
        try await VideoInspection.writeColorVideo(to: b, size: CGSize(width: 640, height: 400), colors: [(green, 1)])
        VideoDemoDraftStore.delete(for: a)
        let model = VideoEditorModel(videoURL: a)
        await model.load()
        XCTAssertEqual(model.timelineDuration, 2, accuracy: 0.05)
        let added = await model.appendVideo(b)
        XCTAssertTrue(added)
        XCTAssertEqual(model.sourceDuration, 3, accuracy: 0.05)
        XCTAssertEqual(model.timelineDuration, 3, accuracy: 0.05)
        XCTAssertEqual(model.playback.timelineDuration, 3, accuracy: 0.1, "the player plays both")
        // Undo takes it out again.
        model.undo()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(model.project.hasAppendedSources)
        XCTAssertEqual(model.timelineDuration, 2, accuracy: 0.05)
        model.stop()
        VideoDemoDraftStore.delete(for: a)
    }
}
