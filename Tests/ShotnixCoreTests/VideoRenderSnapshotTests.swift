import AppKit
import CoreImage
import XCTest
@testable import ShotnixCore

/// Visual harness: renders representative frames through the real
/// renderer into PNGs (printed as SNAPSHOT: <path>) so the look can be
/// inspected without launching the app. Also asserts basic sanity.
final class VideoRenderSnapshotTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private func snapshotDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-render-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func demoProject(duration: Double = 12) -> (VideoDemoProject, VideoDemoRecordingMetadata) {
        let source = CGSize(width: 2880, height: 1800)
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"), duration: duration, sourceSize: source)
        let (samples, clicks) = VideoTestSupport.scriptedPointer(duration: duration)
        let shape = VideoTestSupport.currentCursorShape()
        let metadata = VideoDemoRecordingMetadata(
            videoURLPath: "/tmp/demo.mp4",
            createdAt: Date(),
            duration: duration,
            sourceWidth: source.width,
            sourceHeight: source.height,
            fps: 60,
            nativeCursorVisible: false,
            cursorSamples: samples,
            clickEvents: clicks,
            pointPixelScale: 2,
            cursorShapes: shape.map { [$0] },
            cursorShapeEvents: shape.map { [VideoCursorShapeEvent(time: 0, shapeID: $0.id)] },
            renderCursor: true
        )
        project.apply(metadata: metadata)
        return (project, metadata)
    }

    func testRenderRepresentativeFrames() throws {
        let (baseProject, metadata) = demoProject()
        let screen = CIImage(cgImage: VideoTestSupport.fakeScreen(size: CGSize(width: 2880, height: 1800), progress: 0.4, typed: "Acme De"))
        let dir = try snapshotDirectory()

        var project = baseProject
        project.zoomRegions = VideoAutoZoomPlanner.regions(
            clicks: project.clickEvents,
            cursorSamples: project.cursorSamples,
            segments: project.timelineSegments(totalDuration: 12),
            scale: 2,
            speed: .smooth
        )
        XCTAssertFalse(project.zoomRegions.isEmpty)

        let renderer = VideoFrameRenderer()
        let plan = VideoDemoExporter.makePlan(project: project, sourceDuration: 12, recording: metadata)
        let output = CGSize(width: 1920, height: 1080)
        for time in [0.5, 1.0, 1.55, 3.3, 5.0, 6.1] {
            let image = renderer.render(source: screen, timelineTime: time, plan: plan, outputSize: output)
            let url = dir.appendingPathComponent(String(format: "frame-%.2f.png", time))
            try VideoTestSupport.writePNG(image, size: output, to: url)
            print("SNAPSHOT: \(url.path)")
        }

        // Vertical canvas with a gradient background and a text callout.
        var vertical = project
        vertical.aspectPreset = .vertical
        vertical.background = .gradient("violet")
        vertical.overlayEffects = [
            VideoDemoOverlayEffect(kind: .text, time: 0, duration: 12, x: 0.5, y: 0.12, width: 0.6, height: 0.08, text: "Change the theme in one click"),
            VideoDemoOverlayEffect(kind: .blur, time: 0, duration: 12, x: 0.5, y: 0.62, width: 0.4, height: 0.06),
        ]
        vertical.zoomRegions = []
        let verticalPlan = VideoDemoExporter.makePlan(project: vertical, sourceDuration: 12, recording: metadata)
        let verticalSize = CGSize(width: 1080, height: 1920)
        let verticalImage = renderer.render(source: screen, timelineTime: 2, plan: verticalPlan, outputSize: verticalSize)
        let verticalURL = dir.appendingPathComponent("vertical.png")
        try VideoTestSupport.writePNG(verticalImage, size: verticalSize, to: verticalURL)
        print("SNAPSHOT: \(verticalURL.path)")

        // Every built-in wallpaper, small, for a contact sheet.
        for wallpaper in VideoBackgroundCatalog.wallpapers {
            let image = VideoBackgroundRenderer.image(for: .wallpaper(wallpaper.id), blur: 0, size: CGSize(width: 480, height: 270))
            let url = dir.appendingPathComponent("wallpaper-\(wallpaper.id).png")
            try VideoTestSupport.writePNG(image, size: CGSize(width: 480, height: 270), to: url)
        }
        print("SNAPSHOT-DIR: \(dir.path)")
    }
}
