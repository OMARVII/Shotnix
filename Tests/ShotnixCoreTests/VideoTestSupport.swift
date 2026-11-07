import AppKit
import AVFoundation
import CoreImage
import XCTest
@testable import ShotnixCore

/// Synthesizes realistic screen recordings for editor tests: a fake macOS
/// app window (sidebar, headings, body text, controls) plus a scripted,
/// human-like pointer path with clicks.
enum VideoTestSupport {
    /// A fake app window on a desktop, drawn at `size` pixels.
    static func fakeScreen(size: CGSize, progress: Double = 0, typed: String = "") -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let unit = size.width / 1440
        // Flip to top-left drawing.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        // Desktop.
        NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.20, blue: 0.34, alpha: 1), NSColor(srgbRed: 0.35, green: 0.22, blue: 0.40, alpha: 1)])!
            .draw(in: CGRect(origin: .zero, size: size), angle: 90)

        // Window.
        let window = CGRect(x: 90 * unit, y: 60 * unit, width: 1260 * unit, height: 790 * unit)
        let windowPath = NSBezierPath(roundedRect: window, xRadius: 12 * unit, yRadius: 12 * unit)
        NSColor(white: 0.985, alpha: 1).setFill()
        windowPath.fill()
        // Title bar.
        NSColor(white: 0.93, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: window.minX, y: window.minY, width: window.width, height: 52 * unit), xRadius: 12 * unit, yRadius: 12 * unit).fill()
        NSColor(white: 0.93, alpha: 1).setFill()
        CGRect(x: window.minX, y: window.minY + 30 * unit, width: window.width, height: 22 * unit).fill()
        for (index, color) in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: window.minX + (20 + CGFloat(index) * 22) * unit, y: window.minY + 19 * unit, width: 13 * unit, height: 13 * unit)).fill()
        }
        draw("Acme Studio — Project Settings", at: CGPoint(x: window.midX - 150 * unit, y: window.minY + 16 * unit), size: 14 * unit, weight: .semibold, color: NSColor(white: 0.3, alpha: 1))

        // Sidebar.
        let sidebar = CGRect(x: window.minX, y: window.minY + 52 * unit, width: 250 * unit, height: window.height - 52 * unit)
        NSColor(white: 0.955, alpha: 1).setFill()
        sidebar.fill()
        let items = ["General", "Appearance", "Notifications", "Privacy & Security", "Integrations", "Billing", "Team Members", "Advanced"]
        for (index, item) in items.enumerated() {
            let y = sidebar.minY + (28 + CGFloat(index) * 40) * unit
            if index == 1 {
                NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: CGRect(x: sidebar.minX + 12 * unit, y: y - 8 * unit, width: sidebar.width - 24 * unit, height: 32 * unit), xRadius: 7 * unit, yRadius: 7 * unit).fill()
            }
            NSColor(white: index == 1 ? 1 : 0.55, alpha: 1).setFill()
            NSBezierPath(roundedRect: CGRect(x: sidebar.minX + 26 * unit, y: y, width: 16 * unit, height: 16 * unit), xRadius: 4 * unit, yRadius: 4 * unit).fill()
            draw(item, at: CGPoint(x: sidebar.minX + 54 * unit, y: y - 1 * unit), size: 14 * unit, weight: .medium, color: index == 1 ? .white : NSColor(white: 0.2, alpha: 1))
        }

        // Content.
        let content = CGRect(x: sidebar.maxX + 48 * unit, y: window.minY + 90 * unit, width: window.maxX - sidebar.maxX - 96 * unit, height: 600 * unit)
        draw("Appearance", at: CGPoint(x: content.minX, y: content.minY), size: 30 * unit, weight: .bold, color: NSColor(white: 0.1, alpha: 1))
        draw("Choose how Acme Studio looks on your Mac. Changes apply to every workspace you own and sync to your other devices.", at: CGPoint(x: content.minX, y: content.minY + 50 * unit), size: 14 * unit, weight: .regular, color: NSColor(white: 0.4, alpha: 1), width: content.width)

        let rows = ["Theme", "Accent color", "Sidebar icon size", "Show scroll bars", "Reduce motion"]
        for (index, row) in rows.enumerated() {
            let y = content.minY + (130 + CGFloat(index) * 62) * unit
            NSColor(white: 0.9, alpha: 1).setFill()
            CGRect(x: content.minX, y: y + 46 * unit, width: content.width, height: 1 * unit).fill()
            draw(row, at: CGPoint(x: content.minX, y: y + 10 * unit), size: 15 * unit, weight: .medium, color: NSColor(white: 0.15, alpha: 1))
            // Toggle.
            let on = index % 2 == 0
            let toggle = CGRect(x: content.maxX - 52 * unit, y: y + 8 * unit, width: 44 * unit, height: 26 * unit)
            (on ? NSColor.systemGreen : NSColor(white: 0.82, alpha: 1)).setFill()
            NSBezierPath(roundedRect: toggle, xRadius: 13 * unit, yRadius: 13 * unit).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: on ? toggle.maxX - 24 * unit : toggle.minX + 2 * unit, y: toggle.minY + 2 * unit, width: 22 * unit, height: 22 * unit)).fill()
        }

        // Text field (typed text grows over time).
        let field = CGRect(x: content.minX, y: content.minY + 460 * unit, width: content.width * 0.62, height: 36 * unit)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: field, xRadius: 7 * unit, yRadius: 7 * unit).fill()
        NSColor(white: 0.78, alpha: 1).setStroke()
        let fieldPath = NSBezierPath(roundedRect: field, xRadius: 7 * unit, yRadius: 7 * unit)
        fieldPath.lineWidth = 1 * unit
        fieldPath.stroke()
        draw(typed.isEmpty ? "Workspace name" : typed, at: CGPoint(x: field.minX + 12 * unit, y: field.minY + 9 * unit), size: 14 * unit, weight: .regular, color: typed.isEmpty ? NSColor(white: 0.65, alpha: 1) : NSColor(white: 0.1, alpha: 1))

        // Progress bar.
        let bar = CGRect(x: content.minX, y: content.minY + 530 * unit, width: content.width * 0.62, height: 8 * unit)
        NSColor(white: 0.9, alpha: 1).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 4 * unit, yRadius: 4 * unit).fill()
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(min(max(progress, 0), 1)), height: bar.height), xRadius: 4 * unit, yRadius: 4 * unit).fill()

        // Button.
        let button = CGRect(x: content.maxX - 150 * unit, y: content.minY + 510 * unit, width: 150 * unit, height: 38 * unit)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: button, xRadius: 8 * unit, yRadius: 8 * unit).fill()
        draw("Save Changes", at: CGPoint(x: button.minX + 26 * unit, y: button.minY + 10 * unit), size: 14 * unit, weight: .semibold, color: .white)

        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, width: CGFloat? = nil) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        if let width {
            string.draw(with: CGRect(x: point.x, y: point.y, width: width, height: size * 4), options: [.usesLineFragmentOrigin])
        } else {
            string.draw(at: point)
        }
    }

    // MARK: Scripted pointer

    struct Waypoint {
        var x: Double
        var y: Double
        /// Time the pointer arrives.
        var arrive: Double
        var click: Bool
        var hold: Double = 0.1
    }

    /// Points of interest on the fake screen (video-normalized, y down).
    static let demoWaypoints: [Waypoint] = [
        Waypoint(x: 0.55, y: 0.55, arrive: 0.0, click: false),
        Waypoint(x: 0.15, y: 0.285, arrive: 1.4, click: true),
        Waypoint(x: 0.785, y: 0.33, arrive: 3.2, click: true),
        Waypoint(x: 0.785, y: 0.47, arrive: 4.3, click: true),
        Waypoint(x: 0.45, y: 0.69, arrive: 6.0, click: true),
        Waypoint(x: 0.46, y: 0.70, arrive: 8.4, click: false),
        Waypoint(x: 0.82, y: 0.735, arrive: 9.6, click: true, hold: 0.18),
        Waypoint(x: 0.7, y: 0.5, arrive: 11.0, click: false),
    ]

    static func scriptedPointer(waypoints: [Waypoint] = demoWaypoints, duration: Double, rate: Double = 60) -> ([VideoDemoCursorSample], [VideoDemoClickEvent]) {
        var samples: [VideoDemoCursorSample] = []
        var clicks: [VideoDemoClickEvent] = []
        let count = Int(duration * rate)
        for index in 0...count {
            let t = Double(index) / rate
            var point = CGPoint(x: waypoints[0].x, y: waypoints[0].y)
            for pair in zip(waypoints, waypoints.dropFirst()) {
                let (a, b) = pair
                // Leave a beat after arriving, then travel.
                let leave = a.arrive + 0.35
                if t >= a.arrive && t < leave {
                    point = CGPoint(x: a.x, y: a.y)
                } else if t >= leave && t < b.arrive {
                    let u = (t - leave) / max(b.arrive - leave, 0.01)
                    let eased = u * u * (3 - 2 * u)
                    // Slight arc like a real hand.
                    let arc = sin(u * .pi) * 0.03
                    point = CGPoint(x: a.x + (b.x - a.x) * eased, y: a.y + (b.y - a.y) * eased - arc)
                } else if t >= b.arrive {
                    point = CGPoint(x: b.x, y: b.y)
                }
            }
            // Hand tremor.
            let jitter = 0.0006
            point.x += sin(t * 37) * jitter
            point.y += cos(t * 29) * jitter
            samples.append(VideoDemoCursorSample(time: t, x: point.x, y: point.y))
        }
        for waypoint in waypoints where waypoint.click {
            clicks.append(VideoDemoClickEvent(time: waypoint.arrive + 0.12, x: waypoint.x, y: waypoint.y, button: .left, endTime: waypoint.arrive + 0.12 + waypoint.hold))
        }
        return (samples, clicks)
    }

    // MARK: Video synthesis

    /// Writes a screen-recording-like MP4 (fake app, progress bar moving,
    /// text being typed) and returns its URL.
    static func writeFakeRecording(to url: URL, size: CGSize, seconds: Double, fps: Int = 30, audioSeconds: Double? = nil) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var audioInput: AVAssetWriterInput?
        if audioSeconds != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "test", code: 1) }
        writer.startSession(atSourceTime: .zero)

        // Audio is pumped concurrently: AVAssetWriter interleaves, so a
        // video-then-audio sequence would stall waiting for audio.
        let audioTask: Task<Void, Error>? = {
            guard let audioInput, let audioSeconds else { return nil }
            let box = WriterInputBox(audioInput)
            return Task.detached {
                try await appendTone(to: box.input, seconds: audioSeconds)
                box.input.markAsFinished()
            }
        }()

        let frames = max(Int(seconds * Double(fps)), 2)
        let phrase = "Acme Design Team"
        var cache: [String: CGImage] = [:]
        for frame in 0..<frames {
            let t = Double(frame) / Double(fps)
            let typedCount = t > 6.2 ? min(Int((t - 6.2) * 8), phrase.count) : 0
            let typed = String(phrase.prefix(typedCount))
            let progress = (t / seconds * 20).rounded() / 20
            let key = "\(typed)|\(progress)"
            let image = cache[key] ?? fakeScreen(size: size, progress: progress, typed: typed)
            cache[key] = image
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "test", code: 2) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw NSError(domain: "test", code: 3) }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
            context?.draw(image, in: CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        try await audioTask?.value
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? NSError(domain: "test", code: 4) }
    }

    /// A 440 Hz tone as 16-bit mono PCM chunks.
    private static func appendTone(to input: AVAssetWriterInput, seconds: Double) async throws {
        let rate = 48_000.0
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard let format else { throw NSError(domain: "test", code: 6) }
        let total = Int(seconds * rate)
        let chunk = 4800
        var written = 0
        while written < total {
            let frames = min(chunk, total - written)
            var samples = [Int16](repeating: 0, count: frames)
            for i in 0..<frames {
                samples[i] = Int16(sin(Double(written + i) / rate * 2 * .pi * 440) * 8000)
            }
            var block: CMBlockBuffer?
            let length = frames * 2
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block)
            guard let block else { throw NSError(domain: "test", code: 7) }
            samples.withUnsafeBytes { raw in
                _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
            }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames, presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(rate)), packetDescriptions: nil, sampleBufferOut: &sample)
            guard let sample else { throw NSError(domain: "test", code: 8) }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            input.append(sample)
            written += frames
        }
    }

    /// Captured pointer shapes, when the environment can provide one.
    /// A stereo tone file in `directory`, with optional clicks (a few loud
    /// samples) at the given seconds.
    static func writeTone(in directory: URL, amplitude: Double, frequency: Double, seconds: Double, clicks: [Double] = [], clickLevel: Float = 0.5) throws -> URL {
        let url = directory.appendingPathComponent("tone-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let value = Float(sin(2 * .pi * frequency * Double(frame) / 48_000) * amplitude)
            buffer.floatChannelData![0][frame] = value
            buffer.floatChannelData![1][frame] = value
        }
        for click in clicks {
            let at = Int(click * 48_000)
            for frame in at..<min(at + 24, Int(frames)) {
                let value = frame % 2 == 0 ? clickLevel : -clickLevel
                buffer.floatChannelData![0][frame] = value
                buffer.floatChannelData![1][frame] = value
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// A recording with a picture and one sound track per tone (the voice
    /// first, then the computer's sound), written as `url`.
    static func writeRecording(to url: URL, seconds: Double, tones: [URL]) async throws {
        let video = url.deletingLastPathComponent().appendingPathComponent("picture-\(UUID().uuidString).mp4")
        try await writeFakeRecording(to: video, size: CGSize(width: 320, height: 200), seconds: seconds, fps: 30)
        let composition = AVMutableComposition()
        let asset = AVURLAsset(url: video)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let source = try XCTUnwrap(videoTracks.first)
        let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        try track.insertTimeRange(range, of: source, at: .zero)
        var keep: [AVURLAsset] = [asset]
        for tone in tones {
            let toneAsset = AVURLAsset(url: tone)
            keep.append(toneAsset)
            let audioTracks = try await toneAsset.loadTracks(withMediaType: .audio)
            let audio = try XCTUnwrap(audioTracks.first)
            let lane = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try lane.insertTimeRange(range, of: audio, at: .zero)
        }
        let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        session.outputURL = url
        session.outputFileType = .mov
        await session.export()
        XCTAssertEqual(session.status, .completed, session.error?.localizedDescription ?? "")
        withExtendedLifetime(keep) {}
    }

    /// Interleaved stereo 48 kHz float sound of a file's (mixed) tracks.
    static func readSound(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let count = CMBlockBufferGetDataLength(block) / 4
            let start = samples.count
            samples += [Float](repeating: 0, count: count)
            _ = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress! + start * 4) }
        }
        return samples
    }

    static func currentCursorShape() -> VideoCursorShape? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        let reps = cursor.image.representations.compactMap { $0 as? NSBitmapImageRep }
        guard let largest = reps.max(by: { $0.pixelsWide < $1.pixelsWide }),
              let png = largest.representation(using: .png, properties: [:]) else { return nil }
        return VideoCursorShape(
            id: "test-arrow",
            hotSpotX: cursor.hotSpot.x,
            hotSpotY: cursor.hotSpot.y,
            width: cursor.image.size.width,
            height: cursor.image.size.height,
            pngData: png
        )
    }

    static func writePNG(_ image: CIImage, size: CGSize, to url: URL) throws {
        let context = VideoRenderContext.shared
        guard let cgImage = context.createCGImage(image, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw NSError(domain: "test", code: 5)
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}

private final class WriterInputBox: @unchecked Sendable {
    let input: AVAssetWriterInput
    init(_ input: AVAssetWriterInput) { self.input = input }
}
