import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

struct VideoRGBA: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }

    init(nsColor: NSColor) {
        let color = nsColor.usingColorSpace(.sRGB) ?? nsColor
        r = Double(color.redComponent)
        g = Double(color.greenComponent)
        b = Double(color.blueComponent)
        a = Double(color.alphaComponent)
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var ciColor: CIColor { CIColor(red: r, green: g, blue: b, alpha: a, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? CIColor(red: r, green: g, blue: b, alpha: a) }

    func withAlpha(_ alpha: Double) -> VideoRGBA { VideoRGBA(r, g, b, alpha) }

    /// Perceived brightness 0...1 — picks legible ink over a background.
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}

/// What fills the canvas behind the recording.
enum VideoBackground: Codable, Equatable, Hashable {
    /// A built-in mesh-gradient wallpaper, by id.
    case wallpaper(String)
    /// A built-in linear gradient, by id.
    case gradient(String)
    case color(VideoRGBA)
    /// A picture the user chose.
    case image(String)
    /// A macOS desktop picture on this Mac.
    case systemWallpaper(String)

    var imageURL: URL? {
        switch self {
        case .image(let path), .systemWallpaper(let path):
            return path.isEmpty ? nil : URL(fileURLWithPath: path)
        default:
            return nil
        }
    }

    /// Rough brightness, for choosing contrasting chrome.
    var approximateLuminance: Double {
        switch self {
        case .wallpaper(let id):
            return VideoBackgroundCatalog.wallpaper(id: id)?.averageColor.luminance ?? 0.3
        case .gradient(let id):
            return VideoBackgroundCatalog.gradient(id: id)?.averageColor.luminance ?? 0.3
        case .color(let color):
            return color.luminance
        case .image, .systemWallpaper:
            return 0.4
        }
    }
}

/// A soft, vivid "mesh" wallpaper: a two-tone base washed with blurred
/// color blobs, then dithered with fine grain so 8-bit video never bands.
struct VideoMeshWallpaper: Identifiable {
    struct Blob {
        var x: Double
        var y: Double
        var radius: Double
        var color: VideoRGBA
    }

    var id: String
    var title: String
    var base: [VideoRGBA]
    /// Degrees; 0 = left to right, 90 = top to bottom.
    var angle: Double
    var blobs: [Blob]

    var averageColor: VideoRGBA {
        let colors = base + blobs.map(\.color)
        let count = Double(max(colors.count, 1))
        return VideoRGBA(
            colors.map(\.r).reduce(0, +) / count,
            colors.map(\.g).reduce(0, +) / count,
            colors.map(\.b).reduce(0, +) / count
        )
    }
}

struct VideoGradientPreset: Identifiable {
    var id: String
    var title: String
    var colors: [VideoRGBA]
    var angle: Double

    var averageColor: VideoRGBA {
        let count = Double(max(colors.count, 1))
        return VideoRGBA(
            colors.map(\.r).reduce(0, +) / count,
            colors.map(\.g).reduce(0, +) / count,
            colors.map(\.b).reduce(0, +) / count
        )
    }
}

enum VideoBackgroundCatalog {
    static let defaultBackground: VideoBackground = .wallpaper("aurora")

    static let wallpapers: [VideoMeshWallpaper] = [
        VideoMeshWallpaper(id: "aurora", title: "Aurora", base: [VideoRGBA(hex: 0x1B1B6B), VideoRGBA(hex: 0x3A1C71)], angle: 120, blobs: [
            .init(x: 0.15, y: 0.2, radius: 0.55, color: VideoRGBA(hex: 0x4F7CFF)),
            .init(x: 0.85, y: 0.15, radius: 0.5, color: VideoRGBA(hex: 0xC04BFF)),
            .init(x: 0.7, y: 0.9, radius: 0.6, color: VideoRGBA(hex: 0xFF6FB5)),
            .init(x: 0.2, y: 0.95, radius: 0.45, color: VideoRGBA(hex: 0x36D1DC)),
        ]),
        VideoMeshWallpaper(id: "sunset", title: "Sunset", base: [VideoRGBA(hex: 0xFF7E5F), VideoRGBA(hex: 0x6A3093)], angle: 100, blobs: [
            .init(x: 0.2, y: 0.15, radius: 0.55, color: VideoRGBA(hex: 0xFFC371)),
            .init(x: 0.9, y: 0.4, radius: 0.5, color: VideoRGBA(hex: 0xFF5E99)),
            .init(x: 0.35, y: 0.95, radius: 0.55, color: VideoRGBA(hex: 0x8E44AD)),
        ]),
        VideoMeshWallpaper(id: "lagoon", title: "Lagoon", base: [VideoRGBA(hex: 0x0B486B), VideoRGBA(hex: 0x0F9B8E)], angle: 135, blobs: [
            .init(x: 0.1, y: 0.1, radius: 0.5, color: VideoRGBA(hex: 0x2BC0E4)),
            .init(x: 0.9, y: 0.25, radius: 0.45, color: VideoRGBA(hex: 0x5EE7DF)),
            .init(x: 0.6, y: 0.95, radius: 0.6, color: VideoRGBA(hex: 0x1D5F9E)),
        ]),
        VideoMeshWallpaper(id: "citrus", title: "Citrus", base: [VideoRGBA(hex: 0xF7B733), VideoRGBA(hex: 0xFC4A1A)], angle: 90, blobs: [
            .init(x: 0.1, y: 0.2, radius: 0.5, color: VideoRGBA(hex: 0xFFE259)),
            .init(x: 0.85, y: 0.8, radius: 0.55, color: VideoRGBA(hex: 0xFF6A3D)),
            .init(x: 0.6, y: 0.1, radius: 0.4, color: VideoRGBA(hex: 0xFFB347)),
        ]),
        VideoMeshWallpaper(id: "blossom", title: "Blossom", base: [VideoRGBA(hex: 0xFBC2EB), VideoRGBA(hex: 0xA6C1EE)], angle: 120, blobs: [
            .init(x: 0.15, y: 0.25, radius: 0.5, color: VideoRGBA(hex: 0xFF9A9E)),
            .init(x: 0.85, y: 0.2, radius: 0.45, color: VideoRGBA(hex: 0xC2B6FF)),
            .init(x: 0.5, y: 0.95, radius: 0.55, color: VideoRGBA(hex: 0x9FD8FF)),
        ]),
        VideoMeshWallpaper(id: "nebula", title: "Nebula", base: [VideoRGBA(hex: 0x0F0C29), VideoRGBA(hex: 0x24243E)], angle: 135, blobs: [
            .init(x: 0.2, y: 0.3, radius: 0.5, color: VideoRGBA(hex: 0x6A11CB)),
            .init(x: 0.8, y: 0.7, radius: 0.55, color: VideoRGBA(hex: 0x2575FC)),
            .init(x: 0.95, y: 0.1, radius: 0.35, color: VideoRGBA(hex: 0xE94057)),
        ]),
        VideoMeshWallpaper(id: "meadow", title: "Meadow", base: [VideoRGBA(hex: 0x134E5E), VideoRGBA(hex: 0x71B280)], angle: 110, blobs: [
            .init(x: 0.15, y: 0.15, radius: 0.5, color: VideoRGBA(hex: 0xA8E063)),
            .init(x: 0.85, y: 0.35, radius: 0.45, color: VideoRGBA(hex: 0x56AB2F)),
            .init(x: 0.45, y: 0.95, radius: 0.55, color: VideoRGBA(hex: 0x1D976C)),
        ]),
        VideoMeshWallpaper(id: "ember", title: "Ember", base: [VideoRGBA(hex: 0x200122), VideoRGBA(hex: 0x6F0000)], angle: 130, blobs: [
            .init(x: 0.2, y: 0.8, radius: 0.55, color: VideoRGBA(hex: 0xF12711)),
            .init(x: 0.85, y: 0.25, radius: 0.5, color: VideoRGBA(hex: 0xF5AF19)),
            .init(x: 0.5, y: 0.2, radius: 0.35, color: VideoRGBA(hex: 0xB31217)),
        ]),
        VideoMeshWallpaper(id: "glacier", title: "Glacier", base: [VideoRGBA(hex: 0xE0EAFC), VideoRGBA(hex: 0xCFDEF3)], angle: 100, blobs: [
            .init(x: 0.15, y: 0.2, radius: 0.5, color: VideoRGBA(hex: 0xA1C4FD)),
            .init(x: 0.9, y: 0.75, radius: 0.55, color: VideoRGBA(hex: 0xC2E9FB)),
            .init(x: 0.6, y: 0.05, radius: 0.35, color: VideoRGBA(hex: 0xD4C1FF)),
        ]),
        VideoMeshWallpaper(id: "midnight", title: "Midnight", base: [VideoRGBA(hex: 0x0F2027), VideoRGBA(hex: 0x203A43)], angle: 125, blobs: [
            .init(x: 0.85, y: 0.15, radius: 0.5, color: VideoRGBA(hex: 0x2C5364)),
            .init(x: 0.15, y: 0.9, radius: 0.5, color: VideoRGBA(hex: 0x1A2980)),
            .init(x: 0.62, y: 0.58, radius: 0.5, color: VideoRGBA(hex: 0x26D0CE, alpha: 0.28)),
        ]),
        VideoMeshWallpaper(id: "peach", title: "Peach", base: [VideoRGBA(hex: 0xFFDDE1), VideoRGBA(hex: 0xFFC3A0)], angle: 110, blobs: [
            .init(x: 0.1, y: 0.8, radius: 0.5, color: VideoRGBA(hex: 0xFFAFBD)),
            .init(x: 0.9, y: 0.2, radius: 0.45, color: VideoRGBA(hex: 0xFFD89B)),
            .init(x: 0.55, y: 0.45, radius: 0.35, color: VideoRGBA(hex: 0xFDEFF9)),
        ]),
        VideoMeshWallpaper(id: "orchid", title: "Orchid", base: [VideoRGBA(hex: 0x41295A), VideoRGBA(hex: 0x2F0743)], angle: 140, blobs: [
            .init(x: 0.8, y: 0.2, radius: 0.55, color: VideoRGBA(hex: 0xDA22FF)),
            .init(x: 0.2, y: 0.85, radius: 0.5, color: VideoRGBA(hex: 0x9733EE)),
            .init(x: 0.1, y: 0.1, radius: 0.35, color: VideoRGBA(hex: 0xFF61D2)),
        ]),
    ]

    static let gradients: [VideoGradientPreset] = [
        VideoGradientPreset(id: "sky", title: "Sky", colors: [VideoRGBA(hex: 0x56CCF2), VideoRGBA(hex: 0x2F80ED)], angle: 135),
        VideoGradientPreset(id: "violet", title: "Violet", colors: [VideoRGBA(hex: 0x8E2DE2), VideoRGBA(hex: 0x4A00E0)], angle: 135),
        VideoGradientPreset(id: "flamingo", title: "Flamingo", colors: [VideoRGBA(hex: 0xF857A6), VideoRGBA(hex: 0xFF5858)], angle: 135),
        VideoGradientPreset(id: "tangerine", title: "Tangerine", colors: [VideoRGBA(hex: 0xF2994A), VideoRGBA(hex: 0xF2C94C)], angle: 135),
        VideoGradientPreset(id: "emerald", title: "Emerald", colors: [VideoRGBA(hex: 0x11998E), VideoRGBA(hex: 0x38EF7D)], angle: 135),
        VideoGradientPreset(id: "dusk", title: "Dusk", colors: [VideoRGBA(hex: 0x2C3E50), VideoRGBA(hex: 0xFD746C)], angle: 135),
        VideoGradientPreset(id: "iris", title: "Iris", colors: [VideoRGBA(hex: 0x667EEA), VideoRGBA(hex: 0x764BA2)], angle: 135),
        VideoGradientPreset(id: "mist", title: "Mist", colors: [VideoRGBA(hex: 0xF5F7FA), VideoRGBA(hex: 0xC3CFE2)], angle: 135),
        // Legacy presets (earlier drafts reference these ids).
        VideoGradientPreset(id: "graphite", title: "Graphite", colors: [VideoRGBA(0.05, 0.052, 0.06), VideoRGBA(0.12, 0.12, 0.14)], angle: 135),
        VideoGradientPreset(id: "ocean", title: "Ocean", colors: [VideoRGBA(0.02, 0.10, 0.16), VideoRGBA(0.00, 0.24, 0.30)], angle: 135),
        VideoGradientPreset(id: "plum", title: "Plum", colors: [VideoRGBA(0.14, 0.08, 0.18), VideoRGBA(0.24, 0.12, 0.24)], angle: 135),
        VideoGradientPreset(id: "linen", title: "Linen", colors: [VideoRGBA(0.91, 0.86, 0.76), VideoRGBA(0.80, 0.76, 0.67)], angle: 135),
        VideoGradientPreset(id: "pure", title: "Pure", colors: [VideoRGBA(1, 1, 1), VideoRGBA(0.90, 0.91, 0.93)], angle: 135),
        VideoGradientPreset(id: "mint", title: "Mint", colors: [VideoRGBA(0.72, 0.92, 0.84), VideoRGBA(0.32, 0.62, 0.72)], angle: 135),
    ]

    static let colors: [VideoRGBA] = [
        VideoRGBA(hex: 0xFFFFFF),
        VideoRGBA(hex: 0xF2F2F4),
        VideoRGBA(hex: 0xD9DCE3),
        VideoRGBA(hex: 0x1C1C1E),
        VideoRGBA(hex: 0x0A0A0B),
        VideoRGBA(hex: 0x2F6BFF),
        VideoRGBA(hex: 0x7C4DFF),
        VideoRGBA(hex: 0xFF4F8B),
        VideoRGBA(hex: 0xFF8A00),
        VideoRGBA(hex: 0xFFD60A),
        VideoRGBA(hex: 0x30D158),
        VideoRGBA(hex: 0x00C7BE),
    ]

    static func wallpaper(id: String) -> VideoMeshWallpaper? {
        wallpapers.first { $0.id == id }
    }

    static func gradient(id: String) -> VideoGradientPreset? {
        gradients.first { $0.id == id }
    }

    /// Gradients shown in the picker (legacy ids stay decodable but hidden).
    static var pickerGradients: [VideoGradientPreset] {
        gradients.filter { !["graphite", "ocean", "plum", "linen", "pure", "mint"].contains($0.id) }
    }

    // MARK: macOS desktop pictures

    /// Full-resolution desktop pictures present on this Mac: the current
    /// wallpaper first, then downloaded and built-in stills. Stub entries
    /// (.madesktop, not downloaded) are skipped.
    static func systemWallpapers() -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), FileManager.default.fileExists(atPath: path) else { return }
            let ext = url.pathExtension.lowercased()
            guard ["heic", "jpg", "jpeg", "png", "tif", "tiff"].contains(ext) else { return }
            seen.insert(path)
            urls.append(URL(fileURLWithPath: path))
        }

        for screen in NSScreen.screens {
            if let url = NSWorkspace.shared.desktopImageURL(for: screen) { add(url) }
        }
        let fileManager = FileManager.default
        let directories = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.mobileAssetDesktop", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true),
            URL(fileURLWithPath: "/Library/Desktop Pictures", isDirectory: true),
        ]
        for directory in directories {
            let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                // Tiny files are thumbnails or placeholders, not pictures.
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 200_000 { add(url) }
            }
        }
        return urls
    }
}

// MARK: - Rendering

/// Renders backgrounds as Core Image images at any size. Pure and
/// deterministic, so the preview and the export paint identical pixels.
enum VideoBackgroundRenderer {
    /// A background filling `size` (pixels, bottom-left origin).
    static func image(for background: VideoBackground, blur: Double, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        var image: CIImage
        switch background {
        case .wallpaper(let id):
            image = meshImage(VideoBackgroundCatalog.wallpaper(id: id) ?? VideoBackgroundCatalog.wallpapers[0], size: size)
        case .gradient(let id):
            let preset = VideoBackgroundCatalog.gradient(id: id) ?? VideoBackgroundCatalog.gradients[0]
            image = linearGradient(colors: preset.colors, angle: preset.angle, size: size)
        case .color(let color):
            image = CIImage(color: color.withAlpha(1).ciColor).cropped(to: rect)
        case .image(let path), .systemWallpaper(let path):
            if let picture = loadPicture(path: path, fitting: size) {
                image = aspectFill(picture, into: size)
            } else {
                image = meshImage(VideoBackgroundCatalog.wallpapers[0], size: size)
            }
        }

        if blur > 0.01 {
            let radius = blur * Double(min(size.width, size.height)) * 0.045
            image = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: rect)
        }
        return dithered(image, size: size)
    }

    private static func meshImage(_ wallpaper: VideoMeshWallpaper, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        var image = linearGradient(colors: wallpaper.base, angle: wallpaper.angle, size: size)
        let scale = Double(max(size.width, size.height))
        for blob in wallpaper.blobs {
            let center = CIVector(x: CGFloat(blob.x) * size.width, y: (1 - CGFloat(blob.y)) * size.height)
            let gradient = CIFilter.radialGradient()
            gradient.center = CGPoint(x: center.x, y: center.y)
            gradient.radius0 = 0
            gradient.radius1 = Float(blob.radius * scale)
            gradient.color0 = blob.color.withAlpha(0.85 * blob.color.a).ciColor
            gradient.color1 = blob.color.withAlpha(0).ciColor
            guard let blobImage = gradient.outputImage?.cropped(to: rect) else { continue }
            image = blobImage.composited(over: image)
        }
        // A wide blur melts the radial cones into a smooth mesh.
        let sigma = Double(min(size.width, size.height)) * 0.06
        return image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: rect)
    }

    /// Multi-stop linear gradient, drawn with Core Graphics (exact stops,
    /// any count) and handed to Core Image.
    private static func linearGradient(colors: [VideoRGBA], angle: Double, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let stops = colors.isEmpty ? [VideoRGBA(0.1, 0.1, 0.12)] : colors
        let width = max(Int(size.width.rounded()), 1)
        let height = max(Int(size.height.rounded()), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return CIImage(color: stops[0].ciColor).cropped(to: rect)
        }
        let cgColors = stops.map { CGColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: $0.a) } as CFArray
        let locations: [CGFloat] = stops.count == 1 ? [0] : (0..<stops.count).map { CGFloat($0) / CGFloat(stops.count - 1) }
        guard let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: locations) else {
            return CIImage(color: stops[0].ciColor).cropped(to: rect)
        }
        let radians = angle * .pi / 180
        // Angle measured with y DOWN (like CSS); the bitmap context is y up.
        let dx = cos(radians)
        let dy = -sin(radians)
        let half = 0.5 * (abs(dx) * Double(width) + abs(dy) * Double(height))
        let center = CGPoint(x: Double(width) / 2, y: Double(height) / 2)
        let start = CGPoint(x: center.x - CGFloat(dx * half), y: center.y - CGFloat(dy * half))
        let end = CGPoint(x: center.x + CGFloat(dx * half), y: center.y + CGFloat(dy * half))
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        guard let cgImage = context.makeImage() else {
            return CIImage(color: stops[0].ciColor).cropped(to: rect)
        }
        return CIImage(cgImage: cgImage)
    }

    private static func aspectFill(_ image: CIImage, into size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = max(size.width / extent.width, size.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let x = (size.width - extent.width * scale) / 2 - extent.minX * scale
        let y = (size.height - extent.height * scale) / 2 - extent.minY * scale
        return scaled.transformed(by: CGAffineTransform(translationX: x, y: y))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// ±1/255 grain: invisible, but it breaks up the steps an 8-bit encoder
    /// would otherwise carve into smooth gradients.
    private static func dithered(_ image: CIImage, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }
        let grain = noise
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.008, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.008, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.008, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -0.004, y: -0.004, z: -0.004, w: 0),
            ])
            .cropped(to: rect)
        return grain.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: rect)
    }

    // MARK: Picture loading

    private static let pictureCache = NSCache<NSString, CIImage>()

    /// Decodes a picture no larger than needed (6K HEIC wallpapers decode in
    /// a fraction of the time at 4K).
    static func loadPicture(path: String, fitting size: CGSize) -> CIImage? {
        let bucket = max(size.width, size.height) > 2200 ? 4096 : 2304
        let key = "\(path)#\(bucket)" as NSString
        if let cached = pictureCache.object(forKey: key) { return cached }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: bucket,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        let image = CIImage(cgImage: cgImage)
        pictureCache.setObject(image, forKey: key)
        return image
    }

    /// Small picker thumbnail.
    static func thumbnail(path: String, maxPixel: Int = 240) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
