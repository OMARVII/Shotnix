import AppKit
import CoreImage
import Translation
import XCTest
@testable import ShotnixCore

/// Caption looks, WebVTT, and translated caption tracks.
final class VideoCaptionStyleTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private func project() -> VideoDemoProject {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/styles.mp4"), duration: 10, sourceSize: CGSize(width: 1920, height: 1080))
        project.cursor.visible = false
        let words = [
            VideoCaptionWord(text: "Open", start: 1.0, end: 1.3),
            VideoCaptionWord(text: "the", start: 1.3, end: 1.45),
            VideoCaptionWord(text: "settings", start: 1.45, end: 1.9),
            VideoCaptionWord(text: "panel", start: 1.9, end: 2.3),
        ]
        project.captions = [
            VideoCaptionLine(start: 1.0, end: 2.6, text: "Open the settings panel", words: words),
            VideoCaptionLine(start: 3.0, end: 4.0, text: "Then save <it> & go"),
        ]
        return project
    }

    // MARK: Looks

    func testEveryLookDrawsDifferentlyAndTheHighlightUsesItsColor() throws {
        let screen = CIImage(cgImage: VideoTestSupport.fakeScreen(size: CGSize(width: 2880, height: 1800), progress: 0.4, typed: "Hello"))
        let size = CGSize(width: 1920, height: 1080)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-ux", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var bands: [VideoCaptionPreset: (r: Double, g: Double, b: Double)] = [:]
        for preset in VideoCaptionPreset.allCases {
            var styled = project()
            styled.captionStyle.preset = preset
            let plan = VideoDemoExporter.makePlan(project: styled, sourceDuration: 10, recording: nil)
            let image = VideoFrameRenderer().render(source: screen, timelineTime: 1.6, plan: plan, outputSize: size)
            let url = out.appendingPathComponent("75-caption-\(preset.rawValue).png")
            try VideoTestSupport.writePNG(image, size: size, to: url)
            print("SNAPSHOT: \(url.path)")
            bands[preset] = VideoInspection.color(of: image, size: size, x: 0.5, y: 0.9)
        }
        func differs(_ a: VideoCaptionPreset, _ b: VideoCaptionPreset) -> Bool {
            guard let x = bands[a], let y = bands[b] else { return false }
            return abs(x.r - y.r) + abs(x.g - y.g) + abs(x.b - y.b) > 0.01
        }
        XCTAssertTrue(differs(.classic, .minimal), "the pill vs no backdrop")
        XCTAssertTrue(differs(.classic, .outline))

        // The spoken word's tag (Highlight) is drawn in the chosen color.
        var style = VideoCaptionStyle()
        style.preset = .highlight
        style.highlightColor = VideoRGBA(0, 1, 0)
        let words = ["Captions", "look", "like", "this"]
        let tagged = try XCTUnwrap(VideoCaptionDrawing.image(text: words.joined(separator: " "), words: words, spoken: 1, style: style, fontSize: 60, maxWidth: 1200))
        XCTAssertTrue(containsColor(tagged, VideoRGBA(0, 1, 0)), "a green tag behind the spoken word")
        // Outline: a yellow spoken word by default.
        style.preset = .outline
        style.highlightColor = nil
        let outlined = try XCTUnwrap(VideoCaptionDrawing.image(text: words.joined(separator: " "), words: words, spoken: 2, style: style, fontSize: 60, maxWidth: 1200))
        XCTAssertTrue(containsColor(outlined, VideoCaptionPreset.outline.defaultHighlight), "the spoken word in yellow")
        XCTAssertTrue(containsColor(outlined, VideoRGBA(0, 0, 0)), "with a black outline")
        // Classic without word timings is all white on the pill.
        style.preset = .classic
        let plain = try XCTUnwrap(VideoCaptionDrawing.image(text: "No timings", words: [], spoken: nil, style: style, fontSize: 60, maxWidth: 1200))
        XCTAssertFalse(containsColor(plain, VideoRGBA(1, 0.84, 0.04)))
    }

    private func containsColor(_ image: CGImage, _ color: VideoRGBA, tolerance: Double = 0.1) -> Bool {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 250 {
            let r = Double(pixels[index]) / 255, g = Double(pixels[index + 1]) / 255, b = Double(pixels[index + 2]) / 255
            if abs(r - color.r) < tolerance, abs(g - color.g) < tolerance, abs(b - color.b) < tolerance { return true }
        }
        return false
    }

    func testCaptionLookSurvivesDraftsAndTheSavedLook() throws {
        var project = project()
        project.captionStyle.preset = .highlight
        project.captionStyle.highlightColor = VideoRGBA(hex: 0x30D158)
        project.captionStyle.size = .large
        project.captionStyle.position = .top
        let decoded = try JSONDecoder().decode(VideoDemoProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.captionStyle, project.captionStyle)
        let look = try JSONDecoder().decode(VideoStylePreset.self, from: JSONEncoder().encode(project.style))
        XCTAssertEqual(look.captionStyle.preset, .highlight)
        // Styles saved before looks existed are Classic.
        let old = try JSONDecoder().decode(VideoCaptionStyle.self, from: Data(#"{"visible":true,"size":"small","position":"bottom","highlightWords":false}"#.utf8))
        XCTAssertEqual(old.preset, .classic)
        XCTAssertNil(old.highlightColor)
        XCTAssertEqual(old.size, .small)
    }

    // MARK: WebVTT

    func testWebVTTFollowsTheEditedTimelineAndEscapes() {
        var project = project()
        // Cut 0–0.5 s: everything moves half a second earlier.
        project.timelineClips = [VideoDemoTimelineClip(sourceStart: 0.5, sourceEnd: 10)]
        let segments = project.timelineSegments(totalDuration: 10)
        let vtt = VideoCaptionBuilder.vtt(lines: project.captions, segments: segments)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(vtt.contains("00:00:00.500 --> 00:00:02.100\nOpen the settings panel"), vtt)
        XCTAssertTrue(vtt.contains("Then save &lt;it&gt; &amp; go"), "cue text is escaped: \(vtt)")
        XCTAssertEqual(VideoCaptionBuilder.vttTimestamp(3_725.25), "01:02:05.250")
        let srt = VideoCaptionBuilder.subtitles(.srt, project: project, segments: segments)
        XCTAssertTrue(srt.contains("00:00:00,500 --> 00:00:02,100"), srt)
    }

    // MARK: Translation

    func testTranslatedTrackShowsAndExportsInsteadOfTheOriginal() throws {
        var project = project()
        let first = project.captions[0], second = project.captions[1]
        project.captionTracks.translations = [VideoCaptionTranslation(language: "es", lines: [
            .init(id: first.id, text: "Abre el panel de ajustes", sourceText: first.text),
            .init(id: second.id, text: "Luego guarda y listo", sourceText: second.text),
        ])]
        project.captionTracks.active = "es"
        let plan = VideoDemoExporter.makePlan(project: project, sourceDuration: 10, recording: nil)
        XCTAssertEqual(plan.caption(at: 1.5)?.text, "Abre el panel de ajustes")
        XCTAssertTrue(plan.caption(at: 1.5)?.words.isEmpty ?? false, "no word highlighting on a translation")
        let segments = project.timelineSegments(totalDuration: 10)
        let vtt = VideoCaptionBuilder.subtitles(.vtt, project: project, segments: segments)
        XCTAssertTrue(vtt.contains("Abre el panel de ajustes"))
        XCTAssertFalse(vtt.contains("Open the settings"))

        // Editing a line after translating marks it stale.
        project.captions[1].text = "Then save it"
        XCTAssertEqual(project.captionTracks.translations[0].staleCount(for: project.captions), 1)

        // Back to the original track.
        project.captionTracks.active = nil
        XCTAssertEqual(VideoDemoExporter.makePlan(project: project, sourceDuration: 10, recording: nil).caption(at: 1.5)?.text, "Open the settings panel")

        let decoded = try JSONDecoder().decode(VideoDemoProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.captionTracks, project.captionTracks)
    }

    @MainActor
    func testSubtitleFileNamesCarryTheLanguage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Demo.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 320, height: 200), seconds: 1, fps: 30)
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        XCTAssertEqual(model.subtitleFileName(.srt), "Demo.srt")
        model.mutate { $0.captionTracks.active = "de" }
        XCTAssertEqual(model.subtitleFileName(.vtt), "Demo.de.vtt")
        model.stop()
        VideoDemoDraftStore.delete(for: url)
    }

    /// The real on-device translator (macOS 26 can open a session without
    /// the UI when the languages are installed; skipped otherwise).
    func testOnDeviceTranslationWhenLanguagesAreInstalled() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Needs macOS 26 for a session without the UI") }
        let readiness = await VideoCaptionTranslator.readiness(from: "en", to: "es")
        guard readiness == .installed else { throw XCTSkip("English → Spanish isn't installed on this Mac (\(readiness))") }
        let session = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "es"))
        let lines = [VideoCaptionLine(start: 0, end: 1, text: "Good morning"), VideoCaptionLine(start: 1, end: 2, text: "   ")]
        let translation = try await VideoCaptionTranslator.translate(lines, into: "es", session: session)
        XCTAssertEqual(translation.lines.count, 1, "empty lines are skipped")
        XCTAssertEqual(translation.lines.first?.id, lines[0].id)
        XCTAssertFalse(translation.lines.first?.text.isEmpty ?? true)
        XCTAssertNotEqual(translation.lines.first?.text, "Good morning")
    }
}
