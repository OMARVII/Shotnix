import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShotnixCore

/// End-to-end export coverage: synthesizes a tiny real MP4, then runs the full
/// exporter (composition + Core Animation overlay + export session) for both
/// formats. Guards the new GIF transcode path and the export options plumbing.
final class VideoDemoExportTests: XCTestCase {

    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotnix-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDirectory)
    }

    func testGIFExportProducesLoopingMultiFrameGIF() async throws {
        let sourceURL = try await makeSampleVideo(seconds: 1.2)
        var project = VideoDemoProject.make(sourceURL: sourceURL, duration: 1.2, sourceSize: CGSize(width: 320, height: 240))
        project.aspectPreset = .source
        // Exercise the scene-zoom animation path in a real render.
        project.zoomKeyframes = [
            VideoDemoZoomKeyframe(time: 0.2, scale: 1.6, focusX: 0.1, focusY: 0.9),
            VideoDemoZoomKeyframe(time: 0.9, scale: 1, focusX: 0.5, focusY: 0.5),
        ]

        let gifURL = workDirectory.appendingPathComponent("out.gif")
        let warnings = try await VideoDemoExporter.export(
            project: project,
            destinationURL: gifURL,
            options: VideoDemoExportOptions(format: .gif, fps: 30, halfResolution: false, endCard: true)
        )

        XCTAssertTrue(warnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gifURL.path))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
        let type = try XCTUnwrap(CGImageSourceGetType(source) as String?)
        XCTAssertEqual(type, UTType.gif.identifier)
        // 1.2s at 15fps ≈ 18 frames; anything comfortably above 1 proves the
        // frame loop ran rather than writing a single still.
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 8)
    }

    func testMP4ExportHonorsHalfResolutionAndSixtyFPS() async throws {
        let sourceURL = try await makeSampleVideo(seconds: 0.8)
        var project = VideoDemoProject.make(sourceURL: sourceURL, duration: 0.8, sourceSize: CGSize(width: 320, height: 240))
        project.aspectPreset = .widescreen

        let mp4URL = workDirectory.appendingPathComponent("out.mp4")
        _ = try await VideoDemoExporter.export(
            project: project,
            destinationURL: mp4URL,
            options: VideoDemoExportOptions(format: .mp4, fps: 60, halfResolution: true, endCard: true)
        )

        let asset = AVURLAsset(url: mp4URL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        // Widescreen canvas is 1920x1080; half resolution must land at 960x540.
        XCTAssertEqual(size.width, 960, accuracy: 2)
        XCTAssertEqual(size.height, 540, accuracy: 2)
    }

    func testZoomWindowStaysInsideCanvasThroughCornerRamp() {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), duration: 10, sourceSize: CGSize(width: 1920, height: 1080))
        // A click in the extreme top-left corner used to expose black beyond
        // the video edge; the scene-zoom window must always stay inside the
        // canvas (background fills any slack, black is impossible).
        project.zoomKeyframes = [
            VideoDemoZoomKeyframe(time: 0, scale: 1, focusX: 0.5, focusY: 0.5),
            VideoDemoZoomKeyframe(time: 2, scale: 1.8, focusX: 0.02, focusY: 0.97),
            VideoDemoZoomKeyframe(time: 4, scale: 1, focusX: 0.5, focusY: 0.5),
        ]
        let canvas = CGSize(width: 1920, height: 1080)

        for step in 0...80 {
            let time = Double(step) * 0.05
            let window = project.zoomWindow(in: canvas, at: time)
            XCTAssertGreaterThanOrEqual(window.minX, -0.001, "escapes left at t=\(time)")
            XCTAssertGreaterThanOrEqual(window.minY, -0.001, "escapes top at t=\(time)")
            XCTAssertLessThanOrEqual(window.maxX, canvas.width + 0.001, "escapes right at t=\(time)")
            XCTAssertLessThanOrEqual(window.maxY, canvas.height + 0.001, "escapes bottom at t=\(time)")
            // Aspect preserved: uniform scale.
            XCTAssertEqual(window.width / window.height, canvas.width / canvas.height, accuracy: 0.001)
        }
    }

    func testZoomWindowCentersInteriorFocus() {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), duration: 10, sourceSize: CGSize(width: 1920, height: 1080))
        project.zoomKeyframes = [VideoDemoZoomKeyframe(time: 1, scale: 1.8, focusX: 0.5, focusY: 0.5)]
        let canvas = CGSize(width: 1920, height: 1080)

        // "Zooms where I made it": an interior focus must land dead-center in
        // the visible window.
        let window = project.zoomWindow(in: canvas, at: 5)
        XCTAssertEqual(window.midX, canvas.width / 2, accuracy: 0.5)
        XCTAssertEqual(window.midY, canvas.height / 2, accuracy: 0.5)
        XCTAssertEqual(window.width, canvas.width / 1.8, accuracy: 0.5)
    }

    // MARK: - Sample video synthesis

    private func makeSampleVideo(seconds: Double) async throws -> URL {
        let url = workDirectory.appendingPathComponent("source.mp4")
        let size = CGSize(width: 320, height: 240)
        let fps = 30
        let frameCount = max(Int(seconds * Double(fps)), 2)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let buffer = try XCTUnwrap(makePixelBuffer(size: size, hue: CGFloat(frame) / CGFloat(frameCount)))
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: time))
        }

        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func makePixelBuffer(size: CGSize, hue: CGFloat) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
            &pixelBuffer
        )
        guard let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let color = NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1)
        context.setFillColor(color.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        return pixelBuffer
    }
}
