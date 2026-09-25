import AVFoundation
import CoreImage
import XCTest
@testable import ShotnixCore

@MainActor
final class VideoReframeTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    /// Pointer rests on the left, then moves to the right side at 3 s.
    private func project() -> VideoDemoProject {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/reframe.mp4"), duration: 8, sourceSize: CGSize(width: 1920, height: 1080))
        var samples: [VideoDemoCursorSample] = []
        for index in 0..<(8 * 60) {
            let t = Double(index) / 60
            let x = t < 3 ? 0.1 : (t < 3.6 ? 0.1 + (t - 3) / 0.6 * 0.8 : 0.9)
            samples.append(VideoDemoCursorSample(time: t, x: x, y: 0.5))
        }
        project.cursorSamples = samples
        project.nativeCursorVisible = false
        project.cursor.hideWhenIdle = false
        project.padding = 0
        project.aspectPreset = .vertical
        project.reframe = true
        return project
    }

    private func average(_ image: CIImage, in rect: CGRect) -> (r: Double, g: Double, b: Double) {
        let context = CIContext()
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)]), toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    func testWhenReframingApplies() {
        var project = project()
        XCTAssertTrue(project.canReframe)
        XCTAssertTrue(project.reframeActive)
        project.aspectPreset = .widescreen
        XCTAssertFalse(project.canReframe, "a 16:9 frame fits a 16:9 recording")
        project.aspectPreset = .square
        XCTAssertTrue(project.canReframe)
        XCTAssertEqual(VideoReframe.windowFraction(outputAspect: 9.0 / 16, sceneAspect: 16.0 / 9) ?? 0, 0.316, accuracy: 0.001)
    }

    func testWindowFollowsThePointerAndNeverLosesIt() {
        let project = project()
        let plan = VideoDemoExporter.makePlan(project: project, sourceDuration: 8, recording: nil)
        let reframe = try? XCTUnwrap(plan.reframe)
        guard let reframe else { return }
        let half = Double(reframe.windowFraction) / 2
        XCTAssertLessThan(Double(reframe.center(at: 1)), 0.35, "starts on the left with the pointer")
        XCTAssertGreaterThan(Double(reframe.center(at: 6)), 0.65, "ends on the right with it")
        // The pointer viewers see (the drawn, smoothed one) is inside the
        // window the whole way — even through a fast sweep.
        let track = try? XCTUnwrap(plan.cursorTrack)
        for step in 0..<160 {
            let t = Double(step) * 0.05
            guard let pointer = track?.visiblePosition(at: t)?.x else { continue }
            let center = Double(reframe.center(at: t))
            XCTAssertLessThanOrEqual(abs(Double(pointer) - center), half + 0.01, "pointer in frame at \(t)s")
            XCTAssertGreaterThanOrEqual(center, half - 0.0001)
            XCTAssertLessThanOrEqual(center, 1 - half + 0.0001)
        }
    }

    func testRenderShowsTheSideThePointerIsOn() {
        let project = project()
        let plan = VideoDemoExporter.makePlan(project: project, sourceDuration: 8, recording: nil)
        XCTAssertEqual(plan.outputCanvasSize.width / plan.outputCanvasSize.height, 9.0 / 16, accuracy: 0.01)
        XCTAssertGreaterThan(plan.canvasSize.width, plan.canvasSize.height, "the scene stays landscape")
        // Left half red, right half blue.
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 960, height: 1080))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 960, y: 0, width: 960, height: 1080))
        let screen = red.composited(over: blue)
        let renderer = VideoFrameRenderer()
        let size = CGSize(width: 1080, height: 1920)
        var options = VideoFrameRenderer.Options()
        options.frameRate = 30
        let early = renderer.render(source: screen, timelineTime: 1, plan: plan, outputSize: size, options: options)
        let late = renderer.render(source: screen, timelineTime: 6, plan: plan, outputSize: size, options: options)
        let middle = CGRect(x: 440, y: 860, width: 200, height: 200)
        XCTAssertGreaterThan(average(early, in: middle).r, 0.8, "left side (red) while the pointer is there")
        XCTAssertGreaterThan(average(late, in: middle).b, 0.8, "right side (blue) after it moved")
        // Filled: no letterbox bars top and bottom.
        XCTAssertGreaterThan(average(late, in: CGRect(x: 440, y: 1800, width: 200, height: 60)).b, 0.8)
    }

    func testVerticalSnapshot() throws {
        var project = project()
        project.sourceWidth = 2880
        project.sourceHeight = 1800
        project.padding = 0.04
        project.captions = [VideoCaptionLine(start: 4, end: 7, text: "Now save your changes")]
        project.webcam.anchor = .bottomRight
        project.webcam.size = 0.3
        project.zoomRegions = []
        let plan = VideoDemoExporter.makePlan(project: project, sourceDuration: 8, recording: nil, hasWebcam: true)
        let screen = CIImage(cgImage: VideoTestSupport.fakeScreen(size: CGSize(width: 2880, height: 1800), progress: 0.4, typed: "Hello"))
        var options = VideoFrameRenderer.Options()
        options.webcamFrame = CIImage(color: CIColor(red: 0.85, green: 0.62, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        let size = CGSize(width: 1080, height: 1920)
        let image = VideoFrameRenderer().render(source: screen, timelineTime: 5, plan: plan, outputSize: size, options: options)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-reframe.png")
        try VideoTestSupport.writePNG(image, size: size, to: url)
        print("SNAPSHOT: \(url.path)")
    }

    func testExportIsVerticalWhenReframing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-reframe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rec.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 1280, height: 720), seconds: 3, fps: 30)
        var project = project()
        project.sourcePath = url.path
        project.timelineClips = []
        project.ensureTimeline(totalDuration: 3)
        var settings = VideoExportSettings()
        settings.resolution = .p1080
        settings.fps = 30
        settings.endCard = false
        let out = directory.appendingPathComponent("out.mp4")
        try await VideoDemoExporter.export(project: project, destinationURL: out, settings: settings)
        let tracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 1080)
        XCTAssertEqual(size.height, 1920)
    }

    func testSwitchingToVerticalTurnsReframingOn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-reframe-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rec.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 1280, height: 720), seconds: 3, fps: 30)
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        XCTAssertFalse(model.project.reframeActive)
        model.setAspect(.vertical)
        XCTAssertTrue(model.project.reframeActive)
        XCTAssertNotNil(model.plan.reframe)
        // Turned off stays off when moving between narrow shapes.
        model.setStyle { $0.reframe = false }
        model.setAspect(.square)
        XCTAssertFalse(model.project.reframe)
        VideoDemoDraftStore.delete(for: url)
    }
}
