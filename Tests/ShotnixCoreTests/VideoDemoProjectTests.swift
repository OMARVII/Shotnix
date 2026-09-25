import AVFoundation
import XCTest
@testable import ShotnixCore

final class VideoDemoProjectTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private func project(duration: Double = 10, source: CGSize = CGSize(width: 1920, height: 1080)) -> VideoDemoProject {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: duration, sourceSize: source)
        project.apply(style: .factory)
        return project
    }

    // MARK: Canvas & frame

    func testAspectPresetsUseA1080ShortSide() {
        let source = CGSize(width: 1333, height: 777)
        XCTAssertEqual(VideoDemoProject.AspectPreset.widescreen.canvasSize(sourceSize: source), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(VideoDemoProject.AspectPreset.vertical.canvasSize(sourceSize: source), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(VideoDemoProject.AspectPreset.square.canvasSize(sourceSize: source), CGSize(width: 1080, height: 1080))
        XCTAssertEqual(VideoDemoProject.AspectPreset.classic.canvasSize(sourceSize: source), CGSize(width: 1440, height: 1080))
        XCTAssertEqual(VideoDemoProject.AspectPreset.portrait.canvasSize(sourceSize: source), CGSize(width: 1080, height: 1350))
        let auto = VideoDemoProject.AspectPreset.source.canvasSize(sourceSize: source)
        XCTAssertEqual(auto.height, 1080)
        XCTAssertEqual(auto.width / auto.height, source.width / source.height, accuracy: 0.01)
    }

    func testStageRectFitsSourceInsidePadding() {
        var project = project(source: CGSize(width: 2560, height: 1440))
        project.padding = 0.1
        project.aspectPreset = .vertical
        let canvas = project.canvasSize()
        let rect = project.stageRect(in: canvas)
        let margin = min(canvas.width, canvas.height) * 0.1
        XCTAssertGreaterThanOrEqual(rect.minX, margin - 0.5)
        XCTAssertLessThanOrEqual(rect.maxX, canvas.width - margin + 0.5)
        XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(rect.midY, canvas.height / 2, accuracy: 0.5)
    }

    func testZeroPaddingIsFullBleed() {
        var project = project()
        project.padding = 0
        project.aspectPreset = .source
        XCTAssertTrue(project.usesRawSourceFrame)
        XCTAssertEqual(project.effectiveCornerRadius, 0)
        XCTAssertEqual(project.effectiveShadow, 0)
        let canvas = project.canvasSize()
        XCTAssertEqual(project.stageRect(in: canvas), CGRect(origin: .zero, size: canvas))
    }

    // MARK: Timeline math

    func testTrimRangeClampsToDuration() {
        var project = project(duration: 20)
        project.trimStart = -4
        project.trimEnd = 99
        let trim = project.normalizedTrim(totalDuration: 20)
        XCTAssertEqual(trim.start, 0, accuracy: 0.001)
        XCTAssertEqual(trim.end, 20, accuracy: 0.001)
    }

    func testTimelineSplitsClipAtSourceTime() {
        var project = project()
        let newClipID = project.splitClip(atSourceTime: 4, totalDuration: 10)
        let segments = project.timelineSegments(totalDuration: 10)
        XCTAssertNotNil(newClipID)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].clip.sourceEnd, 4, accuracy: 0.001)
        XCTAssertEqual(segments[1].timelineStart, 4, accuracy: 0.001)
        XCTAssertEqual(segments[1].clip.sourceStart, 4, accuracy: 0.001)
    }

    func testTimelineDeleteRipplesRemainingClips() {
        let middleID = UUID()
        var project = project()
        project.timelineClips = [
            VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 3),
            VideoDemoTimelineClip(id: middleID, sourceStart: 3, sourceEnd: 5),
            VideoDemoTimelineClip(sourceStart: 5, sourceEnd: 10),
        ]
        XCTAssertNotNil(project.deleteClip(id: middleID, totalDuration: 10))
        let segments = project.timelineSegments(totalDuration: 10)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[1].timelineStart, 3, accuracy: 0.001)
        XCTAssertEqual(project.timelineDuration(totalDuration: 10), 8, accuracy: 0.001)
    }

    func testTimelineRangeDeleteSplitsAndRipples() {
        var project = project(duration: 12)
        project.timelineClips = [
            VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 5),
            VideoDemoTimelineClip(sourceStart: 5, sourceEnd: 12),
        ]
        XCTAssertNotNil(project.deleteTimelineRange(start: 3, end: 8, totalDuration: 12))
        let segments = project.timelineSegments(totalDuration: 12)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].clip.sourceEnd, 3, accuracy: 0.001)
        XCTAssertEqual(segments[1].clip.sourceStart, 8, accuracy: 0.001)
        XCTAssertEqual(project.timelineDuration(totalDuration: 12), 7, accuracy: 0.001)
        XCTAssertNil(project.deleteTimelineRange(start: 0, end: 12, totalDuration: 12), "keeps at least one clip")
    }

    func testTimelineMapsAcrossCutsAndSpeed() {
        var project = project()
        project.timelineClips = [
            VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 4, speed: 2),
            VideoDemoTimelineClip(sourceStart: 6, sourceEnd: 10, speed: 0.5),
        ]
        XCTAssertEqual(project.timelineDuration(totalDuration: 10), 2 + 8, accuracy: 0.001)
        XCTAssertEqual(project.sourceTime(forTimelineTime: 1, totalDuration: 10), 2, accuracy: 0.001)
        XCTAssertEqual(project.timelineTime(forSourceTime: 7, totalDuration: 10), 4, accuracy: 0.001)
        XCTAssertNil(project.timelineTimeIfIncluded(sourceTime: 5, totalDuration: 10))
        let ranges = VideoDemoProject.timelineRanges(sourceStart: 3, sourceEnd: 7, segments: project.timelineSegments(totalDuration: 10))
        XCTAssertEqual(ranges.count, 1, "the cut joins the two pieces seamlessly")
        XCTAssertEqual(ranges[0].lowerBound, 1.5, accuracy: 0.001)
        XCTAssertEqual(ranges[0].upperBound, 4, accuracy: 0.001)
    }

    func testClipSpeedAndFadesClamp() throws {
        let clipID = UUID()
        var project = project(duration: 4)
        project.timelineClips = [VideoDemoTimelineClip(id: clipID, sourceStart: 0, sourceEnd: 4)]
        XCTAssertTrue(project.updateClip(id: clipID, totalDuration: 4) { clip in
            clip.speed = 64
            clip.fadeIn = 99
            clip.fadeOut = 99
        })
        let clip = try XCTUnwrap(project.timelineSegments(totalDuration: 4).first?.clip)
        XCTAssertEqual(clip.normalizedSpeed, 16, accuracy: 0.001)
        XCTAssertEqual(clip.fadeIn, clip.outputDuration / 2, accuracy: 0.001)
    }

    func testTrimCannotGrowIntoNeighbour() {
        let first = UUID()
        var project = project()
        project.timelineClips = [
            VideoDemoTimelineClip(id: first, sourceStart: 0, sourceEnd: 3),
            VideoDemoTimelineClip(sourceStart: 5, sourceEnd: 10),
        ]
        XCTAssertTrue(project.trimClip(id: first, sourceEnd: 8, totalDuration: 10))
        XCTAssertEqual(project.timelineClips[0].sourceEnd, 5, accuracy: 0.001)
    }

    // MARK: Migration

    func testLegacyDraftMigratesToRegionsAndNewStyle() throws {
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "sourcePath": "/tmp/demo.mp4",
            "createdAt": 0,
            "sourceWidth": 1920,
            "sourceHeight": 1080,
            "trimStart": 0,
            "trimEnd": 10,
            "aspectPreset": "widescreen",
            "backgroundPreset": "mint",
            "customBackgroundPath": "",
            "backgroundBlur": 9,
            "stageInset": 0.1,
            "shadowStrength": 0.4,
            "cornerRadius": 24,
            "zoomKeyframes": [
                ["id": UUID().uuidString, "time": 1, "scale": 1, "focusX": 0.5, "focusY": 0.5],
                ["id": UUID().uuidString, "time": 2, "scale": 1.8, "focusX": 0.3, "focusY": 0.4],
                ["id": UUID().uuidString, "time": 4, "scale": 1.8, "focusX": 0.3, "focusY": 0.4],
                ["id": UUID().uuidString, "time": 5, "scale": 1, "focusX": 0.5, "focusY": 0.5],
            ],
            "cursorSamples": [],
            "clickEvents": [],
            "nativeCursorVisible": false,
            "showCursorOverlay": true,
            "enlargeCursor": true,
            "showClickRipple": false,
            "smoothCursor": true,
            "cursorScale": 2.0,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let project = try JSONDecoder().decode(VideoDemoProject.self, from: data)
        XCTAssertEqual(project.background, .gradient("mint"))
        XCTAssertEqual(project.padding, 0.1, accuracy: 0.0001)
        XCTAssertEqual(project.backgroundBlur, 0.5, accuracy: 0.0001)
        XCTAssertEqual(project.zoomRegions.count, 1)
        let region = try XCTUnwrap(project.zoomRegions.first)
        XCTAssertEqual(region.start, 1, accuracy: 0.001)
        XCTAssertEqual(region.end, 5, accuracy: 0.001)
        XCTAssertEqual(region.scale, 1.8, accuracy: 0.001)
        XCTAssertFalse(region.followsCursor)
        XCTAssertEqual(project.cursor.size, 2, accuracy: 0.001)
        XCTAssertEqual(project.cursor.clickEffect, VideoCursorSettings.ClickEffect.none)

        // Round trip in the new format.
        let reencoded = try JSONDecoder().decode(VideoDemoProject.self, from: try JSONEncoder().encode(project))
        XCTAssertEqual(reencoded, project)
    }

    // MARK: Camera

    func testCameraRampsInsideTheRegionAndReturnsToRest() throws {
        let project = project()
        let segments = project.timelineSegments(totalDuration: 10)
        let region = VideoZoomRegion(start: 2, end: 6, scale: 2, followsCursor: false, focusX: 0.5, focusY: 0.5)
        let track = VideoCameraTrack.build(regions: [region], segments: segments, timelineDuration: 10, speed: .smooth, stage: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), cursor: nil)
        XCTAssertEqual(track.state(at: 1.9).scale, 1, accuracy: 0.001, "no zoom before the block")
        XCTAssertGreaterThan(track.state(at: 2.3).scale, 1.05, "zoom starts with the block")
        XCTAssertEqual(track.state(at: 4).scale, 2, accuracy: 0.01)
        XCTAssertEqual(track.state(at: 6.05).scale, 1, accuracy: 0.001, "fully out by the block's end")
    }

    func testCloseRegionsChainIntoAPan() {
        let project = project()
        let segments = project.timelineSegments(totalDuration: 10)
        let a = VideoZoomRegion(start: 1, end: 4, scale: 2, followsCursor: false, focusX: 0.2, focusY: 0.2)
        let b = VideoZoomRegion(start: 4.6, end: 8, scale: 2, followsCursor: false, focusX: 0.8, focusY: 0.8)
        let track = VideoCameraTrack.build(regions: [a, b], segments: segments, timelineDuration: 10, speed: .smooth, stage: CGRect(x: 0, y: 0, width: 1, height: 1), cursor: nil)
        for t in stride(from: 3.0, through: 5.5, by: 0.1) {
            XCTAssertGreaterThan(track.state(at: t).scale, 1.9, "stays zoomed through the gap at \(t)")
        }
        XCTAssertLessThan(track.state(at: 3.0).centerX, track.state(at: 5.5).centerX, "pans toward the second shot")
    }

    func testCameraWindowNeverLeavesTheCanvas() {
        let project = project()
        let segments = project.timelineSegments(totalDuration: 10)
        let region = VideoZoomRegion(start: 1, end: 5, scale: 2.5, followsCursor: false, focusX: 0.01, focusY: 0.99)
        let track = VideoCameraTrack.build(regions: [region], segments: segments, timelineDuration: 10, speed: .quick, stage: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), cursor: nil)
        let canvas = CGSize(width: 1920, height: 1080)
        for step in 0...100 {
            let window = track.state(at: Double(step) * 0.1).window(in: canvas)
            XCTAssertGreaterThanOrEqual(window.minX, -0.01)
            XCTAssertGreaterThanOrEqual(window.minY, -0.01)
            XCTAssertLessThanOrEqual(window.maxX, canvas.width + 0.01)
            XCTAssertLessThanOrEqual(window.maxY, canvas.height + 0.01)
        }
    }

    func testFollowCameraKeepsThePointerInView() {
        let project = project()
        let segments = project.timelineSegments(totalDuration: 10)
        let region = VideoZoomRegion(start: 0, end: 10, scale: 2, followsCursor: true)
        // Pointer sweeps left to right.
        let pointer: (Double) -> CGPoint? = { t in CGPoint(x: 0.1 + 0.08 * t, y: 0.5) }
        let track = VideoCameraTrack.build(regions: [region], segments: segments, timelineDuration: 10, speed: .smooth, stage: CGRect(x: 0, y: 0, width: 1, height: 1), cursor: pointer)
        for t in stride(from: 2.0, through: 8.0, by: 0.5) {
            let state = track.state(at: t)
            let x = pointer(t)!.x
            let half = 0.5 / state.scale
            XCTAssertLessThan(abs(x - state.centerX), half, "pointer on screen at \(t)")
        }
    }

    func testAutoZoomGivesEachBurstItsOwnRegion() {
        let project = project(duration: 20)
        let clicks = [2.0, 2.5, 9.0, 16.0].map { VideoDemoClickEvent(time: $0, x: 0.5, y: 0.5, button: .left) }
        let regions = VideoAutoZoomPlanner.regions(clicks: clicks, cursorSamples: [], segments: project.timelineSegments(totalDuration: 20), scale: 2, speed: .smooth)
        XCTAssertEqual(regions.count, 3)
        for region in regions {
            XCTAssertTrue(region.isAuto)
            XCTAssertFalse(region.followsCursor, "no pointer path → aim at the clicks")
        }
        // The zoom has landed before the first click.
        let first = regions[0]
        XCTAssertLessThan(first.start + VideoCameraTrack.transitionDuration(scale: 2, speed: .smooth), 2.0)
    }

    // MARK: Cursor track

    func testCursorLandsExactlyOnClicks() throws {
        var samples: [VideoDemoCursorSample] = []
        for i in 0...300 {
            let t = Double(i) / 60
            // Fast sweep to (0.8, 0.2) arriving at t=2, click at 2.05 while still.
            let u = min(t / 2, 1)
            samples.append(VideoDemoCursorSample(time: t, x: 0.1 + 0.7 * u, y: 0.8 - 0.6 * u))
        }
        let click = VideoDemoClickEvent(time: 2.05, x: 0.8, y: 0.2, button: .left, endTime: 2.15)
        let track = try XCTUnwrap(VideoCursorTrack.build(samples: samples, clicks: [click], smoothing: .silky, hideWhenIdle: false, duration: 5))
        let atClick = track.position(at: 2.1)
        XCTAssertEqual(atClick.x, 0.8, accuracy: 0.002)
        XCTAssertEqual(atClick.y, 0.2, accuracy: 0.002)
    }

    func testCursorHidesWhenIdleAndOutside() throws {
        var samples: [VideoDemoCursorSample] = []
        for i in 0...600 {
            let t = Double(i) / 60
            let x: Double = t < 1 ? 0.3 + 0.2 * t : (t < 8 ? 0.5 : 1.4)
            samples.append(VideoDemoCursorSample(time: t, x: x, y: 0.5))
        }
        let track = try XCTUnwrap(VideoCursorTrack.build(samples: samples, clicks: [], smoothing: .smooth, hideWhenIdle: true, duration: 10))
        XCTAssertGreaterThan(track.alpha(at: 0.5), 0.9)
        XCTAssertLessThan(track.alpha(at: 5), 0.05, "idle for seconds → hidden")
        XCTAssertLessThan(track.alpha(at: 9.5), 0.05, "outside the frame → hidden")
    }

    func testTidyEndingHidesTheDashToStop() throws {
        var samples: [VideoDemoCursorSample] = []
        for i in 0...600 {
            let t = Double(i) / 60
            // Still until 9.2s, then a dash up out of the frame.
            let y = t < 9.2 ? 0.6 : 0.6 - (t - 9.2) * 1.4
            samples.append(VideoDemoCursorSample(time: t, x: 0.5, y: y))
        }
        let track = try XCTUnwrap(VideoCursorTrack.build(samples: samples, clicks: [], smoothing: .smooth, hideWhenIdle: false, tidyEnding: true, duration: 10))
        let end = try XCTUnwrap(track.endTime)
        XCTAssertEqual(end, 9.2, accuracy: 0.1)
        XCTAssertEqual(track.position(at: 9.8).y, track.position(at: end).y, accuracy: 0.01, "frozen where the dash began")
        XCTAssertLessThan(track.alpha(at: 9.9), 0.05)
    }

    // MARK: Layers

    func testEffectLayerNormalizationSpreadsConflictsAndCompacts() {
        let a = VideoDemoOverlayEffect(kind: .highlight, time: 1, duration: 3)
        let b = VideoDemoOverlayEffect(kind: .text, time: 2, duration: 3)
        let c = VideoDemoOverlayEffect(kind: .arrow, time: 3, duration: 1)
        let solo = VideoDemoOverlayEffect(kind: .blur, time: 10, duration: 1, layer: 5)
        let normalized = VideoDemoProject.normalizedEffectLayers([a, b, c, solo])
        let layers = Dictionary(uniqueKeysWithValues: normalized.map { ($0.id, $0.layer) })
        XCTAssertEqual(layers[a.id], 0)
        XCTAssertEqual(layers[b.id], 1)
        XCTAssertEqual(layers[c.id], 2)
        XCTAssertEqual(layers[solo.id], 3, "empty lanes compact away")
    }

    // MARK: Stores

    func testRecordingMetadataAppliesCursorDefaults() {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"))
        let metadata = VideoDemoRecordingMetadata(
            videoURLPath: "/tmp/demo.mp4", createdAt: Date(), duration: 12, sourceWidth: 1920, sourceHeight: 1080, fps: 30,
            nativeCursorVisible: false,
            cursorSamples: [VideoDemoCursorSample(time: 1, x: 0.5, y: 0.25)],
            clickEvents: [VideoDemoClickEvent(time: 2, x: 0.6, y: 0.4, button: .left)]
        )
        project.apply(metadata: metadata)
        XCTAssertEqual(project.sourceSize, CGSize(width: 1920, height: 1080))
        XCTAssertTrue(project.cursor.visible)
        XCTAssertTrue(project.rendersCursor)
        XCTAssertEqual(project.trimEnd, 12, accuracy: 0.001)
    }

    func testSidecarRoundTripsRecordingMetadata() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let videoURL = dir.appendingPathComponent("demo.mp4")
        try Data().write(to: videoURL)
        let metadata = VideoDemoRecordingMetadata(
            videoURLPath: videoURL.path, createdAt: Date(timeIntervalSince1970: 1), duration: 3.5, sourceWidth: 100, sourceHeight: 80, fps: 60,
            nativeCursorVisible: false,
            cursorSamples: [VideoDemoCursorSample(time: 0.2, x: 0.1, y: 0.9)],
            clickEvents: [VideoDemoClickEvent(time: 1, x: 0.2, y: 0.3, button: .left, endTime: 1.4)],
            pointPixelScale: 2,
            cursorShapes: [VideoCursorShape(id: "a", hotSpotX: 4, hotSpotY: 4, width: 20, height: 30, pngData: Data([1, 2, 3]))],
            cursorShapeEvents: [VideoCursorShapeEvent(time: 0, shapeID: "a")],
            renderCursor: true
        )
        XCTAssertTrue(VideoDemoSidecarStore.save(metadata, for: videoURL, baseDirectory: dir))
        XCTAssertEqual(VideoDemoSidecarStore.load(for: videoURL, baseDirectory: dir), metadata)
    }

    func testOlderSidecarsStillDecode() throws {
        let json = """
        {"videoURLPath":"/tmp/a.mp4","createdAt":0,"duration":4,"sourceWidth":1280,"sourceHeight":720,"fps":30,
         "nativeCursorVisible":true,"cursorSamples":[{"time":0,"x":0.5,"y":0.5}],"clickEvents":[{"id":"\(UUID().uuidString)","time":1,"x":0.4,"y":0.6,"button":"left"}]}
        """
        let metadata = try JSONDecoder().decode(VideoDemoRecordingMetadata.self, from: Data(json.utf8))
        XCTAssertNil(metadata.pointPixelScale)
        XCTAssertFalse(metadata.shouldRenderCursor, "baked cursor → don't draw another")
        XCTAssertEqual(metadata.clickEvents.first?.pressDuration ?? 0, 0.12, accuracy: 0.001)
    }

    func testDraftStoreRoundTripsProject() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let videoURL = dir.appendingPathComponent("demo.mp4")
        var project = VideoDemoProject.make(sourceURL: videoURL, duration: 8, sourceSize: CGSize(width: 1280, height: 720))
        project.background = .wallpaper("lagoon")
        project.zoomRegions = [VideoZoomRegion(start: 1, end: 3, scale: 1.8, followsCursor: false, focusX: 0.4, focusY: 0.3)]
        XCTAssertTrue(VideoDemoDraftStore.save(project, for: videoURL, baseDirectory: dir))
        let draft = try XCTUnwrap(VideoDemoDraftStore.load(for: videoURL, baseDirectory: dir))
        XCTAssertEqual(draft.project, project)
        XCTAssertTrue(VideoDemoDraftStore.delete(for: videoURL, baseDirectory: dir))
        XCTAssertNil(VideoDemoDraftStore.load(for: videoURL, baseDirectory: dir))
    }

    func testRecentExportStoreKeepsNewestPerSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("source.mp4")
        let exportURL = dir.appendingPathComponent("export.mp4")
        try Data(repeating: 7, count: 4096).write(to: exportURL)
        let exports = VideoDemoRecentExportStore.add(exportURL: exportURL, sourceURL: sourceURL, baseDirectory: dir)
        XCTAssertEqual(exports.count, 1)
        XCTAssertEqual(VideoDemoRecentExportStore.load(for: sourceURL, baseDirectory: dir).first?.fileSize, 4096)
    }
}
