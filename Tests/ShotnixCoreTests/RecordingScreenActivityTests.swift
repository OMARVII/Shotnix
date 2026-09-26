import CoreVideo
import XCTest
@testable import ShotnixCore

/// `screenActivity` for the editor's idle detection: real changes count,
/// a blinking caret doesn't, and never more than ten samples a second.
final class RecordingScreenActivityTests: XCTestCase {
    private let frame = CGSize(width: 3024, height: 1964)

    func testSmallChangesDontCountAndTypingDoes() {
        var activity = RecordingScreenActivity()
        // A caret blink on a 2x display: 3×40 pixels = 30 points².
        activity.observe(time: 0.5, dirtyRects: [CGRect(x: 800, y: 400, width: 3, height: 40)], frameSize: frame, pixelsPerPoint: 2, grid: { nil })
        XCTAssertTrue(activity.samples.isEmpty)
        // A few typed characters: 60×40 pixels = 600 points².
        activity.observe(time: 0.7, dirtyRects: [CGRect(x: 800, y: 400, width: 60, height: 40)], frameSize: frame, pixelsPerPoint: 2, grid: { nil })
        XCTAssertEqual(activity.samples, [0.7])
    }

    func testThresholdIsInPointsNotPixels() {
        // 20×20 pixels: 400 points² at 1x (counts), 100 points² at 2x (doesn't).
        var oneX = RecordingScreenActivity()
        oneX.observe(time: 1, dirtyRects: [CGRect(x: 0, y: 0, width: 20, height: 20)], frameSize: frame, pixelsPerPoint: 1, grid: { nil })
        XCTAssertEqual(oneX.samples.count, 1)
        var twoX = RecordingScreenActivity()
        twoX.observe(time: 1, dirtyRects: [CGRect(x: 0, y: 0, width: 20, height: 20)], frameSize: frame, pixelsPerPoint: 2, grid: { nil })
        XCTAssertTrue(twoX.samples.isEmpty)
    }

    func testAtMostTenSamplesASecond() {
        var activity = RecordingScreenActivity()
        // A scrolling page: big changes on every frame at 60 fps for 2 s.
        for index in 0..<120 {
            activity.observe(time: Double(index) / 60, dirtyRects: [CGRect(x: 0, y: 0, width: 3024, height: 900)], frameSize: frame, pixelsPerPoint: 2, grid: { nil })
        }
        XCTAssertEqual(activity.samples.count, 20, accuracy: 1)
        XCTAssertTrue(zip(activity.samples, activity.samples.dropFirst()).allSatisfy { $1 - $0 >= 0.1 - 1e-6 }, "\(activity.samples)")
        XCTAssertEqual(activity.samples.first, 0)
    }

    func testNothingChangingMeansNoSamples() {
        var activity = RecordingScreenActivity()
        // The first frame of a stream reports an empty dirty rect.
        activity.observe(time: 0, dirtyRects: [.zero], frameSize: frame, pixelsPerPoint: 2, grid: { [0] })
        activity.observe(time: 0.2, dirtyRects: [], frameSize: frame, pixelsPerPoint: 2, grid: { [0] })
        XCTAssertTrue(activity.samples.isEmpty)
    }

    /// Some content reports the whole frame dirty every frame (the lock
    /// screen does); a pixel sample decides whether anything changed.
    func testWholeFrameDirtyFallsBackToPixels() {
        var activity = RecordingScreenActivity()
        let still = [UInt32](repeating: 0xFF20_2020, count: 100)
        var moving = still
        moving[10] = 0xFFFF_FFFF
        moving[70] = 0xFF00_00FF
        let whole = [CGRect(origin: .zero, size: frame)]
        activity.observe(time: 0, dirtyRects: [], frameSize: frame, pixelsPerPoint: 2, grid: { still })
        for index in 1...12 {
            activity.observe(time: Double(index) / 30, dirtyRects: whole, frameSize: frame, pixelsPerPoint: 2, grid: { still })
        }
        XCTAssertTrue(activity.samples.isEmpty, "repainted but unchanged")
        activity.observe(time: 0.5, dirtyRects: whole, frameSize: frame, pixelsPerPoint: 2, grid: { moving })
        XCTAssertEqual(activity.samples, [0.5])
        // A missing dirty-rect list is treated the same way.
        activity.observe(time: 0.7, dirtyRects: nil, frameSize: frame, pixelsPerPoint: 2, grid: { still })
        XCTAssertEqual(activity.samples, [0.5, 0.7])
    }

    func testPixelComparisonIgnoresNoise() {
        let base = [UInt32](repeating: 0xFF80_8080, count: 400)
        var dithered = base
        dithered[5] = 0xFF84_8284 // a shade, not a change
        dithered[9] = 0xFF7C_7E7C
        XCTAssertFalse(RecordingScreenActivity.changed(base, dithered))
        var oneChanged = base
        oneChanged[3] = 0xFFFF_FFFF
        XCTAssertFalse(RecordingScreenActivity.changed(base, oneChanged), "a single pixel (a caret) isn't activity")
        oneChanged[300] = 0xFF00_0000
        XCTAssertTrue(RecordingScreenActivity.changed(base, oneChanged))
    }

    func testGridSamplesAFrame() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1600, 900, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0x40, CVPixelBufferGetBytesPerRow(pixelBuffer) * 900)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        let before = try XCTUnwrap(RecordingScreenActivity.grid(of: pixelBuffer))
        XCTAssertEqual(before.count, 160 * 90)

        // A word typed into a text field: about 80×24 pixels.
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 400..<424 { memset(base + y * rowBytes + 700 * 4, 0xF0, 80 * 4) }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        let after = try XCTUnwrap(RecordingScreenActivity.grid(of: pixelBuffer))
        XCTAssertTrue(RecordingScreenActivity.changed(before, after))
    }
}
