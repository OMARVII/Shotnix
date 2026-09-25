import AppKit
import Foundation

/// Every export choice, persisted between exports.
struct VideoExportSettings: Equatable {
    enum Format: String, CaseIterable, Identifiable {
        case mp4
        case gif

        var id: String { rawValue }
        var title: String {
            switch self {
            case .mp4: return "MP4"
            case .gif: return "GIF"
            }
        }
    }

    /// Short side of the output, in pixels.
    enum Resolution: Int, CaseIterable, Identifiable {
        case p720 = 720
        case p1080 = 1080
        case p1440 = 1440
        case p2160 = 2160

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .p720: return "720p"
            case .p1080: return "1080p"
            case .p1440: return "1440p"
            case .p2160: return "4K"
            }
        }
    }

    enum Quality: String, CaseIterable, Identifiable {
        case web
        case social
        case studio

        var id: String { rawValue }
        var title: String {
            switch self {
            case .web: return "Web"
            case .social: return "Social"
            case .studio: return "Studio"
            }
        }
        var detail: String {
            switch self {
            case .web: return "Smallest files, great for docs and chat"
            case .social: return "Crisp and compact — the best default"
            case .studio: return "Maximum detail for further editing"
            }
        }
        /// Bits per pixel per frame at 30 fps (H.264).
        var bitsPerPixel: Double {
            switch self {
            case .web: return 0.055
            case .social: return 0.1
            case .studio: return 0.21
            }
        }
    }

    enum Codec: String, CaseIterable, Identifiable {
        case h264
        case hevc

        var id: String { rawValue }
        var title: String {
            switch self {
            case .h264: return "H.264"
            case .hevc: return "HEVC"
            }
        }
        var detail: String {
            switch self {
            case .h264: return "Plays everywhere"
            case .hevc: return "About 35% smaller, modern players"
            }
        }
    }

    enum GIFSize: Int, CaseIterable, Identifiable {
        case small = 480
        case medium = 720
        case large = 1080

        var id: Int { rawValue }
        var title: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }
    }

    var format: Format = .mp4
    var resolution: Resolution = .p1080
    var fps: Int = 60
    var quality: Quality = .social
    var codec: Codec = .h264
    var endCard: Bool = true
    var gifSize: GIFSize = .medium
    var gifFPS: Int = 15

    static let frameRates = [24, 30, 60]
    static let gifFrameRates = [10, 15, 20, 24]

    var fileExtension: String { format == .gif ? "gif" : "mp4" }
    var effectiveFrameRate: Int { format == .gif ? gifFPS : fps }

    /// Output pixel size for a canvas: the short side hits the chosen
    /// resolution (GIFs: the long side hits the chosen width).
    func outputSize(canvas: CGSize) -> CGSize {
        guard canvas.width > 0, canvas.height > 0 else { return CGSize(width: 1920, height: 1080) }
        func even(_ value: CGFloat) -> CGFloat {
            let rounded = max(2, Int(value.rounded()))
            return CGFloat(rounded.isMultiple(of: 2) ? rounded : rounded + 1)
        }
        if format == .gif {
            let long = CGFloat(gifSize.rawValue)
            let scale = long / max(canvas.width, canvas.height)
            return CGSize(width: even(canvas.width * scale), height: even(canvas.height * scale))
        }
        let short = CGFloat(resolution.rawValue)
        let scale = short / min(canvas.width, canvas.height)
        return CGSize(width: even(canvas.width * scale), height: even(canvas.height * scale))
    }

    func videoBitrate(for size: CGSize) -> Int {
        let pixels = Double(size.width * size.height)
        let fpsFactor = pow(Double(max(fps, 1)) / 30, 0.6)
        var bitrate = pixels * 30 * quality.bitsPerPixel * fpsFactor
        if codec == .hevc { bitrate *= 0.65 }
        return Int(min(max(bitrate, 1_500_000), 160_000_000))
    }

    /// Upper-bound size estimate (screen content usually lands well under).
    func estimatedBytes(duration: Double, canvas: CGSize, hasAudio: Bool) -> Int64 {
        let size = outputSize(canvas: canvas)
        let seconds = max(duration, 0) + (endCard && format == .mp4 ? VideoDemoExporter.endCardDuration : 0)
        if format == .gif {
            let frames = seconds * Double(gifFPS)
            return Int64(frames * Double(size.width * size.height) * 0.12)
        }
        let video = Double(videoBitrate(for: size)) * seconds / 8
        let audio = hasAudio ? 192_000.0 * seconds / 8 : 0
        return Int64(video + audio)
    }

    static var fromSettings: VideoExportSettings {
        var settings = VideoExportSettings()
        settings.format = Format(rawValue: Settings.videoExportFormat) ?? .mp4
        settings.fps = Settings.videoExportFPS
        settings.endCard = Settings.videoExportEndCard
        let defaults = UserDefaults.standard
        if let raw = defaults.object(forKey: "videoExportResolution") as? Int, let value = Resolution(rawValue: raw) {
            settings.resolution = value
        }
        if let raw = defaults.string(forKey: "videoExportQuality"), let value = Quality(rawValue: raw) {
            settings.quality = value
        }
        if let raw = defaults.string(forKey: "videoExportCodec"), let value = Codec(rawValue: raw) {
            settings.codec = value
        }
        if let raw = defaults.object(forKey: "videoExportGIFSize") as? Int, let value = GIFSize(rawValue: raw) {
            settings.gifSize = value
        }
        if let raw = defaults.object(forKey: "videoExportGIFFPS") as? Int, gifFrameRates.contains(raw) {
            settings.gifFPS = raw
        }
        return settings
    }

    func saveAsDefaults() {
        Settings.videoExportFormat = format.rawValue
        Settings.videoExportFPS = fps
        Settings.videoExportEndCard = endCard
        let defaults = UserDefaults.standard
        defaults.set(resolution.rawValue, forKey: "videoExportResolution")
        defaults.set(quality.rawValue, forKey: "videoExportQuality")
        defaults.set(codec.rawValue, forKey: "videoExportCodec")
        defaults.set(gifSize.rawValue, forKey: "videoExportGIFSize")
        defaults.set(gifFPS, forKey: "videoExportGIFFPS")
    }
}
