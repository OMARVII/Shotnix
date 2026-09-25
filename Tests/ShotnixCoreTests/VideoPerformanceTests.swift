import AVFoundation
import CoreImage
import XCTest
@testable import ShotnixCore

/// Budget checks: the preview must render a Retina recording well inside a
/// 60Hz frame, and export must beat real time.
final class VideoPerformanceTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    func testPreviewFrameRenderBudget() throws {
        let source = CIImage(cgImage: VideoTestSupport.fakeScreen(size: CGSize(width: 2880, height: 1800), progress: 0.5, typed: "Acme"))
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/perf.mp4"), duration: 10, sourceSize: CGSize(width: 2880, height: 1800))
        project.apply(style: .factory)
        let (samples, clicks) = VideoTestSupport.scriptedPointer(duration: 10)
        project.cursorSamples = samples
        project.clickEvents = clicks
        project.nativeCursorVisible = false
        project.zoomRegions = [VideoZoomRegion(start: 1, end: 9, scale: 2, followsCursor: true)]
        let plan = VideoDemoExporter.makePlan(project: project, sourceDuration: 10, recording: nil)
        let renderer = VideoFrameRenderer()
        let context = VideoRenderContext.makeContext()
        let size = CGSize(width: 2600, height: 1462) // a Retina preview area

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
        let target = try XCTUnwrap(buffer)

        // Warm up (shader compiles, caches).
        for i in 0..<10 {
            context.render(renderer.render(source: source, timelineTime: Double(i) * 0.1, plan: plan, outputSize: size), to: target, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        let frames = 120
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<frames {
            let image = renderer.render(source: source, timelineTime: 1.5 + Double(i) / 60, plan: plan, outputSize: size)
            context.render(image, to: target, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        let perFrame = (CFAbsoluteTimeGetCurrent() - start) / Double(frames) * 1000
        print(String(format: "PERF: preview frame %.2f ms (%.0f fps)", perFrame, 1000 / perFrame))
        XCTAssertLessThan(perFrame, 16, "must fit a 60Hz frame with room to spare")
    }

    func testExportBeatsRealTime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("src.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 2880, height: 1800), seconds: 6, fps: 60)
        var project = VideoDemoProject.make(sourceURL: url, duration: 6, sourceSize: CGSize(width: 2880, height: 1800))
        project.apply(style: .factory)
        let (samples, clicks) = VideoTestSupport.scriptedPointer(duration: 6)
        project.cursorSamples = samples
        project.clickEvents = clicks
        project.nativeCursorVisible = false
        project.zoomRegions = [VideoZoomRegion(start: 1, end: 5, scale: 2, followsCursor: true)]
        var settings = VideoExportSettings()
        settings.resolution = .p1080
        settings.fps = 60
        settings.endCard = false
        let start = CFAbsoluteTimeGetCurrent()
        try await VideoDemoExporter.export(project: project, destinationURL: directory.appendingPathComponent("out.mp4"), settings: settings)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print(String(format: "PERF: 6s 1080p60 export in %.2fs (%.1fx real time)", elapsed, 6 / elapsed))
        XCTAssertLessThan(elapsed, 6)
    }
}
