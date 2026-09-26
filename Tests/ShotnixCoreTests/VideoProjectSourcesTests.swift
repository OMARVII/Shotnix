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

    @MainActor
    func testStartOverKeepsTheAddedRecordings() async throws {
        let a = directory.appendingPathComponent("start-a.mp4")
        let b = directory.appendingPathComponent("start-b.mp4")
        try await VideoInspection.writeColorVideo(to: a, size: CGSize(width: 640, height: 400), colors: [(yellow, 2)])
        try await VideoInspection.writeColorVideo(to: b, size: CGSize(width: 640, height: 400), colors: [(green, 1.5)])
        let click = VideoDemoClickEvent(time: 0.5, x: 0.25, y: 0.25, button: .left, endTime: 0.6)
        let metadata = VideoDemoRecordingMetadata(videoURLPath: b.path, createdAt: Date(), duration: 1.5, sourceWidth: 640, sourceHeight: 400, fps: 30, nativeCursorVisible: true, cursorSamples: [], clickEvents: [click])
        XCTAssertTrue(VideoDemoSidecarStore.save(metadata, for: b))
        VideoDemoDraftStore.delete(for: a)
        let model = VideoEditorModel(videoURL: a)
        await model.load()
        let appended = await model.appendVideo(b)
        XCTAssertTrue(appended)
        let addedID = try XCTUnwrap(model.project.sources.last?.id)

        // Edits: an intro card, a cut, and the added recording moved first.
        model.setIntroEnabled(true)
        model.seek(to: 3.0)
        model.splitAtPlayhead()
        model.moveSource(addedID, by: -1)
        try await Task.sleep(nanoseconds: 300_000_000)
        let order = model.project.sources.map(\.id)
        XCTAssertEqual(order.first, addedID)

        model.resetToOriginal()
        XCTAssertEqual(model.project.sources.map(\.id), order, "the recordings stay, in their order")
        XCTAssertFalse(model.project.cards.intro.enabled, "the edits are gone")
        XCTAssertEqual(model.project.timelineClips.count, 2, "one clip per recording again")
        XCTAssertEqual(model.sourceDuration, 3.5, accuracy: 0.05)
        XCTAssertEqual(model.timelineDuration, 3.5, accuracy: 0.05)
        XCTAssertEqual(model.project.timelineClips.first?.sourceStart ?? 9, 0, accuracy: 0.001, "the moved recording still opens the video")
        XCTAssertTrue(model.project.clickEvents.contains { abs($0.time - 0.5) < 0.01 }, "its click is back where it plays")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.playback.timelineDuration, 3.5, accuracy: 0.1, "and both still play")

        // One undo brings the edits back.
        model.undo()
        XCTAssertTrue(model.project.cards.intro.enabled)
        model.stop()
        VideoDemoDraftStore.delete(for: a)
    }

    @MainActor
    func testTheCameraTabWorksWhenOnlyAnAddedRecordingHasACamera() async throws {
        let a = directory.appendingPathComponent("plain-a.mp4")
        let b = directory.appendingPathComponent("with-camera-b.mp4")
        let camera = directory.appendingPathComponent("b-camera.mp4")
        try await VideoInspection.writeColorVideo(to: a, size: CGSize(width: 640, height: 400), colors: [(yellow, 1.5)])
        try await VideoInspection.writeColorVideo(to: b, size: CGSize(width: 640, height: 400), colors: [(green, 1.5)])
        try await VideoInspection.writeColorVideo(to: camera, size: CGSize(width: 320, height: 240), colors: [(NSColor(srgbRed: 0.9, green: 0.1, blue: 0.8, alpha: 1), 1.5)])
        let metadata = VideoDemoRecordingMetadata(videoURLPath: b.path, createdAt: Date(), duration: 1.5, sourceWidth: 640, sourceHeight: 400, fps: 30, nativeCursorVisible: true, cursorSamples: [], clickEvents: [], webcam: VideoWebcamRecording(path: camera.path, offset: 0, width: 320, height: 240))
        XCTAssertTrue(VideoDemoSidecarStore.save(metadata, for: b))
        VideoDemoDraftStore.delete(for: a)
        let model = VideoEditorModel(videoURL: a)
        await model.load()
        XCTAssertFalse(model.hasCameraInAnyRecording, "no camera yet")

        let added = await model.appendVideo(b)
        XCTAssertTrue(added)
        XCTAssertTrue(model.hasCameraInAnyRecording, "the Camera tab offers the added recording's camera")
        XCTAssertTrue(model.hasWebcamFootage)
        XCTAssertNotNil(model.plan.webcam, "the bubble is part of the picture")
        XCTAssertFalse(model.plan.hasCameraFootage(at: 0.7), "not over the first recording, which has none")
        XCTAssertTrue(model.plan.hasCameraFootage(at: 2.2), "over the added one")
        // Its settings apply: hiding the camera hides the bubble.
        model.setStyle { $0.webcam.visible = false }
        XCTAssertEqual(model.plan.webcam?.visible, false)
        model.stop()
        VideoDemoDraftStore.delete(for: a)
    }

    /// Enhance voice cleans up every recording's microphone, not only the
    /// first one's — in the export and in the editor.
    func testEnhanceVoiceCoversEveryRecording() async throws {
        let a = directory.appendingPathComponent("talk-a.mp4")
        let b = directory.appendingPathComponent("talk-b.mp4")
        try await VideoInspection.writeColorVideo(to: a, size: CGSize(width: 640, height: 400), colors: [(yellow, 2)], toneSeconds: 2, toneFrequency: 440)
        try await VideoInspection.writeColorVideo(to: b, size: CGSize(width: 640, height: 400), colors: [(green, 2)], toneSeconds: 2, toneFrequency: 660)
        var project = VideoInspection.project(for: a, seconds: 2, size: CGSize(width: 640, height: 400))
        project.ensurePrimarySource(duration: 2, kinds: [.mixed], webcam: nil, pointPixelScale: nil)
        project.appendSource(VideoProjectSource(path: b.path, name: "talk-b.mp4", duration: 2, width: 640, height: 400, audioKinds: [.mixed]), metadata: nil)
        let targets = project.voiceTargets(primaryKinds: [.mixed])
        XCTAssertEqual(targets.map(\.url.lastPathComponent), ["talk-a.mp4", "talk-b.mp4"], "both voices get cleaned up")
        XCTAssertFalse(targets.contains(where: \.isReady))

        // Stand-ins for the cleaned-up voices (the real cleanup needs
        // Apple's voice isolation): a pitch of their own for each.
        for (target, frequency) in zip(targets, [880.0, 990.0]) {
            try FileManager.default.createDirectory(at: target.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try VideoInspection.writeTone(to: target.destination, frequency: frequency, seconds: 2, amplitude: 0.4)
        }
        XCTAssertTrue(project.voiceTargets(primaryKinds: [.mixed]).allSatisfy(\.isReady))
        project.audio.enhanceVoice = true
        let output = directory.appendingPathComponent("enhanced.mp4")
        try await VideoDemoExporter.export(project: project, destinationURL: output, settings: VideoInspection.mp4Settings())
        let samples = try VideoInspection.audio(of: output)
        func level(_ frequency: Double, _ from: Double, _ to: Double) -> Double {
            VideoInspection.toneLevel(samples, frequency: frequency, from: from, to: to)
        }
        XCTAssertGreaterThan(level(880, 0.4, 1.6), 0.1, "the first recording plays its cleaned-up voice")
        XCTAssertLessThan(level(440, 0.4, 1.6), 0.03, "not its raw sound")
        XCTAssertGreaterThan(level(990, 2.4, 3.6), 0.1, "so does the added one: \(level(990, 2.4, 3.6))")
        XCTAssertLessThan(level(660, 2.4, 3.6), 0.03, "not its raw sound: \(level(660, 2.4, 3.6))")
    }

    @MainActor
    func testTheEditorOffersAndUsesEnhanceVoiceForAnAddedRecording() async throws {
        // The first recording is silent; only the added one talks.
        let a = directory.appendingPathComponent("silent-a.mp4")
        let b = directory.appendingPathComponent("talk-b.mp4")
        try await VideoInspection.writeColorVideo(to: a, size: CGSize(width: 640, height: 400), colors: [(yellow, 2)])
        try await VideoInspection.writeColorVideo(to: b, size: CGSize(width: 640, height: 400), colors: [(green, 1.5)], toneSeconds: 1.5, toneFrequency: 660)
        VideoDemoDraftStore.delete(for: a)
        let model = VideoEditorModel(videoURL: a)
        await model.load()
        XCTAssertFalse(model.project.appendedSourceHasVoice)
        let added = await model.appendVideo(b)
        XCTAssertTrue(added)
        XCTAssertTrue(model.project.appendedSourceHasVoice)
        XCTAssertEqual(model.canEnhanceVoice, VideoVoiceEnhancer.isAvailable, "Enhance voice is offered for the added recording's voice")

        // Once its cleaned-up voice exists, the preview plays it.
        let target = try XCTUnwrap(model.project.voiceTargets(primaryKinds: model.audioKinds).first)
        XCTAssertEqual(target.url.lastPathComponent, "talk-b.mp4")
        try FileManager.default.createDirectory(at: target.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try VideoInspection.writeTone(to: target.destination, frequency: 990, seconds: 1.5, amplitude: 0.4)
        model.setStyle { $0.audio.enhanceVoice = true }
        await model.refreshAudioSources()
        let entry = try XCTUnwrap(model.media.layout?.entries.first { !$0.source.isPrimary })
        XCTAssertEqual(entry.audio.first?.identity, target.destination.path, "the added recording's cleaned-up voice is in the edit")
        model.stop()
        VideoDemoDraftStore.delete(for: a)
    }

    /// Recordings made on different screens: each pointer is drawn at its
    /// own Retina scale, and a recording of another shape keeps its pointer
    /// on its own picture.
    func testEachRecordingKeepsItsOwnPointerSizeAndPlace() throws {
        func samples(_ duration: Double, at point: (Double, Double), after: Double = .infinity, moveTo: (Double, Double) = (0, 0)) -> [VideoDemoCursorSample] {
            stride(from: 0.0, through: duration, by: 0.05).map { t in
                t < after ? VideoDemoCursorSample(time: t, x: point.0, y: point.1) : VideoDemoCursorSample(time: t, x: moveTo.0, y: moveTo.1)
            }
        }
        func metadata(_ path: String, width: Double, height: Double, scale: Double, cursor: [VideoDemoCursorSample], clicks: [VideoDemoClickEvent] = []) -> VideoDemoRecordingMetadata {
            VideoDemoRecordingMetadata(videoURLPath: path, createdAt: Date(), duration: 2, sourceWidth: width, sourceHeight: height, fps: 30, nativeCursorVisible: false, cursorSamples: cursor, clickEvents: clicks, pointPixelScale: scale, renderCursor: true)
        }
        // A: 1280×800 on a Retina screen (2×).
        let primary = metadata("/tmp/pointer-a.mp4", width: 1280, height: 800, scale: 2, cursor: samples(2, at: (0.5, 0.5)))
        var project = VideoInspection.project(for: URL(fileURLWithPath: primary.videoURLPath), seconds: 2, size: CGSize(width: 1280, height: 800))
        project.apply(metadata: primary)
        project.cursor.visible = true
        project.cursor.hideWhenIdle = false
        project.cursor.tidyEnding = false
        project.cursor.motionBlur = false
        project.cursor.clickEffect = .none
        project.ensurePrimarySource(duration: 2, kinds: [], webcam: nil, pointPixelScale: 2)
        // B: the same pixels from a 1× display — a half-size pointer.
        let b = metadata("/tmp/pointer-b.mp4", width: 1280, height: 800, scale: 1, cursor: samples(2, at: (0.5, 0.5)))
        project.appendSource(VideoProjectSource(path: b.videoURLPath, name: "b.mp4", duration: 2, width: 1280, height: 800, hasPointer: true, pointPixelScale: 1), metadata: b)
        // C: a small square area at 2×, fitted (twice as big) into the frame;
        // its pointer leaves its picture after a second.
        let corner = VideoDemoClickEvent(time: 0.5, x: 0, y: 0, button: .left, endTime: 0.6)
        let c = metadata("/tmp/pointer-c.mp4", width: 400, height: 400, scale: 2, cursor: samples(2, at: (0.5, 0.5), after: 1, moveTo: (-0.2, 0.5)), clicks: [corner])
        project.appendSource(VideoProjectSource(path: c.videoURLPath, name: "c.mp4", duration: 2, width: 400, height: 400, hasPointer: true, pointPixelScale: 2), metadata: c)

        // C's picture spans 18.75%–81.25% of the width: its click in its own
        // top-left corner lands there.
        let click = try XCTUnwrap(project.clickEvents.first { $0.time >= 4 })
        XCTAssertEqual(click.x, 0.1875, accuracy: 0.001)
        XCTAssertEqual(click.y, 0, accuracy: 0.001)
        let track = try XCTUnwrap(VideoSourcesPointer.cursorTrack(project: project, duration: 6))
        XCTAssertGreaterThan(track.alpha(at: 4.5), 0.9, "on its picture, the pointer shows")
        XCTAssertLessThan(track.alpha(at: 5.9), 0.05, "over the bars beside it, it's hidden")

        let plan = VideoDemoExporter.makePlan(project: project, sourceDuration: 6, recording: primary)
        XCTAssertEqual(plan.pointerScale(at: 1), 2, accuracy: 0.001)
        XCTAssertEqual(plan.pointerScale(at: 3), 1, accuracy: 0.001)
        XCTAssertEqual(plan.pointerScale(at: 4.5), 4, accuracy: 0.001, "2× recording, shown twice as big")

        // Drawn: dark arrow pixels around the middle of the frame.
        let size = CGSize(width: 640, height: 400)
        let light = CIImage(color: CIColor(red: 0.85, green: 0.85, blue: 0.85)).cropped(to: CGRect(origin: .zero, size: size))
        let renderer = VideoFrameRenderer()
        func arrowPixels(at time: Double) -> Int {
            let image = renderer.render(source: light, timelineTime: time, plan: plan, outputSize: size)
            let cgImage = VideoRenderContext.shared.createCGImage(image, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
            var data = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
            let context = CGContext(data: &data, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cgImage, in: CGRect(origin: .zero, size: size))
            var count = 0
            for y in 150..<340 {
                for x in 280..<440 {
                    let index = (y * Int(size.width) + x) * 4
                    if Int(data[index]) + Int(data[index + 1]) + Int(data[index + 2]) < 230 { count += 1 }
                }
            }
            return count
        }
        let retina = arrowPixels(at: 1)
        let standard = arrowPixels(at: 3)
        let magnified = arrowPixels(at: 4.5)
        XCTAssertGreaterThan(retina, 20, "the arrow is drawn")
        XCTAssertEqual(Double(standard) / Double(retina), 0.25, accuracy: 0.12, "half as tall on the 1× recording (\(standard) vs \(retina))")
        XCTAssertEqual(Double(magnified) / Double(retina), 4, accuracy: 1.5, "twice as tall on the magnified one (\(magnified) vs \(retina))")
    }

    /// A phone clip stored sideways (with a rotation) added after a screen
    /// recording: upright and fitted, with the recording's camera on or off.
    func testARotatedAddedVideoStaysUprightWithOrWithoutTheCamera() async throws {
        let red = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        let blue = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1)
        let magenta = NSColor(srgbRed: 0.9, green: 0.1, blue: 0.8, alpha: 1)
        let screen = directory.appendingPathComponent("screen.mp4")
        try await VideoInspection.writeColorVideo(to: screen, size: CGSize(width: 1280, height: 800), colors: [(yellow, 1.5)])
        let camera = directory.appendingPathComponent("camera.mp4")
        try await VideoInspection.writeColorVideo(to: camera, size: CGSize(width: 640, height: 480), colors: [(magenta, 1.5)])
        // Stored 320×240 (red | blue), shown portrait 240×320: red on top.
        let phone = directory.appendingPathComponent("phone.mp4")
        try await VideoInspection.writeSplitVideo(to: phone, size: CGSize(width: 320, height: 240), left: red, right: blue, seconds: 1.5, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0))
        let phoneTracks = try await VideoSourceTracks.load(url: phone)
        XCTAssertEqual(phoneTracks.size, CGSize(width: 240, height: 320), "portrait once turned")

        let webcam = VideoWebcamRecording(path: camera.path, offset: 0, width: 640, height: 480)
        let metadata = VideoDemoRecordingMetadata(videoURLPath: screen.path, createdAt: Date(), duration: 1.5, sourceWidth: 1280, sourceHeight: 800, fps: 30, nativeCursorVisible: true, cursorSamples: [], clickEvents: [], webcam: webcam)
        var project = VideoInspection.project(for: screen, seconds: 1.5, size: CGSize(width: 1280, height: 800))
        project.ensurePrimarySource(duration: 1.5, kinds: [], webcam: webcam, pointPixelScale: nil)
        project.appendSource(VideoProjectSource(path: phone.path, name: "phone.mp4", duration: 1.5, width: 240, height: 320), metadata: nil)
        // With the camera, the song and the end card too (the camera's
        // compositor has to cover the music past the picture).
        let song = directory.appendingPathComponent("song.m4a")
        try VideoInspection.writeTone(to: song, frequency: 330, seconds: 8, amplitude: 0.3)
        let stored = try VideoAssetStore.importFile(song)

        for cameraOn in [true, false] {
            project.webcam.visible = cameraOn
            var settings = VideoInspection.mp4Settings()
            if cameraOn {
                project.music = VideoMusicTrack(path: stored.path, name: "song.m4a", duration: 8)
                settings.endCard = true
            }
            let output = directory.appendingPathComponent("rotated-\(cameraOn).mp4")
            try await VideoDemoExporter.export(project: project, recording: metadata, destinationURL: output, settings: settings)
            let length = try await AVURLAsset(url: output).load(.duration).seconds
            XCTAssertEqual(length, cameraOn ? 5 : 3, accuracy: 0.15)

            let added = try VideoInspection.frame(of: output, at: 2.2)
            let top = VideoInspection.color(of: added, x: 0.5, y: 0.2)
            let bottom = VideoInspection.color(of: added, x: 0.5, y: 0.8)
            let bar = VideoInspection.color(of: added, x: 0.08, y: 0.5)
            XCTAssertTrue(VideoInspection.isClose(top, (0.9, 0.1, 0.1), tolerance: 0.15), "upright, red on top (camera \(cameraOn ? "on" : "off")): \(top)")
            XCTAssertTrue(VideoInspection.isClose(bottom, (0.1, 0.2, 0.9), tolerance: 0.15), "blue below (camera \(cameraOn ? "on" : "off")): \(bottom)")
            XCTAssertLessThan(bar.r + bar.g + bar.b, 0.15, "fitted between black bars, not stretched: \(bar)")

            // The camera bubble (bottom right) shows over the screen recording.
            let first = try VideoInspection.frame(of: output, at: 0.7)
            let bubble = VideoInspection.color(of: first, x: 0.893, y: 0.83)
            if cameraOn {
                XCTAssertTrue(VideoInspection.isClose(bubble, (0.9, 0.1, 0.8), tolerance: 0.2), "the camera shows: \(bubble)")
            } else {
                XCTAssertTrue(VideoInspection.isClose(bubble, (1, 0.85, 0), tolerance: 0.15), "no camera: \(bubble)")
            }
        }
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

    func testAMissingRecordingKeepsTheTimingAsBlack() async throws {
        let (project, a, b, _) = try await twoRecordings()
        try FileManager.default.removeItem(at: b)
        let primary = try await VideoSourceTracks.load(url: a)
        let loaded = await VideoSourceLayout.load(project: project, primary: primary, primaryAudio: [], primaryCamera: nil)
        let layout = try XCTUnwrap(loaded)
        XCTAssertEqual(layout.entries.count, 1, "only the recording that's there loads")
        var extras = VideoEditExtras()
        extras.layout = layout
        let edit = try VideoCompositionBuilder.build(source: primary, segments: project.timelineSegments(totalDuration: 3.5), audio: project.audio, extras: extras)
        XCTAssertEqual(edit.duration.seconds, 3.5, accuracy: 0.05, "the missing part stays on the timeline (black)")
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
