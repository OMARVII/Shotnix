import AVFoundation
import XCTest
@testable import ShotnixCore

/// Codec, size and bitrate choices: every display records in a format its
/// encoder can take in real time and a player can open.
final class RecordingEncodingTests: XCTestCase {
    private struct Display {
        let name: String
        let points: CGSize
        let scale: CGFloat
        var pixels: (Int, Int) { (Int(points.width * scale), Int(points.height * scale)) }
    }

    func testCodecAndSizeAcrossDisplays() {
        let cases: [(Display, fps: Int, codec: RecordingVideoFormat.Codec)] = [
            (Display(name: "14-inch MacBook Pro", points: CGSize(width: 1512, height: 982), scale: 2), 60, .h264),
            (Display(name: "16-inch MacBook Pro", points: CGSize(width: 1728, height: 1117), scale: 2), 60, .h264),
            (Display(name: "4K at 1x", points: CGSize(width: 3840, height: 2160), scale: 1), 60, .h264),
            (Display(name: "1440p ultrawide", points: CGSize(width: 3440, height: 1440), scale: 1), 60, .h264),
            (Display(name: "Studio Display / 5K", points: CGSize(width: 2560, height: 1440), scale: 2), 60, .hevc),
            (Display(name: "Studio Display / 5K at 30", points: CGSize(width: 2560, height: 1440), scale: 2), 30, .hevc),
            (Display(name: "Pro Display XDR (6K)", points: CGSize(width: 3008, height: 1692), scale: 2), 60, .hevc),
            (Display(name: "4K monitor on More Space", points: CGSize(width: 3840, height: 2160), scale: 2), 60, .hevc),
            (Display(name: "5K2K ultrawide at 1x", points: CGSize(width: 5120, height: 2160), scale: 1), 60, .hevc),
        ]
        for (display, fps, codec) in cases {
            let (width, height) = display.pixels
            let format = RecordingVideoFormat.plan(width: width, height: height, fps: fps, hevcAvailable: true)
            XCTAssertEqual(format.codec, codec, display.name)
            XCTAssertEqual(format.width, width, "\(display.name): nothing is scaled when an encoder takes the full size")
            XCTAssertEqual(format.height, height, display.name)
        }
    }

    func testH264StaysInsideLevel52() {
        // 4096×2304 fits at 30 fps but not at 60 (2,073,600 macroblocks a second).
        XCTAssertTrue(RecordingVideoFormat.fitsH264(width: 4096, height: 2304, fps: 30))
        XCTAssertFalse(RecordingVideoFormat.fitsH264(width: 4096, height: 2304, fps: 60))
        XCTAssertTrue(RecordingVideoFormat.fitsH264(width: 4096, height: 2160, fps: 60))
        // Apple's hardware encoder stops at 4096 a side.
        XCTAssertFalse(RecordingVideoFormat.fitsH264(width: 4480, height: 1200, fps: 30))
        XCTAssertEqual(RecordingVideoFormat.plan(width: 4096, height: 2304, fps: 60, hevcAvailable: true).codec, .hevc)
    }

    func testWithoutHEVCBigDisplaysScaleDownToFitH264() {
        for (width, height) in [(5120, 2880), (6016, 3384), (7680, 4320), (5120, 2160)] {
            for fps in [30, 60] {
                let format = RecordingVideoFormat.plan(width: width, height: height, fps: fps, hevcAvailable: false)
                XCTAssertEqual(format.codec, .h264)
                XCTAssertTrue(RecordingVideoFormat.fitsH264(width: format.width, height: format.height, fps: fps), "\(width)×\(height)@\(fps) → \(format.width)×\(format.height)")
                XCTAssertEqual(format.width % 2, 0)
                XCTAssertEqual(format.height % 2, 0)
                let aspect = Double(width) / Double(height)
                let scaledAspect = Double(format.width) / Double(format.height)
                XCTAssertEqual(scaledAspect, aspect, accuracy: aspect * 0.01, "keeps its shape")
                // Roughly 4K, not needlessly small.
                XCTAssertGreaterThan(format.width * format.height, 6_000_000)
            }
        }
        // Past the HEVC encoder's 8K limit even HEVC can't take it.
        let giant = RecordingVideoFormat.plan(width: 10_000, height: 5_000, fps: 60, hevcAvailable: true)
        XCTAssertEqual(giant.codec, .h264)
        XCTAssertTrue(RecordingVideoFormat.fitsH264(width: giant.width, height: giant.height, fps: 60))
    }

    func testThisMacHasAnHEVCEncoder() {
        // Every Apple silicon Mac encodes HEVC in hardware.
        XCTAssertTrue(RecordingVideoFormat.hevcEncoderAvailable)
    }

    func testBitrateScalesWithFrameRate() {
        let quality = RecordingQuality.high
        // 30 fps is unchanged from before.
        let pixels = 1920 * 1080
        let legacy30 = Int((Double(pixels) * 30 * quality.bitsPerPixelPerFrame).rounded())
        XCTAssertEqual(quality.bitrate(width: 1920, height: 1080, fps: 30), min(max(legacy30, quality.minimumBitrate), quality.maximumBitrate))

        // 60 fps gets ~1.7× the bits of 30, not 1× (the old fixed ceiling) or a full 2×.
        let at30 = quality.bitrate(width: 3024, height: 1964, fps: 30)
        let at60 = quality.bitrate(width: 3024, height: 1964, fps: 60)
        XCTAssertEqual(Double(at60) / Double(at30), pow(2, 0.75), accuracy: 0.01)

        // The ceiling moves with the frame rate: a 5K display at 60 fps is no
        // longer squeezed into the 30 fps budget.
        let fiveK60 = quality.bitrate(width: 5120, height: 2880, fps: 60)
        XCTAssertGreaterThan(fiveK60, quality.maximumBitrate)
        XCTAssertLessThanOrEqual(fiveK60, Int(Double(quality.maximumBitrate) * pow(2, 0.75)) + 1)

        // HEVC needs fewer bits for the same detail.
        let hevc = quality.bitrate(width: 5120, height: 2880, fps: 60, codec: .hevc)
        XCTAssertEqual(Double(hevc) / Double(fiveK60), 0.7, accuracy: 0.01)

        // Better quality never means fewer bits.
        for fps in [30, 60] {
            let balanced = RecordingQuality.balanced.bitrate(width: 3024, height: 1964, fps: fps)
            let high = RecordingQuality.high.bitrate(width: 3024, height: 1964, fps: fps)
            let max = RecordingQuality.max.bitrate(width: 3024, height: 1964, fps: fps)
            XCTAssertLessThan(balanced, high)
            XCTAssertLessThan(high, max)
        }
    }

    func testQueueDepthKeepsFrameMemoryBounded() {
        XCTAssertEqual(RecordingVideoFormat.queueDepth(width: 1280, height: 720), 6)
        XCTAssertEqual(RecordingVideoFormat.queueDepth(width: 3024, height: 1964), 6)
        let fiveK = RecordingVideoFormat.queueDepth(width: 5120, height: 2880)
        XCTAssertLessThanOrEqual(fiveK * 5120 * 2880 * 4, 300_000_000)
        XCTAssertEqual(RecordingVideoFormat.queueDepth(width: 7680, height: 4320), 3, "never fewer than 3")
    }

    func testSizeEstimate() {
        // 12 Mbit/s video + both audio tracks, per minute.
        let bytes = RecordingSizeEstimate.bytesPerMinute(videoBitrate: 12_000_000, systemAudio: true, microphone: true)
        XCTAssertEqual(bytes, (12_000_000 + 192_000 + 128_000) * 60 / 8)
        XCTAssertEqual(RecordingSizeEstimate.bytesPerMinute(videoBitrate: 12_000_000, systemAudio: false, microphone: false), 90_000_000)

        let label = RecordingSizeEstimate.label(bytesPerMinute: 90_000_000)
        XCTAssertTrue(label.hasPrefix("up to "), label)
        XCTAssertTrue(label.contains("MB/min"), label)
        XCTAssertTrue(RecordingSizeEstimate.label(bytesPerMinute: 1_500_000_000).contains("GB/min"))

        // 60 fps costs more than 30, Max more than Balanced.
        let size30 = RecordingSizeEstimate.bytesPerMinute(pixelWidth: 3024, pixelHeight: 1964, fps: 30, quality: .high, systemAudio: false, microphone: false)
        let size60 = RecordingSizeEstimate.bytesPerMinute(pixelWidth: 3024, pixelHeight: 1964, fps: 60, quality: .high, systemAudio: false, microphone: false)
        XCTAssertGreaterThan(size60, size30)
        let balanced = RecordingSizeEstimate.bytesPerMinute(pixelWidth: 3024, pixelHeight: 1964, fps: 60, quality: .balanced, systemAudio: false, microphone: false)
        XCTAssertLessThan(balanced, size60)
    }

    func testDiskSpaceThresholdsLeaveRoomToFinish() {
        let rate: Int64 = 10_000_000 // 80 Mbit/s
        let stop = RecordingDiskSpace.stopThreshold(bytesPerSecond: rate)
        let warn = RecordingDiskSpace.warningThreshold(bytesPerSecond: rate)
        XCTAssertGreaterThanOrEqual(stop, 200 * 1_024 * 1_024 + rate * 20)
        XCTAssertEqual(warn - stop, rate * 60, "the warning comes about a minute before the stop")
        XCTAssertLessThan(stop, RecordingDiskSpace.minimumToStart + rate * 60)
        XCTAssertNotNil(RecordingDiskSpace.availableCapacity(at: FileManager.default.temporaryDirectory))
    }

    /// The HEVC settings the engine uses are accepted and encode real frames.
    func testHEVCWriterEncodesABigDisplay() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hevc-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = RecordingVideoFormat.plan(width: 5120, height: 2880, fps: 60, hevcAvailable: true)
        XCTAssertEqual(format.codec, .hevc)
        let handles = try RecordingEngine.makeWriter(url: url, format: format, fps: 60, quality: .high, microphone: false, systemAudio: false)
        handles.writer.startSession(atSourceTime: .zero)
        for frame in 0..<6 {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, format.width, format.height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            let pixelBuffer = try XCTUnwrap(buffer)
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &description)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: 60), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: try XCTUnwrap(description), sampleTiming: &timing, sampleBufferOut: &sample)
            while !handles.videoInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            XCTAssertTrue(handles.videoInput.append(try XCTUnwrap(sample)))
        }
        handles.videoInput.markAsFinished()
        await handles.writer.finishWriting()
        XCTAssertEqual(handles.writer.status, .completed, "\(String(describing: handles.writer.error))")
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 5120, height: 2880))
        let formats = try await track.load(.formatDescriptions)
        XCTAssertEqual(formats.first.map { CMFormatDescriptionGetMediaSubType($0) }, kCMVideoCodecType_HEVC)
    }
}
