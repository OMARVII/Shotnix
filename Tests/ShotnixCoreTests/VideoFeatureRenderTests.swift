import AppKit
import CoreImage
import XCTest
@testable import ShotnixCore

/// Crop, keyboard shortcuts, and captions through the real renderer.
final class VideoFeatureRenderTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private func snapshotDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-render-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func project(duration: Double = 10) -> VideoDemoProject {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/features.mp4"), duration: duration, sourceSize: CGSize(width: 2880, height: 1800))
        let (samples, clicks) = VideoTestSupport.scriptedPointer(duration: duration)
        project.cursorSamples = samples
        project.clickEvents = clicks
        project.nativeCursorVisible = false
        return project
    }

    private func averageColor(_ image: CIImage, in rect: CGRect) -> (r: Double, g: Double, b: Double, a: Double) {
        let context = VideoRenderContext.makeContext()
        var pixel = [UInt8](repeating: 0, count: 4)
        let average = image.cropped(to: rect).applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255, Double(pixel[3]) / 255)
    }

    // MARK: Keyboard shortcuts

    func testFormatterKeepsShortcutsAndDropsTyping() {
        XCTAssertEqual(VideoKeystrokeFormatter.keys(keyCode: 1, characters: "s", modifiers: [.command]), ["⌘", "S"])
        XCTAssertEqual(VideoKeystrokeFormatter.keys(keyCode: 21, characters: "$", modifiers: [.command, .shift]), ["⇧", "⌘", "4"])
        XCTAssertEqual(VideoKeystrokeFormatter.keys(keyCode: 36, characters: "\r", modifiers: [.command]), ["⌘", "↩"])
        XCTAssertEqual(VideoKeystrokeFormatter.keys(keyCode: 53, characters: "\u{1b}", modifiers: []), ["esc"])
        XCTAssertEqual(VideoKeystrokeFormatter.keys(keyCode: 122, characters: nil, modifiers: []), ["F1"])
        XCTAssertEqual(VideoKeystrokeFormatter.keys(keyCode: 0, characters: "a", modifiers: [.control, .option]), ["⌃", "⌥", "A"])
        // Plain typing never records — letters, shifted letters, Return, arrows.
        XCTAssertNil(VideoKeystrokeFormatter.keys(keyCode: 0, characters: "a", modifiers: []))
        XCTAssertNil(VideoKeystrokeFormatter.keys(keyCode: 0, characters: "A", modifiers: [.shift]))
        XCTAssertNil(VideoKeystrokeFormatter.keys(keyCode: 36, characters: "\r", modifiers: []))
        XCTAssertNil(VideoKeystrokeFormatter.keys(keyCode: 123, characters: nil, modifiers: []))
        XCTAssertNil(VideoKeystrokeFormatter.keys(keyCode: 51, characters: nil, modifiers: [.shift]))
    }

    func testRepeatedShortcutsStackAndNewOnesReplace() {
        var project = self.project()
        project.keystrokes = [
            VideoKeystrokeEvent(time: 1.0, keys: ["⌘", "Z"]),
            VideoKeystrokeEvent(time: 1.4, keys: ["⌘", "Z"]),
            VideoKeystrokeEvent(time: 1.8, keys: ["⌘", "Z"]),
            VideoKeystrokeEvent(time: 2.2, keys: ["⌘", "S"]),
            VideoKeystrokeEvent(time: 6.0, keys: ["⌘", "S"]),
        ]
        let plan = VideoDemoExporter.makePlan(project: project, sourceDuration: 10, recording: nil)
        XCTAssertEqual(plan.keystrokes.count, 3)
        XCTAssertEqual(plan.keystrokes[0].pressCount(at: 1.9), 3)
        XCTAssertEqual(plan.keystrokes[0].end, 2.2, accuracy: 0.001, "⌘S replaces ⌘Z")
        XCTAssertEqual(plan.keystroke(at: 2.3)?.keys, ["⌘", "S"])
        XCTAssertNil(plan.keystroke(at: 4.5), "gone after the hold")
        XCTAssertEqual(plan.keystroke(at: 6.5)?.keys, ["⌘", "S"])
    }

    func testShortcutsFollowCuts() {
        var project = self.project()
        project.keystrokes = [VideoKeystrokeEvent(time: 3.0, keys: ["⌘", "C"]), VideoKeystrokeEvent(time: 7.0, keys: ["⌘", "V"])]
        // Remove 2...4 — the ⌘C press is cut away; ⌘V moves 2s earlier.
        project.timelineClips = [
            VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 2),
            VideoDemoTimelineClip(sourceStart: 4, sourceEnd: 10),
        ]
        let plan = VideoDemoExporter.makePlan(project: project, sourceDuration: 10, recording: nil)
        XCTAssertEqual(plan.keystrokes.count, 1)
        XCTAssertEqual(plan.keystrokes[0].start, 5.0, accuracy: 0.01)
    }

    func testKeycapsDrawAtTheBottomAndStayStillWhileZoomed() throws {
        var project = self.project()
        project.keystrokes = [VideoKeystrokeEvent(time: 2.0, keys: ["⇧", "⌘", "4"])]
        project.zoomRegions = [VideoZoomRegion(start: 1, end: 5, scale: 2.5, followsCursor: false)]
        let plan = VideoDemoExporter.makePlan(project: project, sourceDuration: 10, recording: nil)
        let renderer = VideoFrameRenderer()
        let screen = CIImage(cgImage: VideoTestSupport.fakeScreen(size: CGSize(width: 2880, height: 1800), progress: 0.4, typed: "Hello"))
        let size = CGSize(width: 1920, height: 1080)
        let image = renderer.render(source: screen, timelineTime: 2.5, plan: plan, outputSize: size)
        let url = try snapshotDirectory().appendingPathComponent("keycaps.png")
        try VideoTestSupport.writePNG(image, size: size, to: url)
        print("SNAPSHOT: \(url.path)")

        // Hidden style → the same frame without keycaps differs only there.
        var hidden = project
        hidden.keystrokeStyle.visible = false
        let hiddenPlan = VideoDemoExporter.makePlan(project: hidden, sourceDuration: 10, recording: nil)
        let without = renderer.render(source: screen, timelineTime: 2.5, plan: hiddenPlan, outputSize: size)
        let band = CGRect(x: 760, y: 50, width: 400, height: 110)
        let with = averageColor(image, in: band)
        let bare = averageColor(without, in: band)
        let difference = abs(with.r - bare.r) + abs(with.g - bare.g) + abs(with.b - bare.b)
        XCTAssertGreaterThan(difference, 0.05, "keycaps appear near the bottom center")
    }

    // MARK: Captions

    func testCaptionHighlightsSpokenWords() throws {
        var project = self.project()
        let words = [
            VideoCaptionWord(text: "Open", start: 1.0, end: 1.3),
            VideoCaptionWord(text: "the", start: 1.3, end: 1.45),
            VideoCaptionWord(text: "settings", start: 1.45, end: 1.9),
            VideoCaptionWord(text: "panel", start: 1.9, end: 2.3),
        ]
        project.captions = [VideoCaptionLine(start: 1.0, end: 2.6, text: "Open the settings panel", words: words)]
        project.keystrokes = [VideoKeystrokeEvent(time: 1.2, keys: ["⌘", ","])]
        let plan = VideoDemoExporter.makePlan(project: project, sourceDuration: 10, recording: nil)
        XCTAssertEqual(plan.caption(at: 1.5)?.text, "Open the settings panel")
        XCTAssertNil(plan.caption(at: 3))

        let renderer = VideoFrameRenderer()
        let screen = CIImage(cgImage: VideoTestSupport.fakeScreen(size: CGSize(width: 2880, height: 1800), progress: 0.4, typed: "Hello"))
        let size = CGSize(width: 1920, height: 1080)
        let image = renderer.render(source: screen, timelineTime: 1.6, plan: plan, outputSize: size)
        let url = try snapshotDirectory().appendingPathComponent("captions.png")
        try VideoTestSupport.writePNG(image, size: size, to: url)
        print("SNAPSHOT: \(url.path)")

        var vertical = project
        vertical.aspectPreset = .vertical
        vertical.captionStyle.size = .large
        let verticalPlan = VideoDemoExporter.makePlan(project: vertical, sourceDuration: 10, recording: nil)
        let verticalSize = CGSize(width: 1080, height: 1920)
        let verticalImage = renderer.render(source: screen, timelineTime: 1.6, plan: verticalPlan, outputSize: verticalSize)
        let verticalURL = try snapshotDirectory().appendingPathComponent("captions-vertical.png")
        try VideoTestSupport.writePNG(verticalImage, size: verticalSize, to: verticalURL)
        print("SNAPSHOT: \(verticalURL.path)")
    }

    // MARK: Camera + everything together

    func testCameraBubbleWithCaptionsAndKeys() throws {
        var project = self.project()
        project.captions = [VideoCaptionLine(start: 1, end: 3, text: "Let me show you the new export flow")]
        project.keystrokes = [VideoKeystrokeEvent(time: 1.5, keys: ["⌘", "E"])]
        let renderer = VideoFrameRenderer()
        let screen = CIImage(cgImage: VideoTestSupport.fakeScreen(size: CGSize(width: 2880, height: 1800), progress: 0.4, typed: "Hello"))
        // A stand-in camera frame: warm face-ish gradient.
        let face = CIImage(color: CIColor(red: 0.85, green: 0.62, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
            .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 1.2, kCIInputRadiusKey: 2])
        var options = VideoFrameRenderer.Options()
        options.webcamFrame = face
        let size = CGSize(width: 1920, height: 1080)
        for (name, anchor, shape) in [("camera-bottomright-circle", VideoWebcamSettings.Anchor.bottomRight, VideoWebcamSettings.Shape.circle), ("camera-bottom-rounded", .bottom, .square), ("camera-topleft-wide", .topLeft, .rectangle)] {
            var styled = project
            styled.webcam.anchor = anchor
            styled.webcam.shape = shape
            let plan = VideoDemoExporter.makePlan(project: styled, sourceDuration: 10, recording: nil, hasWebcam: true)
            let image = renderer.render(source: screen, timelineTime: 2, plan: plan, outputSize: size, options: options)
            let url = try snapshotDirectory().appendingPathComponent("\(name).png")
            try VideoTestSupport.writePNG(image, size: size, to: url)
            print("SNAPSHOT: \(url.path)")
        }
    }

    // MARK: Crop

    func testCropMapsPointsAndCanvas() {
        var project = self.project()
        project.crop = VideoCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        XCTAssertEqual(project.croppedSourceSize, CGSize(width: 1440, height: 900))
        let crop = project.crop
        let mapped = crop.map(CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(mapped.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(mapped.y, 0.5, accuracy: 0.0001)
        let corner = crop.map(CGPoint(x: 0.25, y: 0.75))
        XCTAssertEqual(corner.x, 0, accuracy: 0.0001)
        XCTAssertEqual(corner.y, 1, accuracy: 0.0001)
        let back = crop.unmap(corner)
        XCTAssertEqual(back.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(back.y, 0.75, accuracy: 0.0001)

        // Clamped inside the frame with a minimum size.
        let wild = VideoCropRect(x: 0.9, y: -0.2, width: 0.01, height: 2).normalized
        XCTAssertEqual(wild.width, VideoCropRect.minimumSide, accuracy: 0.0001)
        XCTAssertEqual(wild.height, 1, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(wild.x + wild.width, 1.0001)
        XCTAssertEqual(wild.y, 0, accuracy: 0.0001)
    }

    func testCropRendersOnlyTheKeptArea() throws {
        // Left half red, right half blue.
        let size = CGSize(width: 1600, height: 1000)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 1000))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 800, y: 0, width: 800, height: 1000))
        let source = red.composited(over: blue)
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/crop.mp4"), duration: 5, sourceSize: size)
        project.cursor.visible = false
        project.background = .color(VideoRGBA(0, 0, 0))
        project.aspectPreset = .source
        project.padding = 0
        project.shadow = 0
        project.cornerRadius = 0
        project.crop = VideoCropRect(x: 0.5, y: 0, width: 0.5, height: 1) // keep the blue half
        let plan = VideoDemoExporter.makePlan(project: project, sourceDuration: 5, recording: nil)
        let renderer = VideoFrameRenderer()
        let output = CGSize(width: 800, height: 1000)
        let image = renderer.render(source: source, timelineTime: 1, plan: plan, outputSize: output)
        let center = averageColor(image, in: CGRect(x: 300, y: 400, width: 200, height: 200))
        XCTAssertGreaterThan(center.b, 0.8, "the kept half fills the frame")
        XCTAssertLessThan(center.r, 0.1)

        // Crop mode shows the whole recording, uncropped.
        var options = VideoFrameRenderer.Options()
        options.rawSource = true
        let raw = renderer.render(source: source, timelineTime: 1, plan: plan, outputSize: size, options: options)
        let left = averageColor(raw, in: CGRect(x: 100, y: 400, width: 200, height: 200))
        XCTAssertGreaterThan(left.r, 0.8)
    }
}
