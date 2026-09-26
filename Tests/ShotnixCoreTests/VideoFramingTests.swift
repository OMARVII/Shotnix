import AppKit
import AVFoundation
import CoreImage
import XCTest
@testable import ShotnixCore

/// Title cards, image annotations, transitions, music, and click sounds —
/// through the real exporter, checked in the file's pixels and sound, and
/// against the preview's renderer.
final class VideoFramingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-framing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let size = CGSize(width: 640, height: 360)

    private func duration(_ url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    // MARK: Title cards

    func testIntroAndOutroCardsExtendTheVideoAndShowTheBackground() async throws {
        let source = directory.appendingPathComponent("white.mp4")
        try await VideoInspection.writeColorVideo(to: source, size: size, colors: [(.white, 2)])
        var project = VideoInspection.project(for: source, seconds: 2, size: size)
        project.background = .color(VideoRGBA(0.1, 0.2, 0.8))
        project.cards.intro = VideoTitleCard(enabled: true, title: "Welcome", subtitle: "A short tour", duration: 1.5)
        project.cards.outro = VideoTitleCard(enabled: true, title: "Thanks", subtitle: "", duration: 1)
        XCTAssertEqual(project.timelineLeadIn, 1.5)
        XCTAssertEqual(project.timelineDuration(totalDuration: 2), 4.5, accuracy: 0.001)
        XCTAssertEqual(project.timelineSegments(totalDuration: 2).first?.timelineStart ?? 0, 1.5, accuracy: 0.001)

        let output = directory.appendingPathComponent("cards.mp4")
        try await VideoDemoExporter.export(project: project, destinationURL: output, settings: VideoInspection.mp4Settings())
        let length = try await duration(output)
        XCTAssertEqual(length, 4.5, accuracy: 0.1)

        // Intro: the dimmed background, not the white recording.
        let intro = try VideoInspection.frame(of: output, at: 0.6)
        let introColor = VideoInspection.color(of: intro, x: 0.5, y: 0.88)
        XCTAssertLessThan(introColor.r, 0.3, "intro shows the background: \(introColor)")
        XCTAssertGreaterThan(introColor.b, 0.45, "intro shows the background: \(introColor)")
        // The video itself in the middle.
        let video = try VideoInspection.frame(of: output, at: 2.5)
        let videoColor = VideoInspection.color(of: video, x: 0.5, y: 0.88)
        XCTAssertGreaterThan(videoColor.r, 0.85, "the recording plays after the intro: \(videoColor)")
        // Outro at the end.
        let outro = try VideoInspection.frame(of: output, at: 4.3)
        let outroColor = VideoInspection.color(of: outro, x: 0.5, y: 0.88)
        XCTAssertGreaterThan(outroColor.b, 0.45, "outro shows the background: \(outroColor)")
        XCTAssertLessThan(outroColor.r, 0.3)

        // The title is drawn (text pixels differ from the plain background).
        let plan = VideoDemoExporter.makePlan(project: project, sourceDuration: 2, recording: nil)
        let renderer = VideoFrameRenderer()
        let card = renderer.render(source: nil, timelineTime: 1.0, plan: plan, outputSize: size)
        let snapshot = directory.appendingPathComponent("card.png")
        try VideoTestSupport.writePNG(card, size: size, to: snapshot)
        let persistent = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-ux", isDirectory: true)
        try? FileManager.default.createDirectory(at: persistent, withIntermediateDirectories: true)
        try? VideoTestSupport.writePNG(card, size: size, to: persistent.appendingPathComponent("70-intro-card.png"))
        print("SNAPSHOT: \(persistent.appendingPathComponent("70-intro-card.png").path)")
        XCTAssertNotNil(plan.card(at: 1.0))
        XCTAssertNil(plan.card(at: 2.5))
    }

    /// After a clip is moved, things timed across the cut show only where
    /// their own clips play — not over the clips now between them.
    func testItemsInMovedClipsShowOnlyWhereTheirClipsPlay() throws {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/moved-clips.mp4"), duration: 4, sourceSize: CGSize(width: 1280, height: 720))
        let a = VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 2)
        let b = VideoDemoTimelineClip(sourceStart: 2, sourceEnd: 4)
        project.timelineClips = [a, b]
        // Everything spans the cut at 2 s (source 1.5–2.5).
        project.overlayEffects = [VideoDemoOverlayEffect(kind: .highlight, time: 1.5, duration: 1)]
        project.captions = [VideoCaptionLine(start: 1.5, end: 2.5, text: "Across the cut")]
        project.cameraLayouts = [VideoCameraLayoutRegion(start: 1.5, end: 2.5, layout: .fullscreen)]
        project.keystrokes = [VideoKeystrokeEvent(time: 3.0, keys: ["⌘", "S"]), VideoKeystrokeEvent(time: 0.5, keys: ["⌘", "Z"])]
        // B first: B plays 0–2 (source 2–4), A plays 2–4 (source 0–2).
        XCTAssertTrue(project.moveClip(id: b.id, toIndex: 0, totalDuration: 4))
        let plan = VideoDemoExporter.makePlan(project: project, sourceDuration: 4, recording: nil, hasWebcam: true)

        let overlay = try XCTUnwrap(plan.overlays.first)
        XCTAssertTrue(overlay.isShowing(at: 0.25), "in B's part")
        XCTAssertTrue(overlay.isShowing(at: 3.75), "in A's part")
        XCTAssertFalse(overlay.isShowing(at: 2.0), "not over A's start, which it never covered")
        XCTAssertNotNil(plan.caption(at: 0.25))
        XCTAssertNotNil(plan.caption(at: 3.75))
        XCTAssertNil(plan.caption(at: 2.0))
        XCTAssertNotNil(plan.cameraLayout(at: 0.25))
        XCTAssertNil(plan.cameraLayout(at: 2.0))
        // Shortcuts in the order they play.
        XCTAssertEqual(plan.keystrokes.map(\.start), [1.0, 2.5])

        // The subtitles have a cue for each part, in order.
        let srt = VideoCaptionBuilder.srt(lines: project.captions, segments: project.timelineSegments(totalDuration: 4))
        XCTAssertTrue(srt.contains("1\n00:00:00,000 --> 00:00:00,500\nAcross the cut"), srt)
        XCTAssertTrue(srt.contains("2\n00:00:03,500 --> 00:00:04,000\nAcross the cut"), srt)
        let vtt = VideoCaptionBuilder.vtt(lines: project.captions, segments: project.timelineSegments(totalDuration: 4))
        XCTAssertEqual(vtt.components(separatedBy: "Across the cut").count - 1, 2, vtt)

        // Drawn: the highlight's dark ring isn't in the frame at 2 s.
        let size = CGSize(width: 640, height: 360)
        let white = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size))
        let renderer = VideoFrameRenderer()
        let over = renderer.render(source: white, timelineTime: 0.25, plan: plan, outputSize: size)
        let clear = renderer.render(source: white, timelineTime: 2.0, plan: plan, outputSize: size)
        let reference = renderer.render(source: white, timelineTime: 2.0, plan: VideoDemoExporter.makePlan(project: { var p = project; p.overlayEffects = []; p.captions = []; return p }(), sourceDuration: 4, recording: nil, hasWebcam: true), outputSize: size)
        func sample(_ image: CIImage) -> (r: Double, g: Double, b: Double) { VideoInspection.color(of: image, size: size, x: 0.5, y: 0.5) }
        XCTAssertFalse(VideoInspection.isClose(sample(over), sample(clear), tolerance: 0.02), "the highlight shows in B's part")
        XCTAssertTrue(VideoInspection.isClose(sample(clear), sample(reference), tolerance: 0.02), "and nothing at 2 s")
    }

    func testCardsDecodeFromOldDraftsAndRoundTrip() throws {
        let url = URL(fileURLWithPath: "/tmp/cards.mp4")
        var project = VideoDemoProject.make(sourceURL: url, duration: 5, sourceSize: CGSize(width: 1280, height: 720))
        project.cards.intro = VideoTitleCard(enabled: true, title: "Title", subtitle: "Sub", duration: 2.5)
        project.cards.outro = VideoTitleCard(enabled: true, title: "Bye", subtitle: "shotnix.com", duration: 4)
        let decoded = try JSONDecoder().decode(VideoDemoProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.cards, project.cards)

        // A draft from before cards existed opens with none.
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        for key in ["cards", "music", "clickSounds", "transitions", "captionTracks", "sources", "imageOverlayEffects"] {
            object.removeValue(forKey: key)
        }
        let old = try JSONDecoder().decode(VideoDemoProject.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.cards, VideoTitleCards())
        XCTAssertNil(old.music)
        XCTAssertEqual(old.transitions, VideoTransitionSettings())
        XCTAssertEqual(old.clickSounds, VideoClickSoundSettings())
        XCTAssertTrue(old.sources.isEmpty)
        XCTAssertEqual(old.timelineLeadIn, 0)
    }

    // MARK: Image annotations

    func testImageAnnotationRendersIdenticallyInPreviewAndExport() async throws {
        let source = directory.appendingPathComponent("white.mp4")
        try await VideoInspection.writeColorVideo(to: source, size: size, colors: [(.white, 2)])
        let logo = directory.appendingPathComponent("logo.png")
        try VideoInspection.writePNG(to: logo, size: CGSize(width: 200, height: 100), color: NSColor(srgbRed: 0, green: 0.2, blue: 1, alpha: 1))
        let stored = try VideoAssetStore.importFile(logo)
        XCTAssertTrue(VideoAssetStore.isStored(stored.path), "the picture is copied into Shotnix's folder")
        // Moving the original away doesn't matter any more.
        try FileManager.default.removeItem(at: logo)

        var project = VideoInspection.project(for: source, seconds: 2, size: size)
        var effect = VideoDemoOverlayEffect(kind: .image, time: 0, duration: 2, x: 0.8, y: 0.25, width: 0.25, height: 0.2, text: "logo")
        effect.image = VideoOverlayImage(path: stored.path, name: "logo.png", aspect: 2)
        project.overlayEffects = [effect]

        let output = directory.appendingPathComponent("image.mp4")
        try await VideoDemoExporter.export(project: project, destinationURL: output, settings: VideoInspection.mp4Settings())
        let frame = try VideoInspection.frame(of: output, at: 1.0)
        let onLogo = VideoInspection.color(of: frame, x: 0.8, y: 0.25)
        let offLogo = VideoInspection.color(of: frame, x: 0.3, y: 0.7)
        XCTAssertTrue(VideoInspection.isClose(onLogo, (0, 0.2, 1), tolerance: 0.12), "the logo shows where it was placed: \(onLogo)")
        XCTAssertTrue(VideoInspection.isClose(offLogo, (1, 1, 1), tolerance: 0.08), "the rest is the recording: \(offLogo)")

        // The preview draws the same pixels with the same renderer.
        let plan = VideoDemoExporter.makePlan(project: project, sourceDuration: 2, recording: nil)
        let still = VideoFrameRenderer().render(source: CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size)), timelineTime: 1.0, plan: plan, outputSize: CGSize(width: 1280, height: 720))
        let previewLogo = VideoInspection.color(of: still, size: CGSize(width: 1280, height: 720), x: 0.8, y: 0.25)
        XCTAssertTrue(VideoInspection.isClose(previewLogo, onLogo, tolerance: 0.1), "preview \(previewLogo) matches export \(onLogo)")

        // Half opacity blends with the recording.
        project.overlayEffects[0].image?.opacity = 0.5
        let faded = VideoDemoExporter.makePlan(project: project, sourceDuration: 2, recording: nil)
        let half = VideoFrameRenderer().render(source: CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: size)), timelineTime: 1.0, plan: faded, outputSize: size)
        let blended = VideoInspection.color(of: half, size: size, x: 0.8, y: 0.25)
        // Blended in linear light: half of white is sRGB ≈ 0.735.
        XCTAssertEqual(blended.r, 0.735, accuracy: 0.06, "half opacity: \(blended)")
        XCTAssertGreaterThan(blended.b, 0.9)
    }

    func testImageAnnotationsSurviveDraftsAndStayOutOfOlderReaders() throws {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/img.mp4"), duration: 5, sourceSize: CGSize(width: 1280, height: 720))
        var image = VideoDemoOverlayEffect(kind: .image, time: 1, duration: 2, x: 0.8, y: 0.2, width: 0.2, height: 0.1, text: "logo")
        image.image = VideoOverlayImage(path: "/tmp/stored.png", name: "logo.png", aspect: 2, opacity: 0.7)
        let arrow = VideoDemoOverlayEffect(kind: .arrow, time: 0.5, duration: 1)
        project.overlayEffects = VideoDemoProject.normalizedEffectLayers([image, arrow])
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(VideoDemoProject.self, from: data)
        XCTAssertEqual(decoded.overlayEffects, project.overlayEffects)
        // Older versions only read "overlayEffects": no picture in there.
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let plain = object["overlayEffects"] as! [[String: Any]]
        XCTAssertEqual(plain.count, 1)
        XCTAssertEqual(plain.first?["kind"] as? String, "arrow")
        XCTAssertEqual((object["imageOverlayEffects"] as? [[String: Any]])?.count, 1)
    }

    func testImagePlacementCornersKeepAMargin() {
        let canvas = CGSize(width: 1920, height: 1080)
        let topRight = VideoImagePlacement.topRight.center(width: 0.2, aspect: 2, canvas: canvas)
        // 20% of 1920 = 384 wide, 192 tall; margin 43.2.
        XCTAssertEqual(Double(topRight.x), 1 - (43.2 + 192) / 1920, accuracy: 0.001)
        XCTAssertEqual(Double(topRight.y), (43.2 + 96) / 1080, accuracy: 0.001)
        var effect = VideoDemoOverlayEffect(kind: .image, time: 0, x: Double(topRight.x), y: Double(topRight.y), width: 0.2)
        effect.image = VideoOverlayImage(path: "/tmp/x.png", name: "x", aspect: 2)
        let rect = effect.imageRect(in: canvas)
        XCTAssertEqual(rect.maxX, 1920 - 43.2, accuracy: 0.5)
        XCTAssertEqual(rect.maxY, 1080 - 43.2, accuracy: 0.5)
        XCTAssertEqual(rect.width / rect.height, 2, accuracy: 0.001)
    }

    // MARK: Transitions

    private func redThenGreen() async throws -> (URL, VideoDemoProject) {
        let source = directory.appendingPathComponent("red-green.mp4")
        try await VideoInspection.writeColorVideo(to: source, size: size, colors: [(.red, 1.5), (NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), 1.5)])
        var project = VideoInspection.project(for: source, seconds: 3, size: size)
        project.timelineClips = [
            VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 1),
            VideoDemoTimelineClip(sourceStart: 2, sourceEnd: 3),
        ]
        return (source, project)
    }

    func testDissolveBlendsTheTwoClipsAtTheCut() async throws {
        var (_, project) = try await redThenGreen()
        project.transitions.betweenClips = .dissolve
        project.transitions.duration = 0.8
        let segments = project.timelineSegments(totalDuration: 3)
        let spans = VideoTransitionTiming.spans(settings: project.transitions, segments: segments)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].time, 1, accuracy: 0.001)
        XCTAssertEqual(spans[0].start, 0.6, accuracy: 0.001)
        XCTAssertEqual(spans[0].incomingSource, 2, accuracy: 0.001)

        let output = directory.appendingPathComponent("dissolve.mp4")
        try await VideoDemoExporter.export(project: project, destinationURL: output, settings: VideoInspection.mp4Settings())
        let length = try await duration(output)
        XCTAssertEqual(length, 2, accuracy: 0.1, "a dissolve doesn't change the length")
        let before = VideoInspection.color(of: try VideoInspection.frame(of: output, at: 0.3), x: 0.5, y: 0.5)
        let middle = VideoInspection.color(of: try VideoInspection.frame(of: output, at: 1.0), x: 0.5, y: 0.5)
        let after = VideoInspection.color(of: try VideoInspection.frame(of: output, at: 1.7), x: 0.5, y: 0.5)
        XCTAssertTrue(VideoInspection.isClose(before, (1, 0, 0), tolerance: 0.12), "red before: \(before)")
        XCTAssertTrue(VideoInspection.isClose(after, (0, 1, 0), tolerance: 0.12), "green after: \(after)")
        XCTAssertGreaterThan(middle.r, 0.25, "both clips show mid-dissolve: \(middle)")
        XCTAssertGreaterThan(middle.g, 0.25, "both clips show mid-dissolve: \(middle)")
    }

    func testDipToBlackAndFadesFromAndToBlack() async throws {
        var (_, project) = try await redThenGreen()
        project.transitions.betweenClips = .fadeThroughBlack
        project.transitions.duration = 0.8
        project.transitions.fadeIn = 0.5
        project.transitions.fadeOut = 0.5
        let output = directory.appendingPathComponent("dip.mp4")
        try await VideoDemoExporter.export(project: project, destinationURL: output, settings: VideoInspection.mp4Settings())
        let start = VideoInspection.color(of: try VideoInspection.frame(of: output, at: 0.0), x: 0.5, y: 0.5)
        let cut = VideoInspection.color(of: try VideoInspection.frame(of: output, at: 1.0), x: 0.5, y: 0.5)
        let clear = VideoInspection.color(of: try VideoInspection.frame(of: output, at: 1.6), x: 0.5, y: 0.5)
        let end = VideoInspection.color(of: try VideoInspection.frame(of: output, at: 1.98), x: 0.5, y: 0.5)
        XCTAssertLessThan(start.r + start.g, 0.15, "starts from black: \(start)")
        XCTAssertLessThan(cut.r + cut.g, 0.15, "black on the cut: \(cut)")
        XCTAssertTrue(VideoInspection.isClose(clear, (0, 1, 0), tolerance: 0.12), "clear between: \(clear)")
        XCTAssertLessThan(end.r + end.g, 0.35, "fades out to black: \(end)")
        XCTAssertEqual(VideoTransitionTiming.edgeFade(time: 1.0, duration: 2, fadeIn: 0.5, fadeOut: 0.5), 0, accuracy: 0.0001)
        XCTAssertEqual(VideoTransitionTiming.edgeFade(time: 0, duration: 2, fadeIn: 0.5, fadeOut: 0.5), 1, accuracy: 0.0001)
    }

    func testTransitionsFitShortClipsAndPerCutChoicesWin() {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/t.mp4"), duration: 10, sourceSize: CGSize(width: 1280, height: 720))
        let a = VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 4)
        let b = VideoDemoTimelineClip(sourceStart: 5, sourceEnd: 5.4)
        let c = VideoDemoTimelineClip(sourceStart: 6, sourceEnd: 10)
        project.timelineClips = [a, b, c]
        project.transitions.betweenClips = .dissolve
        project.transitions.duration = 1.5
        project.transitions.overrides = [VideoClipTransition(clipID: c.id, kind: .fadeThroughBlack, duration: 1)]
        let spans = VideoTransitionTiming.spans(settings: project.transitions, segments: project.timelineSegments(totalDuration: 10))
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].duration, 0.4, accuracy: 0.001, "never longer than the shorter clip")
        XCTAssertEqual(spans[1].kind, .fadeThroughBlack)
        XCTAssertEqual(spans[1].duration, 0.4, accuracy: 0.001)
        let decoded = try? JSONDecoder().decode(VideoDemoProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded?.transitions, project.transitions)
    }

    // MARK: Music

    func testMusicLoopsFadesAndPlaysOnTheOutputTimeline() async throws {
        let source = directory.appendingPathComponent("silent.mp4")
        try await VideoInspection.writeColorVideo(to: source, size: size, colors: [(.gray, 4)])
        let song = directory.appendingPathComponent("song.m4a")
        try VideoInspection.writeTone(to: song, frequency: 880, seconds: 1.5)
        let stored = try VideoAssetStore.importFile(song)
        var project = VideoInspection.project(for: source, seconds: 4, size: size)
        // Cut and speed up: the music still runs straight along the timeline.
        project.timelineClips = [VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 1), VideoDemoTimelineClip(sourceStart: 2, sourceEnd: 4, speed: 2)]
        var music = VideoMusicTrack(path: stored.path, name: "song.m4a", duration: 1.5)
        music.volume = 1
        music.fadeIn = 0
        music.fadeOut = 0
        music.ducking = false
        project.music = music

        let output = directory.appendingPathComponent("music.mp4")
        try await VideoDemoExporter.export(project: project, destinationURL: output, settings: VideoInspection.mp4Settings())
        let length = try await duration(output)
        XCTAssertEqual(length, 2, accuracy: 0.1)
        let samples = try VideoInspection.audio(of: output)
        XCTAssertFalse(samples.isEmpty, "a silent recording with music still gets sound")
        let first = VideoInspection.toneLevel(samples, frequency: 880, from: 0.2, to: 1.2)
        let looped = VideoInspection.toneLevel(samples, frequency: 880, from: 1.6, to: 1.95)
        XCTAssertGreaterThan(first, 0.2, "the song plays: \(first)")
        XCTAssertGreaterThan(looped, 0.2, "and loops to fill: \(looped)")

        // Without looping it ends with the song.
        project.music?.loops = false
        let once = directory.appendingPathComponent("once.mp4")
        try await VideoDemoExporter.export(project: project, destinationURL: once, settings: VideoInspection.mp4Settings())
        let onceSamples = try VideoInspection.audio(of: once)
        XCTAssertLessThan(VideoInspection.toneLevel(onceSamples, frequency: 880, from: 1.65, to: 1.95), 0.02, "no loop: silence after the song")
    }

    func testMusicCoversTheCardsAndTheEndCardAndFadesAtTheVeryEnd() async throws {
        let source = directory.appendingPathComponent("short.mp4")
        try await VideoInspection.writeColorVideo(to: source, size: size, colors: [(.gray, 3)])
        let song = directory.appendingPathComponent("long-song.m4a")
        try VideoInspection.writeTone(to: song, frequency: 330, seconds: 14, amplitude: 0.4)
        let stored = try VideoAssetStore.importFile(song)
        var project = VideoInspection.project(for: source, seconds: 3, size: size)
        project.cards.intro = VideoTitleCard(enabled: true, title: "Intro", duration: 2)
        project.cards.outro = VideoTitleCard(enabled: true, title: "Outro", duration: 2)
        var music = VideoMusicTrack(path: stored.path, name: "long-song.m4a", duration: 14)
        music.volume = 0.8
        music.fadeIn = 0.5
        music.fadeOut = 2.5
        music.ducking = false
        project.music = music
        var settings = VideoInspection.mp4Settings()
        settings.endCard = true

        // Intro 0–2, clips 2–5, outro 5–7, then the 2-second end card.
        let output = directory.appendingPathComponent("with-end-card.mp4")
        try await VideoDemoExporter.export(project: project, destinationURL: output, settings: settings)
        let length = try await duration(output)
        XCTAssertEqual(length, 9, accuracy: 0.15)
        let samples = try VideoInspection.audio(of: output)
        func level(_ from: Double, _ to: Double) -> Double {
            VideoInspection.toneLevel(samples, frequency: 330, from: from, to: to)
        }
        XCTAssertGreaterThan(level(0.8, 1.2), 0.15, "music under the intro card")
        XCTAssertGreaterThan(level(5.8, 6.2), 0.15, "and the outro card")
        XCTAssertGreaterThan(level(6.75, 6.95), 0.12, "no fade-out where the timeline ends: \(level(6.75, 6.95))")
        let underEndCard = level(7.3, 7.7)
        XCTAssertGreaterThan(underEndCard, 0.07, "the music plays on under the end card: \(underEndCard)")
        XCTAssertLessThan(level(8.8, 8.95), underEndCard * 0.35, "and fades out at the very end")
    }

    func testMusicDucksUnderTheVoice() async throws {
        // A "voice" (440 Hz) for the first 1.5 s, then quiet.
        let source = directory.appendingPathComponent("voice.mp4")
        try await VideoInspection.writeColorVideo(to: source, size: size, colors: [(.gray, 3.5)], toneSeconds: 1.5, toneFrequency: 440)
        let song = directory.appendingPathComponent("song.m4a")
        try VideoInspection.writeTone(to: song, frequency: 1760, seconds: 4, amplitude: 0.3)
        let stored = try VideoAssetStore.importFile(song)
        var project = VideoInspection.project(for: source, seconds: 3.5, size: size)
        var music = VideoMusicTrack(path: stored.path, name: "song.m4a", duration: 4)
        music.volume = 1
        music.fadeIn = 0
        music.fadeOut = 0
        music.ducking = true
        music.duckLevel = 0.2
        project.music = music

        let speech = await VideoVoiceActivity.speech(url: source, trackIndex: 0)
        XCTAssertEqual(speech.count, 1, "one stretch of talking: \(speech)")
        XCTAssertEqual(speech.first?.lowerBound ?? 9, 0, accuracy: 0.1)
        XCTAssertEqual(speech.first?.upperBound ?? 0, 1.5, accuracy: 0.15)

        let output = directory.appendingPathComponent("ducked.mp4")
        try await VideoDemoExporter.export(project: project, destinationURL: output, settings: VideoInspection.mp4Settings())
        let samples = try VideoInspection.audio(of: output)
        let underVoice = VideoInspection.toneLevel(samples, frequency: 1760, from: 0.4, to: 1.2)
        let alone = VideoInspection.toneLevel(samples, frequency: 1760, from: 2.6, to: 3.3)
        XCTAssertGreaterThan(alone, 0.15, "full level after the voice: \(alone)")
        XCTAssertLessThan(underVoice, alone * 0.45, "lower under the voice: \(underVoice) vs \(alone)")
    }

    func testMusicEnvelopeMath() {
        var music = VideoMusicTrack(path: "/tmp/song.m4a", name: "song", duration: 30)
        music.volume = 0.8
        music.fadeIn = 2
        music.fadeOut = 2
        music.duckLevel = 0.25
        let voice = [4.0...6.0]
        let keys = VideoMusicMix.envelope(music: music, duration: 20, voice: voice)
        func level(_ t: Double) -> Double {
            guard let after = keys.firstIndex(where: { $0.time >= t }) else { return keys.last?.volume ?? 0 }
            guard after > 0 else { return keys[0].volume }
            let a = keys[after - 1], b = keys[after]
            return a.volume + (b.volume - a.volume) * (t - a.time) / max(b.time - a.time, 0.0001)
        }
        XCTAssertEqual(level(0), 0, accuracy: 0.001)
        XCTAssertEqual(level(1), 0.4, accuracy: 0.02, "halfway through the fade-in")
        XCTAssertEqual(level(3), 0.8, accuracy: 0.001)
        XCTAssertEqual(level(5), 0.2, accuracy: 0.001, "ducked to 25%")
        XCTAssertEqual(level(10), 0.8, accuracy: 0.001, "back up after the voice")
        XCTAssertEqual(level(19), 0.4, accuracy: 0.02, "fading out")
        XCTAssertEqual(level(20), 0, accuracy: 0.001)
        // Speech close together ducks as one stretch.
        XCTAssertEqual(VideoMusicMix.mergedVoice([1...2, 2.5...3, 8...9]).count, 2)

        // Loops lay pieces back to back; a range export starts mid-song.
        let pieces = VideoMusicLayout.pieces(music: VideoMusicTrack(path: "/x", name: "x", duration: 10), timelineDuration: 25)
        XCTAssertEqual(pieces.map(\.start), [0, 10, 20])
        var offset = VideoMusicTrack(path: "/x", name: "x", duration: 10)
        offset.startOffset = 2
        let shifted = VideoMusicLayout.pieces(music: offset, timelineDuration: 12, timelineOffset: 3)
        XCTAssertEqual(shifted.first?.fileStart ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(shifted.first?.length ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(shifted.dropFirst().first?.fileStart ?? 0, 2, accuracy: 0.001, "loops from the start offset")
    }

    func testMusicAndClickSettingsRoundTripInDrafts() throws {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/m.mp4"), duration: 5, sourceSize: CGSize(width: 1280, height: 720))
        var music = VideoMusicTrack(path: "/tmp/song.m4a", name: "Song.m4a", duration: 120)
        music.volume = 0.42
        music.startOffset = 7
        music.loops = false
        music.duckLevel = 0.15
        project.music = music
        project.clickSounds = VideoClickSoundSettings(enabled: true, volume: 0.33)
        let decoded = try JSONDecoder().decode(VideoDemoProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.music, music)
        XCTAssertEqual(decoded.clickSounds, project.clickSounds)
    }

    // MARK: Click sounds

    func testClickSoundsLandOnTheClicks() async throws {
        let source = directory.appendingPathComponent("silent.mp4")
        try await VideoInspection.writeColorVideo(to: source, size: size, colors: [(.gray, 3)])
        var project = VideoInspection.project(for: source, seconds: 3, size: size)
        project.clickEvents = [
            VideoDemoClickEvent(time: 0.5, x: 0.5, y: 0.5, button: .left, endTime: 0.6),
            VideoDemoClickEvent(time: 2.0, x: 0.4, y: 0.4, button: .left, endTime: 2.1),
        ]
        project.clickSounds = VideoClickSoundSettings(enabled: true, volume: 1)
        let samples = VideoClickSound.samples()
        XCTAssertEqual(Double(samples.count) / VideoClickSound.sampleRate, VideoClickSound.length, accuracy: 0.001)
        XCTAssertEqual(Double(samples.map { abs($0) }.max() ?? 0), 0.5, accuracy: 0.01)

        let output = directory.appendingPathComponent("clicks.mp4")
        try await VideoDemoExporter.export(project: project, destinationURL: output, settings: VideoInspection.mp4Settings())
        let audio = try VideoInspection.audio(of: output)
        let atClick = VideoInspection.rms(audio, from: 0.49, to: 0.54)
        let quiet = VideoInspection.rms(audio, from: 1.0, to: 1.8)
        let second = VideoInspection.rms(audio, from: 1.99, to: 2.04)
        XCTAssertGreaterThan(atClick, 0.05, "a click at 0.5 s: \(atClick)")
        XCTAssertGreaterThan(second, 0.05, "and at 2 s: \(second)")
        XCTAssertLessThan(quiet, 0.005, "silence between: \(quiet)")

        // A cut click stays silent.
        project.timelineClips = [VideoDemoTimelineClip(sourceStart: 1, sourceEnd: 3)]
        XCTAssertEqual(VideoClickSound.times(project: project, segments: project.timelineSegments(totalDuration: 3)), [1.0])
    }
}
