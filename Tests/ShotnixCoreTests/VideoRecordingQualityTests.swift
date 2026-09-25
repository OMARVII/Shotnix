import AVFoundation
import CoreImage
import XCTest
@testable import ShotnixCore

/// What gets recorded must look like the screen: exact colors, whole
/// pixels, nothing resampled, no unfilled edge.
@MainActor
final class VideoRecordingQualityTests: XCTestCase {
    func testRecordingKeepsColorsExact() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("colors-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let width = 640, height = 360
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: RecordingEngine.videoSettings(width: width, height: height, fps: 30, quality: .high))
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let colors: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (128, 128, 128), (255, 200, 0), (0, 122, 255)]
        for (index, color) in colors.enumerated() {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer!)
            for y in 0..<height {
                for x in 0..<width {
                    let p = base + y * row + x * 4
                    p[0] = color.2; p[1] = color.1; p[2] = color.0; p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            // Tagged the way ScreenCaptureKit tags sRGB frames.
            CVBufferSetAttachment(buffer!, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
            CVBufferSetAttachment(buffer!, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer!, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer!, formatDescriptionOut: &format)
            for frame in 0..<6 {
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: CMTimeValue(index * 6 + frame), timescale: 30), decodeTimeStamp: .invalid)
                var sample: CMSampleBuffer?
                CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer!, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                input.append(sample!)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let context = CIContext()
        for (index, color) in colors.enumerated() {
            let image = try await generator.image(at: CMTime(value: CMTimeValue(index * 6 + 3), timescale: 30)).image
            let ci = CIImage(cgImage: image)
            var px = [UInt8](repeating: 0, count: 4)
            context.render(ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent.insetBy(dx: 60, dy: 60))]), toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            for (got, want) in zip(px.prefix(3), [color.0, color.1, color.2]) {
                XCTAssertLessThanOrEqual(abs(Int(got) - Int(want)), 3, "color \(color) came back as \(Array(px.prefix(3)))")
            }
        }
    }

    /// The exported file looks like the preview (no gamma lift).
    func testExportColorsMatchThePreview() async throws {
        VideoTestStorage.isolate()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-colors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("src.mp4")
        try await VideoTestSupport.writeFakeRecording(to: src, size: CGSize(width: 1280, height: 720), seconds: 2, fps: 30)
        for background in [VideoRGBA(0.5, 0.5, 0.5), VideoRGBA(0.2, 0.6, 0.9)] {
            var project = VideoDemoProject.make(sourceURL: src, duration: 2, sourceSize: CGSize(width: 1280, height: 720))
            project.cursor.visible = false
            project.background = .color(background)
            let out = dir.appendingPathComponent("out.mp4")
            var settings = VideoExportSettings()
            settings.resolution = .p720
            settings.fps = 30
            settings.endCard = false
            try await VideoDemoExporter.export(project: project, destinationURL: out, settings: settings)
            let exported = try await AVAssetImageGenerator(asset: AVURLAsset(url: out)).image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
            let plan = VideoDemoExporter.makePlan(project: project, sourceDuration: 2, recording: nil)
            let ideal = VideoFrameRenderer().render(source: nil, timelineTime: 1, plan: plan, outputSize: CGSize(width: 1280, height: 720))
            let corner = CGRect(x: 4, y: 4, width: 20, height: 20)
            func average(_ image: CIImage) -> [Int] {
                var px = [UInt8](repeating: 0, count: 4)
                CIContext().render(image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: corner)]), toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                return px.prefix(3).map(Int.init)
            }
            let got = average(CIImage(cgImage: exported))
            let want = average(ideal)
            for (a, b) in zip(got, want) {
                XCTAssertLessThanOrEqual(abs(a - b), 3, "exported \(got), preview \(want)")
            }
        }
    }

    func testCaptureRegionIsWholeEvenPixels() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // An odd, fractional selection on a 2x display.
        let geometry = RecordingEngine.captureGeometry(rect: CGRect(x: 100.3, y: 200.7, width: 640.25, height: 360.5), screenFrame: screen, scale: 2)
        XCTAssertEqual(geometry.pixelWidth % 2, 0)
        XCTAssertEqual(geometry.pixelHeight % 2, 0)
        XCTAssertGreaterThanOrEqual(CGFloat(geometry.pixelWidth), 640.25 * 2)
        // The captured region is exactly the output size: no resampling, no blank edge.
        XCTAssertEqual(geometry.sourceRect.width * 2, CGFloat(geometry.pixelWidth), accuracy: 0.0001)
        XCTAssertEqual(geometry.sourceRect.height * 2, CGFloat(geometry.pixelHeight), accuracy: 0.0001)
        // On the pixel grid.
        XCTAssertEqual((geometry.sourceRect.minX * 2).rounded(), geometry.sourceRect.minX * 2, accuracy: 0.0001)
        XCTAssertEqual((geometry.sourceRect.minY * 2).rounded(), geometry.sourceRect.minY * 2, accuracy: 0.0001)
        // The recorded region covers the selection.
        XCTAssertLessThanOrEqual(geometry.capturedRect.minX, 100.3)
        XCTAssertGreaterThanOrEqual(geometry.capturedRect.maxX, 100.3 + 640.25 - 0.0001)

        // Whole-number sizes stay exact (a 1280×720 area is 2560×1440 pixels).
        let exact = RecordingEngine.captureGeometry(rect: CGRect(x: 10, y: 10, width: 1280, height: 720), screenFrame: screen, scale: 2)
        XCTAssertEqual(exact.pixelWidth, 2560)
        XCTAssertEqual(exact.pixelHeight, 1440)
        XCTAssertEqual(exact.capturedRect, CGRect(x: 10, y: 10, width: 1280, height: 720))

        // At the screen's edge, rounding up to even steps back inside it.
        let edge = RecordingEngine.captureGeometry(rect: CGRect(x: 1000.5, y: 0, width: 511.5, height: 400), screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 1)
        XCTAssertLessThanOrEqual(edge.sourceRect.maxX, 1512 + 0.0001)
        XCTAssertEqual(edge.pixelWidth % 2, 0)

        // A second display to the right: display-local math.
        let second = RecordingEngine.captureGeometry(rect: CGRect(x: 1600, y: 100, width: 800, height: 450), screenFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), scale: 1)
        XCTAssertEqual(second.sourceRect.minX, 88, accuracy: 0.0001)
        XCTAssertEqual(second.sourceRect.minY, 1080 - 100 - 450, accuracy: 0.0001, "top-left origin inside the display")
    }
}
