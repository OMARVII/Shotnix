import AVFoundation
import XCTest
@testable import ShotnixCore

final class VideoDemoProjectTests: XCTestCase {
    func testAspectPresetsUseStableExportCanvasSizes() {
        let source = CGSize(width: 1333, height: 777)

        XCTAssertEqual(VideoDemoProject.AspectPreset.widescreen.canvasSize(sourceSize: source), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(VideoDemoProject.AspectPreset.vertical.canvasSize(sourceSize: source), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(VideoDemoProject.AspectPreset.square.canvasSize(sourceSize: source), CGSize(width: 1440, height: 1440))
        XCTAssertEqual(VideoDemoProject.AspectPreset.source.canvasSize(sourceSize: source), CGSize(width: 1334, height: 778))
    }

    func testSourceFrameUsesRawCanvasWithoutPremiumChrome() {
        var project = VideoDemoProject.make(
            sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"),
            duration: 10,
            sourceSize: CGSize(width: 1280, height: 720)
        )

        project.apply(aspectPreset: .source)

        XCTAssertTrue(project.usesRawSourceFrame)
        XCTAssertEqual(project.stageInset, 0, accuracy: 0.001)
        XCTAssertEqual(project.shadowStrength, 0, accuracy: 0.001)
        XCTAssertEqual(project.cornerRadius, 0, accuracy: 0.001)
        XCTAssertEqual(project.stageRect(in: project.canvasSize()), CGRect(x: 0, y: 0, width: 1280, height: 720))
    }

    func testLeavingSourceFrameRestoresPremiumDefaults() {
        var project = VideoDemoProject.make(
            sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"),
            duration: 10,
            sourceSize: CGSize(width: 1280, height: 720)
        )

        project.apply(aspectPreset: .source)
        project.apply(aspectPreset: .widescreen)

        XCTAssertFalse(project.usesRawSourceFrame)
        XCTAssertEqual(project.stageInset, 0.085, accuracy: 0.001)
        XCTAssertEqual(project.shadowStrength, 0.42, accuracy: 0.001)
        XCTAssertEqual(project.cornerRadius, 24, accuracy: 0.001)
        XCTAssertLessThan(project.stageRect(in: project.canvasSize()).width, project.canvasSize().width)
    }

    func testTrimRangeClampsToDuration() {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 20)
        project.trimStart = -4
        project.trimEnd = 99

        let trim = project.normalizedTrim(totalDuration: 20)

        XCTAssertEqual(trim.start, 0, accuracy: 0.001)
        XCTAssertEqual(trim.end, 20, accuracy: 0.001)
    }

    func testTimelineSeedsSingleClipFromDuration() {
        let project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 12)

        let segments = project.timelineSegments(totalDuration: 12)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].clip.sourceStart, 0, accuracy: 0.001)
        XCTAssertEqual(segments[0].clip.sourceEnd, 12, accuracy: 0.001)
        XCTAssertEqual(project.timelineDuration(totalDuration: 12), 12, accuracy: 0.001)
    }

    func testTimelineSplitsClipAtSourceTime() {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 10)

        let newClipID = project.splitClip(atSourceTime: 4, totalDuration: 10)
        let segments = project.timelineSegments(totalDuration: 10)

        XCTAssertNotNil(newClipID)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].clip.sourceStart, 0, accuracy: 0.001)
        XCTAssertEqual(segments[0].clip.sourceEnd, 4, accuracy: 0.001)
        XCTAssertEqual(segments[1].timelineStart, 4, accuracy: 0.001)
        XCTAssertEqual(segments[1].clip.sourceStart, 4, accuracy: 0.001)
        XCTAssertEqual(segments[1].clip.sourceEnd, 10, accuracy: 0.001)
    }

    func testTimelineDeleteRipplesRemainingClips() {
        let middleID = UUID()
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 10)
        project.timelineClips = [
            VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 3),
            VideoDemoTimelineClip(id: middleID, sourceStart: 3, sourceEnd: 5),
            VideoDemoTimelineClip(sourceStart: 5, sourceEnd: 10),
        ]

        let selectedID = project.deleteClip(id: middleID, totalDuration: 10)
        let segments = project.timelineSegments(totalDuration: 10)

        XCTAssertNotNil(selectedID)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].timelineStart, 0, accuracy: 0.001)
        XCTAssertEqual(segments[0].timelineEnd, 3, accuracy: 0.001)
        XCTAssertEqual(segments[1].timelineStart, 3, accuracy: 0.001)
        XCTAssertEqual(segments[1].timelineEnd, 8, accuracy: 0.001)
        XCTAssertEqual(project.timelineDuration(totalDuration: 10), 8, accuracy: 0.001)
    }

    func testTimelineRangeDeleteSplitsAndRipplesClips() throws {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 12)
        project.timelineClips = [
            VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 5),
            VideoDemoTimelineClip(sourceStart: 5, sourceEnd: 12),
        ]

        let nextID = project.deleteTimelineRange(start: 3, end: 8, totalDuration: 12)
        let segments = project.timelineSegments(totalDuration: 12)

        XCTAssertNotNil(nextID)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].clip.sourceStart, 0, accuracy: 0.001)
        XCTAssertEqual(segments[0].clip.sourceEnd, 3, accuracy: 0.001)
        XCTAssertEqual(segments[1].timelineStart, 3, accuracy: 0.001)
        XCTAssertEqual(segments[1].clip.sourceStart, 8, accuracy: 0.001)
        XCTAssertEqual(segments[1].clip.sourceEnd, 12, accuracy: 0.001)
        XCTAssertEqual(project.timelineDuration(totalDuration: 12), 7, accuracy: 0.001)
    }

    func testTimelineRangeDeleteKeepsAtLeastOneClip() {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 8)

        XCTAssertNil(project.deleteTimelineRange(start: 0, end: 8, totalDuration: 8))
        XCTAssertEqual(project.timelineSegments(totalDuration: 8).count, 1)
        XCTAssertEqual(project.timelineDuration(totalDuration: 8), 8, accuracy: 0.001)
    }

    func testTimelineMapsBetweenEditedAndSourceTimesAcrossCut() {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 10)
        project.timelineClips = [
            VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 3),
            VideoDemoTimelineClip(sourceStart: 5, sourceEnd: 10),
        ]

        XCTAssertEqual(project.sourceTime(forTimelineTime: 3.5, totalDuration: 10), 5.5, accuracy: 0.001)
        XCTAssertEqual(project.timelineTime(forSourceTime: 6, totalDuration: 10), 4, accuracy: 0.001)
        XCTAssertNil(project.timelineTimeIfIncluded(sourceTime: 4, totalDuration: 10))
    }

    func testTimelineSpeedChangesOutputDurationAndMappings() {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 10)
        project.timelineClips = [
            VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 4, speed: 2),
            VideoDemoTimelineClip(sourceStart: 4, sourceEnd: 10, speed: 0.5),
        ]

        let segments = project.timelineSegments(totalDuration: 10)

        XCTAssertEqual(segments[0].duration, 2, accuracy: 0.001)
        XCTAssertEqual(segments[1].timelineStart, 2, accuracy: 0.001)
        XCTAssertEqual(segments[1].duration, 12, accuracy: 0.001)
        XCTAssertEqual(project.timelineDuration(totalDuration: 10), 14, accuracy: 0.001)
        XCTAssertEqual(project.sourceTime(forTimelineTime: 1, totalDuration: 10), 2, accuracy: 0.001)
        XCTAssertEqual(project.timelineTime(forSourceTime: 5, totalDuration: 10), 4, accuracy: 0.001)
    }

    func testTimelineSplitPreservesSpeedMuteAndFades() throws {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 8)
        project.timelineClips = [
            VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 8, speed: 1.5, muted: true, fadeIn: 0.4, fadeOut: 0.6),
        ]

        _ = project.splitClip(atSourceTime: 3, totalDuration: 8)
        let segments = project.timelineSegments(totalDuration: 8)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].clip.normalizedSpeed, 1.5, accuracy: 0.001)
        XCTAssertTrue(segments[0].clip.muted)
        XCTAssertEqual(segments[0].clip.fadeIn, 0.4, accuracy: 0.001)
        XCTAssertEqual(segments[0].clip.fadeOut, 0, accuracy: 0.001)
        XCTAssertEqual(segments[1].clip.fadeIn, 0, accuracy: 0.001)
        XCTAssertEqual(segments[1].clip.fadeOut, 0.6, accuracy: 0.001)
    }

    func testClipAudioControlsClampToOutputDuration() throws {
        let clipID = UUID()
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 4)
        project.timelineClips = [VideoDemoTimelineClip(id: clipID, sourceStart: 0, sourceEnd: 4)]

        XCTAssertTrue(project.updateClip(id: clipID, totalDuration: 4) { clip in
            clip.speed = 8
            clip.muted = true
            clip.fadeIn = 99
            clip.fadeOut = 99
        })
        let clip = try XCTUnwrap(project.timelineSegments(totalDuration: 4).first?.clip)

        XCTAssertEqual(clip.normalizedSpeed, 4, accuracy: 0.001)
        XCTAssertTrue(clip.muted)
        XCTAssertEqual(clip.outputDuration, 1, accuracy: 0.001)
        XCTAssertEqual(clip.fadeIn, 0.5, accuracy: 0.001)
        XCTAssertEqual(clip.fadeOut, 0.5, accuracy: 0.001)
    }

    func testOverlayEffectsActivateAndRoundTrip() throws {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 5)
        project.overlayEffects = [
            VideoDemoOverlayEffect(kind: .text, time: 1, duration: 2, text: "Ship"),
            VideoDemoOverlayEffect(kind: .blur, time: 4, duration: 1),
        ]

        XCTAssertEqual(project.overlayEffectsActive(at: 1.5).map(\.kind), [.text])
        XCTAssertEqual(project.overlayEffectsActive(at: 4.2).map(\.kind), [.blur])

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(VideoDemoProject.self, from: data)

        XCTAssertEqual(decoded.overlayEffects.count, 2)
        XCTAssertEqual(decoded.overlayEffects.first?.text, "Ship")
    }

    func testTimelineTrimsSelectedClip() throws {
        let clipID = UUID()
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 8)
        project.timelineClips = [VideoDemoTimelineClip(id: clipID, sourceStart: 0, sourceEnd: 8)]

        XCTAssertTrue(project.trimClip(id: clipID, sourceStart: 2, sourceEnd: 6, totalDuration: 8))
        let segment = try XCTUnwrap(project.timelineSegments(totalDuration: 8).first)

        XCTAssertEqual(segment.clip.sourceStart, 2, accuracy: 0.001)
        XCTAssertEqual(segment.clip.sourceEnd, 6, accuracy: 0.001)
        XCTAssertEqual(project.trimStart, 2, accuracy: 0.001)
        XCTAssertEqual(project.trimEnd, 6, accuracy: 0.001)
    }

    func testLegacyProjectDecodingDefaultsTimelineClips() throws {
        let project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 10)
        let data = try JSONEncoder().encode(project)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "timelineClips")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(VideoDemoProject.self, from: legacyData)

        XCTAssertTrue(decoded.timelineClips.isEmpty)
        let fallbackClip = try XCTUnwrap(decoded.normalizedTimelineClips(totalDuration: 10).first)
        XCTAssertEqual(fallbackClip.sourceEnd, 10, accuracy: 0.001)
    }

    func testStageRectFitsSourceWithinCanvasInset() {
        var project = VideoDemoProject.make(
            sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"),
            duration: 10,
            sourceSize: CGSize(width: 2560, height: 1440)
        )
        project.stageInset = 0.1
        project.aspectPreset = .vertical

        let canvas = project.canvasSize()
        let rect = project.stageRect(in: canvas)

        XCTAssertLessThanOrEqual(rect.width, canvas.width * 0.8 + 0.001)
        XCTAssertLessThanOrEqual(rect.height, canvas.height * 0.8 + 0.001)
        XCTAssertEqual(rect.width / rect.height, 16.0 / 9.0, accuracy: 0.001)
    }

    func testExportPresetsUpdateFrameAndStyling() {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 10)

        project.apply(preset: .reels)

        XCTAssertEqual(project.aspectPreset, .vertical)
        XCTAssertEqual(project.backgroundPreset, .plum)
        XCTAssertEqual(project.canvasSize(), CGSize(width: 1080, height: 1920))
        XCTAssertGreaterThan(project.shadowStrength, 0)
        XCTAssertGreaterThan(project.cornerRadius, 0)
    }

    func testZoomStateInterpolatesBetweenKeyframes() {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 10)
        project.zoomKeyframes = [
            VideoDemoZoomKeyframe(time: 2, scale: 1.5, focusX: 0.2, focusY: 0.4),
            VideoDemoZoomKeyframe(time: 6, scale: 2.5, focusX: 0.8, focusY: 0.6),
        ]

        let before = project.zoomState(at: 1)
        let quarter = project.zoomState(at: 3)
        let middle = project.zoomState(at: 4)
        let after = project.zoomState(at: 7)

        XCTAssertEqual(before.scale, 1, accuracy: 0.001)
        XCTAssertGreaterThan(quarter.scale, 1.5)
        XCTAssertLessThan(quarter.scale, 1.75)
        XCTAssertEqual(middle.scale, 2, accuracy: 0.001)
        XCTAssertEqual(middle.focusX, 0.5, accuracy: 0.001)
        XCTAssertEqual(after.scale, 2.5, accuracy: 0.001)
    }

    func testExportZoomRampPlanningDoesNotStretchCloseKeyframes() throws {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 1)
        project.zoomKeyframes = [
            VideoDemoZoomKeyframe(time: 0, scale: 1, focusX: 0.5, focusY: 0.5),
            VideoDemoZoomKeyframe(time: 0.02, scale: 1.4, focusX: 0.4, focusY: 0.4),
            VideoDemoZoomKeyframe(time: 0.04, scale: 1.7, focusX: 0.35, focusY: 0.35),
            VideoDemoZoomKeyframe(time: 0.10, scale: 1, focusX: 0.5, focusY: 0.5),
        ]

        let keyframes = VideoDemoExporter.zoomTimelineKeyframes(
            project: project,
            segments: project.timelineSegments(totalDuration: 1)
        )
        let closePair = try XCTUnwrap(zip(keyframes, keyframes.dropFirst()).first { pair in
            let delta = pair.1.timelineTime - pair.0.timelineTime
            return delta > 0 && delta < 0.03
        })

        XCTAssertNil(VideoDemoExporter.zoomRampDuration(from: closePair.0.timelineTime, to: closePair.1.timelineTime))
        for pair in zip(keyframes, keyframes.dropFirst()) {
            let delta = pair.1.timelineTime - pair.0.timelineTime
            guard let plannedDuration = VideoDemoExporter.zoomRampDuration(
                from: pair.0.timelineTime,
                to: pair.1.timelineTime
            ) else { continue }

            XCTAssertEqual(plannedDuration, delta, accuracy: 0.0001)
            XCTAssertLessThanOrEqual(plannedDuration, delta + 0.0001)
        }
    }

    func testExporterHandlesCloseZoomKeyframesForShortClip() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appendingPathComponent("source.mp4")
        let destinationURL = dir.appendingPathComponent("export.mp4")
        try await writeTinyMP4(to: sourceURL)

        var project = VideoDemoProject.make(
            sourceURL: sourceURL,
            duration: 0.5,
            sourceSize: CGSize(width: 64, height: 36)
        )
        project.aspectPreset = .source
        project.showClickRipple = false
        project.zoomKeyframes = [
            VideoDemoZoomKeyframe(time: 0, scale: 1, focusX: 0.5, focusY: 0.5),
            VideoDemoZoomKeyframe(time: 0.02, scale: 1.4, focusX: 0.4, focusY: 0.4),
            VideoDemoZoomKeyframe(time: 0.04, scale: 1.7, focusX: 0.35, focusY: 0.35),
            VideoDemoZoomKeyframe(time: 0.10, scale: 1, focusX: 0.5, focusY: 0.5),
        ]

        try await VideoDemoExporter.export(project: project, destinationURL: destinationURL)

        let fileSize = try destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(fileSize, 0)
    }

    @MainActor
    func testAutoZoomClustersNearbyClicksIntoSingleCameraMove() {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: 5)
        project.clickEvents = [
            VideoDemoClickEvent(time: 1.0, x: 0.22, y: 0.30, button: .left),
            VideoDemoClickEvent(time: 1.6, x: 0.28, y: 0.34, button: .left),
        ]
        let model = VideoDemoEditorViewModel(project: project)
        model.duration = 5

        model.addAutoZoomPreset()

        let strongZooms = model.project.zoomKeyframes.filter { $0.scale > 1.5 }
        XCTAssertLessThanOrEqual(model.project.zoomKeyframes.count, 6)
        XCTAssertEqual(strongZooms.count, 2)
        XCTAssertLessThanOrEqual(model.project.zoomKeyframes.map(\.scale).max() ?? 0, 1.75)
    }

    func testRecordingMetadataAppliesCursorDefaults() {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"))
        let metadata = VideoDemoRecordingMetadata(
            videoURLPath: "/tmp/demo.mp4",
            createdAt: Date(),
            duration: 12,
            sourceWidth: 1920,
            sourceHeight: 1080,
            fps: 30,
            nativeCursorVisible: false,
            cursorSamples: [VideoDemoCursorSample(time: 1, x: 0.5, y: 0.25)],
            clickEvents: [VideoDemoClickEvent(time: 2, x: 0.6, y: 0.4, button: .left)]
        )

        project.apply(metadata: metadata)

        XCTAssertEqual(project.sourceSize, CGSize(width: 1920, height: 1080))
        XCTAssertTrue(project.showCursorOverlay)
        XCTAssertTrue(project.showClickRipple)
        XCTAssertEqual(project.cursorSamples.count, 1)
        XCTAssertEqual(project.clickEvents.count, 1)
        XCTAssertEqual(project.trimEnd, 12, accuracy: 0.001)
    }

    func testSidecarRoundTripsRecordingMetadata() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let videoURL = dir.appendingPathComponent("demo.mp4")
        try Data().write(to: videoURL)
        let metadata = VideoDemoRecordingMetadata(
            videoURLPath: videoURL.path,
            createdAt: Date(timeIntervalSince1970: 1),
            duration: 3.5,
            sourceWidth: 100,
            sourceHeight: 80,
            fps: 60,
            nativeCursorVisible: true,
            cursorSamples: [VideoDemoCursorSample(time: 0.2, x: 0.1, y: 0.9)],
            clickEvents: []
        )

        XCTAssertTrue(VideoDemoSidecarStore.save(metadata, for: videoURL, baseDirectory: dir))
        let loaded = VideoDemoSidecarStore.load(for: videoURL, baseDirectory: dir)

        XCTAssertEqual(loaded, metadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: VideoDemoSidecarStore.metadataURL(for: videoURL, baseDirectory: dir).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: VideoDemoSidecarStore.legacySidecarURL(for: videoURL).path))
    }

    func testSidecarMigratesLegacyDesktopMetadata() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let videoURL = dir.appendingPathComponent("legacy.mp4")
        try Data().write(to: videoURL)
        let metadata = VideoDemoRecordingMetadata(
            videoURLPath: videoURL.path,
            createdAt: Date(timeIntervalSince1970: 2),
            duration: 4,
            sourceWidth: 1280,
            sourceHeight: 720,
            fps: 30,
            nativeCursorVisible: false,
            cursorSamples: [],
            clickEvents: [VideoDemoClickEvent(time: 0.7, x: 0.4, y: 0.6, button: .left)]
        )
        let legacyURL = VideoDemoSidecarStore.legacySidecarURL(for: videoURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: legacyURL, options: .atomic)

        let loaded = VideoDemoSidecarStore.load(for: videoURL, baseDirectory: dir)

        XCTAssertEqual(loaded, metadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: VideoDemoSidecarStore.metadataURL(for: videoURL, baseDirectory: dir).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testVideoDraftStoreRoundTripsProject() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let videoURL = dir.appendingPathComponent("demo.mp4")
        var project = VideoDemoProject.make(sourceURL: videoURL, duration: 8, sourceSize: CGSize(width: 1280, height: 720))
        project.backgroundPreset = .mint
        project.zoomKeyframes = [VideoDemoZoomKeyframe(time: 1, scale: 1.8, focusX: 0.4, focusY: 0.3)]

        XCTAssertTrue(VideoDemoDraftStore.save(project, for: videoURL, baseDirectory: dir))
        let draft = try XCTUnwrap(VideoDemoDraftStore.load(for: videoURL, baseDirectory: dir))

        XCTAssertEqual(draft.sourcePath, videoURL.standardizedFileURL.path)
        XCTAssertEqual(draft.project.backgroundPreset, .mint)
        let zoom = try XCTUnwrap(draft.project.zoomKeyframes.first)
        XCTAssertEqual(zoom.scale, 1.8, accuracy: 0.001)
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
        let loaded = VideoDemoRecentExportStore.load(for: sourceURL, baseDirectory: dir)

        XCTAssertEqual(exports.count, 1)
        XCTAssertEqual(loaded.first?.exportPath, exportURL.standardizedFileURL.path)
        XCTAssertEqual(loaded.first?.fileSize, 4096)
    }

    private func writeTinyMP4(to url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 36,
            ]
        )
        input.expectsMediaDataInRealTime = false

        guard writer.canAdd(input) else {
            throw NSError(domain: "ShotnixVideoDemoProjectTests", code: 1)
        }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 36,
            ]
        )

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "ShotnixVideoDemoProjectTests", code: 2)
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<15 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let buffer = try makePixelBuffer(width: 64, height: 36, frame: frame)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)) else {
                throw writer.error ?? NSError(domain: "ShotnixVideoDemoProjectTests", code: 3)
            }
        }

        input.markAsFinished()
        let writerBox = AssetWriterBox(writer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerBox.writer.finishWriting {
                if writerBox.writer.status == .completed {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: writerBox.writer.error ?? NSError(domain: "ShotnixVideoDemoProjectTests", code: 4))
                }
            }
        }
    }

    private func makePixelBuffer(width: Int, height: Int, frame: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw NSError(domain: "ShotnixVideoDemoProjectTests", code: 5)
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw NSError(domain: "ShotnixVideoDemoProjectTests", code: 6)
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                bytes[offset] = UInt8((x * 3 + frame * 5) % 255)
                bytes[offset + 1] = UInt8((y * 5 + frame * 9) % 255)
                bytes[offset + 2] = UInt8((frame * 17) % 255)
                bytes[offset + 3] = 255
            }
        }

        return buffer
    }

    private final class AssetWriterBox: @unchecked Sendable {
        let writer: AVAssetWriter

        init(_ writer: AVAssetWriter) {
            self.writer = writer
        }
    }
}
