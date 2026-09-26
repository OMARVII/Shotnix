import AppKit
import AVFoundation
import CoreImage
import XCTest
@testable import ShotnixCore

/// Looks inside exported files: frames (pixel colors) and sound (levels,
/// and how much of one pitch is in it) — plus small media makers.
enum VideoInspection {
    // MARK: Frames

    /// The frame showing at `time` seconds, upright.
    static func frame(of url: URL, at time: Double) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
    }

    /// Average sRGB color (0…1) of a box around a point given as fractions
    /// of the frame (top-left origin).
    static func color(of image: CGImage, x: Double, y: Double, radius: Int = 3) -> (r: Double, g: Double, b: Double) {
        let width = image.width
        let height = image.height
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let cx = min(max(Int(x * Double(width)), 0), width - 1)
        let cy = min(max(Int(y * Double(height)), 0), height - 1)
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for py in max(cy - radius, 0)...min(cy + radius, height - 1) {
            for px in max(cx - radius, 0)...min(cx + radius, width - 1) {
                // Bitmap rows run top to bottom in memory.
                let index = (py * width + px) * 4
                r += Double(pixels[index]); g += Double(pixels[index + 1]); b += Double(pixels[index + 2]); n += 1
            }
        }
        return (r / n / 255, g / n / 255, b / n / 255)
    }

    /// Same, on a rendered CIImage of `size` (bottom-left CI origin handled).
    static func color(of image: CIImage, size: CGSize, x: Double, y: Double) -> (r: Double, g: Double, b: Double) {
        let cgImage = VideoRenderContext.shared.createCGImage(image, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
        return color(of: cgImage, x: x, y: y)
    }

    static func isClose(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double), tolerance: Double = 0.1) -> Bool {
        abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
    }

    // MARK: Sound

    /// The file's sound as mono floats.
    static func audio(of url: URL, sampleRate: Double = 48_000) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var tracks: [AVAssetTrack] = []
        asset.loadTracks(withMediaType: .audio) { loaded, _ in
            tracks = loaded ?? []
            semaphore.signal()
        }
        semaphore.wait()
        guard !tracks.isEmpty else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
            }
        }
        return samples
    }

    static func rms(_ samples: [Float], from: Double, to: Double, rate: Double = 48_000) -> Double {
        let a = max(Int(from * rate), 0)
        let b = min(Int(to * rate), samples.count)
        guard b > a else { return 0 }
        var sum = 0.0
        for index in a..<b { sum += Double(samples[index] * samples[index]) }
        return (sum / Double(b - a)).squareRoot()
    }

    /// Amplitude of one frequency in a stretch (Goertzel), about the
    /// sine's peak amplitude.
    static func toneLevel(_ samples: [Float], frequency: Double, from: Double, to: Double, rate: Double = 48_000) -> Double {
        let a = max(Int(from * rate), 0)
        let b = min(Int(to * rate), samples.count)
        guard b > a else { return 0 }
        let n = Double(b - a)
        let omega = 2 * Double.pi * frequency / rate
        let coefficient = 2 * cos(omega)
        var s1 = 0.0, s2 = 0.0
        for index in a..<b {
            let s0 = Double(samples[index]) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
        return 2 * power.squareRoot() / n
    }

    // MARK: Makers

    /// A sine tone file (AAC in .m4a).
    static func writeTone(to url: URL, frequency: Double, seconds: Double, amplitude: Double = 0.5) throws {
        try? FileManager.default.removeItem(at: url)
        let rate = 48_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            data[index] = Float(sin(Double(index) / rate * 2 * .pi * frequency) * amplitude)
        }
        try file.write(from: buffer)
    }

    /// A PNG of one color (with alpha).
    static func writePNG(to url: URL, size: CGSize, color: NSColor) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.usingColorSpace(.sRGB)!.setFill()
        CGRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    /// A video of solid colors, one after another (`sRGB`, tagged), with
    /// optional sound: a tone during `toneSeconds` at the start.
    static func writeColorVideo(to url: URL, size: CGSize, colors: [(NSColor, Double)], fps: Int = 30, toneSeconds: Double? = nil, toneFrequency: Double = 440) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        var audioInput: AVAssetWriterInput?
        if toneSeconds != nil {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ])
            audio.expectsMediaDataInRealTime = false
            writer.add(audio)
            audioInput = audio
        }
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "test", code: 1) }
        writer.startSession(atSourceTime: .zero)
        let audioTask: Task<Void, Error>? = {
            guard let audioInput, let toneSeconds else { return nil }
            let box = InputBox(audioInput)
            return Task.detached {
                try await appendTone(to: box.input, seconds: toneSeconds, frequency: toneFrequency)
                box.input.markAsFinished()
            }
        }()
        var frame = 0
        for (color, seconds) in colors {
            let count = Int((seconds * Double(fps)).rounded())
            let rgb = color.usingColorSpace(.sRGB)!
            for _ in 0..<count {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
                let pixels = buffer!
                CVBufferSetAttachment(pixels, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
                CVPixelBufferLockBaseAddress(pixels, [])
                let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                context.setFillColor(rgb.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
                CVPixelBufferUnlockBaseAddress(pixels, [])
                adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
                frame += 1
            }
        }
        input.markAsFinished()
        try await audioTask?.value
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "test", code: 2) }
    }

    private static func appendTone(to input: AVAssetWriterInput, seconds: Double, frequency: Double) async throws {
        let rate = 48_000.0
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let total = Int(seconds * rate)
        var written = 0
        while written < total {
            let frames = min(4800, total - written)
            var samples = [Int16](repeating: 0, count: frames)
            for i in 0..<frames { samples[i] = Int16(sin(Double(written + i) / rate * 2 * .pi * frequency) * 12_000) }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * 2, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: frames * 2, flags: 0, blockBufferOut: &block)
            samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: frames * 2) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames, presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(rate)), packetDescriptions: nil, sampleBufferOut: &sample)
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            input.append(sample!)
            written += frames
        }
    }

    /// A plain project for a color video (no padding surprises: a known
    /// background and the recording filling a known stage).
    static func project(for url: URL, seconds: Double, size: CGSize) -> VideoDemoProject {
        var project = VideoDemoProject.make(sourceURL: url, duration: seconds, sourceSize: size)
        project.aspectPreset = .source
        project.padding = 0
        project.cursor.visible = false
        project.audio.normalizeLoudness = false
        return project
    }

    static func mp4Settings(fps: Int = 30) -> VideoExportSettings {
        var settings = VideoExportSettings()
        settings.resolution = .p720
        settings.fps = fps
        settings.endCard = false
        return settings
    }
}

private final class InputBox: @unchecked Sendable {
    let input: AVAssetWriterInput
    init(_ input: AVAssetWriterInput) { self.input = input }
}
