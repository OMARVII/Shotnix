import AVFoundation
import VideoToolbox

/// How a recording is encoded. H.264 plays everywhere but stops around 4K
/// (level 5.2, and Apple's hardware encoder takes at most 4096 pixels a
/// side), so 5K, 6K and "More Space" displays switch to HEVC. Only a Mac
/// without an HEVC encoder gets a scaled-down H.264 file instead.
struct RecordingVideoFormat: Equatable {
    enum Codec: Equatable {
        case h264
        case hevc
    }

    let codec: Codec
    let width: Int
    let height: Int

    static func plan(width: Int, height: Int, fps: Int, hevcAvailable: Bool = hevcEncoderAvailable) -> RecordingVideoFormat {
        if fitsH264(width: width, height: height, fps: fps) {
            return RecordingVideoFormat(codec: .h264, width: width, height: height)
        }
        if hevcAvailable, fitsHEVC(width: width, height: height) {
            return RecordingVideoFormat(codec: .hevc, width: width, height: height)
        }
        let scaled = scaledToFitH264(width: width, height: height, fps: fps)
        return RecordingVideoFormat(codec: .h264, width: scaled.width, height: scaled.height)
    }

    /// Level 5.2: 36,864 macroblocks a frame and 2,073,600 a second.
    static func fitsH264(width: Int, height: Int, fps: Int) -> Bool {
        let macroblocks = ((width + 15) / 16) * ((height + 15) / 16)
        return width <= 4096 && height <= 4096
            && macroblocks <= 36_864
            && macroblocks * max(fps, 1) <= 2_073_600
    }

    /// The hardware HEVC encoder on Apple silicon goes up to 8K a side.
    static func fitsHEVC(width: Int, height: Int) -> Bool {
        width <= 8192 && height <= 8192
    }

    /// The largest even size with the same shape that H.264 accepts.
    static func scaledToFitH264(width: Int, height: Int, fps: Int) -> (width: Int, height: Int) {
        let w = Double(max(width, 2))
        let h = Double(max(height, 2))
        let maxArea = Double(min(36_864, 2_073_600 / max(fps, 1)) * 256)
        var scale = min(1, 4096 / w, 4096 / h, (maxArea / (w * h)).squareRoot())
        while scale > 0.05 {
            let scaledWidth = max(2, Int(w * scale) & ~1)
            let scaledHeight = max(2, Int(h * scale) & ~1)
            if fitsH264(width: scaledWidth, height: scaledHeight, fps: fps) {
                return (scaledWidth, scaledHeight)
            }
            scale *= 0.99
        }
        return (1280, 720)
    }

    /// Whether this Mac encodes HEVC in hardware (every Apple silicon Mac does).
    static let hevcEncoderAvailable: Bool = {
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        var encoderID: CFString?
        var properties: CFDictionary?
        return VTCopySupportedPropertyDictionaryForEncoder(
            width: 3840,
            height: 2160,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: specification,
            encoderIDOut: &encoderID,
            supportedPropertiesOut: &properties
        ) == noErr
    }()

    /// Frames waiting for the encoder, capped by memory: eight full-size 5K
    /// frames alone would hold almost half a gigabyte.
    static func queueDepth(width: Int, height: Int) -> Int {
        let frameBytes = max(width * height * 4, 1)
        return min(max(300_000_000 / frameBytes, 3), 6)
    }
}

extension RecordingQuality {
    /// Frames 1/60 s apart differ less than frames 1/30 s apart, so bits grow
    /// with fps^0.75 rather than linearly: 60 fps gets about 1.7× the bitrate
    /// of 30 — ceiling included, so big displays aren't starved at 60.
    static func frameRateFactor(fps: Int) -> Double {
        pow(Double(Swift.max(fps, 1)) / 30, 0.75)
    }

    func bitrate(width: Int, height: Int, fps: Int, codec: RecordingVideoFormat.Codec = .h264) -> Int {
        // HEVC keeps the same detail in roughly 70% of the bits.
        let factor = Self.frameRateFactor(fps: fps) * (codec == .hevc ? 0.7 : 1)
        let pixels = Double(Swift.max(width, 1) * Swift.max(height, 1))
        let raw = pixels * 30 * bitsPerPixelPerFrame * factor
        let floor = Double(minimumBitrate) * factor
        let ceiling = Double(maximumBitrate) * factor
        return Int(Swift.min(Swift.max(raw, floor), ceiling).rounded())
    }
}

/// What a minute of recording costs on disk, for the recording bar and Settings.
enum RecordingSizeEstimate {
    static let microphoneBitrate = 128_000
    static let systemAudioBitrate = 192_000

    static func bytesPerMinute(videoBitrate: Int, systemAudio: Bool, microphone: Bool) -> Int64 {
        let bits = Int64(videoBitrate)
            + (systemAudio ? Int64(systemAudioBitrate) : 0)
            + (microphone ? Int64(microphoneBitrate) : 0)
        return bits * 60 / 8
    }

    /// Screen content usually compresses below the target bitrate, so this
    /// is an upper bound.
    static func bytesPerMinute(pixelWidth: Int, pixelHeight: Int, fps: Int, quality: RecordingQuality, systemAudio: Bool, microphone: Bool) -> Int64 {
        let format = RecordingVideoFormat.plan(width: pixelWidth, height: pixelHeight, fps: fps)
        let bitrate = quality.bitrate(width: format.width, height: format.height, fps: fps, codec: format.codec)
        return bytesPerMinute(videoBitrate: bitrate, systemAudio: systemAudio, microphone: microphone)
    }

    /// "up to 480 MB/min" (whole megabytes; gigabytes to one decimal).
    static func label(bytesPerMinute: Int64) -> String {
        let gigabytes = bytesPerMinute >= 1_000_000_000
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = gigabytes ? 1 : 0
        let value = Double(bytesPerMinute) / (gigabytes ? 1_000_000_000 : 1_000_000)
        let number = formatter.string(from: NSNumber(value: value)) ?? "\(Int(value.rounded()))"
        return "up to \(number) \(gigabytes ? "GB" : "MB")/min"
    }
}

/// Free space a recording needs. It starts only with room to spare and,
/// rather than letting the writer die on a full disk, stops itself while
/// there's still enough left to finish the file.
enum RecordingDiskSpace {
    static let minimumToStart: Int64 = 500 * 1_024 * 1_024

    /// Room to finish writing (movie index, camera file, editor data) plus
    /// 20 s at the current rate, because space is checked every few seconds.
    static func stopThreshold(bytesPerSecond: Int64) -> Int64 {
        200 * 1_024 * 1_024 + max(bytesPerSecond, 0) * 20
    }

    /// About a minute before the stop.
    static func warningThreshold(bytesPerSecond: Int64) -> Int64 {
        stopThreshold(bytesPerSecond: bytesPerSecond) + max(bytesPerSecond, 0) * 60
    }

    /// nil when the volume can't be asked; let the writer surface the real error then.
    static func availableCapacity(at directory: URL) -> Int64? {
        try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }
}
