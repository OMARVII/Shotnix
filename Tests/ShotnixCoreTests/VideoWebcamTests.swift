import AVFoundation
import CoreImage
import XCTest
@testable import ShotnixCore

/// Camera footage end to end: the recorder's camera writer, alignment by
/// host-clock offset, the edited composition (cuts), preview frames, and
/// the exported bubble.
@MainActor
final class VideoWebcamTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-webcam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory {
            VideoDemoDraftStore.delete(for: directory.appendingPathComponent("screen.mp4"))
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A distinct color for every second of camera footage.
    static let palette: [(r: Double, g: Double, b: Double)] = [
        (1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (1, 0, 1), (0, 1, 1), (1, 1, 1), (1, 0.5, 0),
    ]

    private func colorBuffer(_ color: (r: Double, g: Double, b: Double), size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                let p = base + y * row + x * 4
                p[0] = UInt8(color.b * 255); p[1] = UInt8(color.g * 255); p[2] = UInt8(color.r * 255); p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Writes camera footage through the recorder's own pipeline, with
    /// frames stamped on a host clock that starts at `hostStart`.
    private func recordCamera(seconds: Double, hostStart: Double) async throws -> CameraPipeline.Result {
        let pipeline = CameraPipeline()
        let url = directory.appendingPathComponent("camera.mov")
        pipeline.begin(url: url)
        let size = CGSize(width: 320, height: 180)
        var frames: [Int: CVPixelBuffer] = [:]
        for index in Self.palette.indices { frames[index] = colorBuffer(Self.palette[index], size: size) }
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frames[0]!, formatDescriptionOut: &format)
        let count = Int(seconds * 30)
        for frame in 0..<count {
            let t = Double(frame) / 30
            let buffer = frames[min(Int(t), Self.palette.count - 1)]!
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(seconds: hostStart + t, preferredTimescale: 60000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
            nonisolated(unsafe) let ready = sample!
            // Real-time writers drop frames when busy; give each a moment.
            try await Task.sleep(nanoseconds: 3_000_000)
            pipeline.queue.sync { pipeline.append(ready) }
        }
        let result = await pipeline.finish()
        return try XCTUnwrap(result, "camera movie finished")
    }

    private func makeRecording() async throws -> (url: URL, metadata: VideoDemoRecordingMetadata) {
        let url = directory.appendingPathComponent("screen.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 960, height: 600), seconds: 6, fps: 30)
        // Camera rolled 0.5 s before the first screen frame.
        let camera = try await recordCamera(seconds: 7.5, hostStart: 1000)
        XCTAssertEqual(camera.firstFrameTime, 1000, accuracy: 0.001)
        let screenStart = 1000.5
        let metadata = VideoDemoRecordingMetadata(
            videoURLPath: url.path, createdAt: Date(), duration: 6, sourceWidth: 960, sourceHeight: 600,
            fps: 30, nativeCursorVisible: false, cursorSamples: [], clickEvents: [],
            webcam: VideoWebcamRecording(path: camera.url.path, offset: camera.firstFrameTime - screenStart, width: Double(camera.size.width), height: Double(camera.size.height))
        )
        XCTAssertTrue(VideoDemoSidecarStore.save(metadata, for: url))
        return (url, metadata)
    }

    private func dominant(_ color: (r: Double, g: Double, b: Double)) -> Int? {
        Self.palette.firstIndex { abs($0.r - color.r) < 0.25 && abs($0.g - color.g) < 0.25 && abs($0.b - color.b) < 0.25 }
    }

    private func average(_ image: CIImage, in rect: CGRect) -> (r: Double, g: Double, b: Double) {
        let context = CIContext()
        var pixel = [UInt8](repeating: 0, count: 4)
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    func testCameraCompositionFollowsOffsetAndCuts() async throws {
        let (url, metadata) = try await makeRecording()
        var project = VideoDemoProject.make(sourceURL: url, duration: 6, sourceSize: CGSize(width: 960, height: 600))
        project.apply(metadata: metadata)
        project.webcam.anchor = .bottomRight
        project.webcam.shape = .square
        project.webcam.size = 0.3
        project.webcam.mirror = false
        project.webcam.shrinkWhenZoomed = false
        project.cursor.visible = false
        // Cut 2…3 s of the recording.
        project.timelineClips = [
            VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 2),
            VideoDemoTimelineClip(sourceStart: 3, sourceEnd: 6),
        ]

        let out = directory.appendingPathComponent("out.mp4")
        var settings = VideoExportSettings()
        settings.resolution = .p720
        settings.fps = 30
        settings.endCard = false
        try await VideoDemoExporter.export(project: project, recording: metadata, destinationURL: out, settings: settings)

        let asset = AVURLAsset(url: out)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let outputSize = CGSize(width: 1280, height: 720)
        let bubble = VideoFrameRenderer.webcamRect(project.webcam, outputSize: outputSize)
        let probe = CGRect(x: bubble.midX - 20, y: bubble.midY - 20, width: 40, height: 40)
        // timeline → source → camera (+0.5 s) → color index
        let expectations: [(timeline: Double, index: Int)] = [(1.0, 1), (2.4, 3), (4.2, 5)]
        for expectation in expectations {
            let image = try await generator.image(at: CMTime(seconds: expectation.timeline, preferredTimescale: 600)).image
            let color = average(CIImage(cgImage: image), in: probe)
            XCTAssertEqual(dominant(color), expectation.index, "timeline \(expectation.timeline)s shows camera color \(color)")
        }
    }

    func testPreviewDeliversMatchingCameraFrames() async throws {
        let (url, _) = try await makeRecording()
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        XCTAssertTrue(model.isReady)
        XCTAssertTrue(model.hasWebcamFootage)
        XCTAssertNotNil(model.plan.webcam)

        model.seek(to: 3.2)
        var cameraFrame: CIImage?
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let frame = model.playback.frame(forHostTime: CACurrentMediaTime()) {
                cameraFrame = model.playback.cameraFrame(at: frame.time)
                if cameraFrame != nil { break }
            }
        }
        let frame = try XCTUnwrap(cameraFrame, "a camera frame arrives with the screen frame")
        // Source 3.2 s → camera 3.7 s → yellow.
        XCTAssertEqual(dominant(average(frame, in: frame.extent.insetBy(dx: 20, dy: 20))), 3)
    }

    func testCameraLayoutEditing() async throws {
        let (url, _) = try await makeRecording()
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        XCTAssertTrue(model.hasWebcamFootage)
        model.seek(to: 1)
        model.addCameraLayout(.fullscreen)
        XCTAssertEqual(model.project.cameraLayouts.count, 1)
        let first = try XCTUnwrap(model.project.cameraLayouts.first)
        XCTAssertEqual(first.start, 1, accuracy: 0.05)
        XCTAssertEqual(first.end, 4, accuracy: 0.05)
        // Adding inside an existing one starts after it and fits the gap.
        model.seek(to: 2)
        model.addCameraLayout(.sideBySide)
        let second = try XCTUnwrap(model.project.cameraLayouts.last)
        XCTAssertEqual(second.start, 4, accuracy: 0.05)
        XCTAssertEqual(second.end, 6, accuracy: 0.05, "fitted up to the end of the video")
        // Moving the second one left slides against the first instead of overlapping.
        model.setCameraLayoutWindow(second.id, timelineStart: 2.5, timelineEnd: 4.5, moving: true)
        let moved = try XCTUnwrap(model.project.cameraLayouts.first { $0.id == second.id })
        XCTAssertEqual(moved.start, 4, accuracy: 0.05)
        model.setCameraLayout(second.id, to: .hidden)
        XCTAssertEqual(model.project.cameraLayouts.first { $0.id == second.id }?.layout, .hidden)
        XCTAssertEqual(model.plan.cameraLayout(at: 2.5)?.layout, .fullscreen)
        model.deleteSelection()
        XCTAssertEqual(model.project.cameraLayouts.count, 1)
        // Intro and outro.
        model.addCameraIntroOutro(length: 1.5)
        XCTAssertEqual(model.project.cameraLayouts.map(\.layout), [.fullscreen, .fullscreen])
        XCTAssertEqual(model.project.cameraLayouts.last?.end ?? 0, 6, accuracy: 0.05)
    }

    func testBubbleGeometry() {
        var settings = VideoWebcamSettings()
        settings.size = 0.25
        settings.shape = .rectangle
        settings.anchor = .topLeft
        settings.shrinkWhenZoomed = true
        let size = CGSize(width: 1920, height: 1080)
        let rect = VideoFrameRenderer.webcamRect(settings, outputSize: size)
        XCTAssertEqual(rect.height, 270, accuracy: 1)
        XCTAssertEqual(rect.width, 360, accuracy: 1)
        XCTAssertEqual(rect.minX, 43, accuracy: 1)
        XCTAssertEqual(rect.maxY, 1080 - 43, accuracy: 1, "top edge, 4% margin (y up)")
        let zoomed = VideoFrameRenderer.webcamRect(settings, outputSize: size, cameraScale: 2)
        XCTAssertEqual(zoomed.height, 189, accuracy: 1, "shrinks to 70% while zoomed")
        XCTAssertEqual(VideoWebcamSettings.Anchor.nearest(to: CGPoint(x: 0.9, y: 0.95)), .bottomRight)
        XCTAssertEqual(VideoWebcamSettings.Anchor.nearest(to: CGPoint(x: 0.45, y: 0.1)), .top)
    }
}

final class VideoCameraFrameStoreTests: XCTestCase {
    private func buffer(width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        return buffer!
    }

    func testStoresNearestFramesAndCapsSize() {
        let store = VideoCameraFrameStore(capacity: 4)
        for index in 0..<10 {
            store.put(buffer(width: 1920, height: 1080), at: 5 + Double(index) / 30)
        }
        XCTAssertNil(store.frame(at: 5), "old frames are dropped")
        let latest = store.frame(at: 5 + 9.0 / 30)
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.extent.height ?? 0, 720, accuracy: 0.5, "copies are capped at 720p")
        XCTAssertNotNil(store.frame(at: 5 + 8.4 / 30), "nearest within tolerance")
        XCTAssertNil(store.frame(at: 8), "nothing near")
        // Seeking far backwards starts over.
        store.put(buffer(width: 640, height: 360), at: 0.1)
        XCTAssertNil(store.frame(at: 5 + 9.0 / 30, tolerance: 0.01))
        XCTAssertEqual(store.frame(at: 0.1)?.extent.width ?? 0, 640, accuracy: 0.5)
    }

    func testConcurrentPutsAreSafe() {
        let store = VideoCameraFrameStore(capacity: 8)
        let buffers = (0..<4).map { _ in buffer(width: 320, height: 180) }
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            store.put(buffers[index % 4], at: Double(index) / 60)
            _ = store.frame(at: Double(index) / 60)
        }
        XCTAssertNotNil(store.frame(at: 199.0 / 60, tolerance: 1))
    }
}
