import AppKit

/// How a capture was taken — shown on history cards and used by the
/// history type filter.
enum CaptureType: String, Codable, CaseIterable {
    case area
    case window
    case fullscreen
    case scrolling
    case text

    var title: String {
        switch self {
        case .area: return "Area"
        case .window: return "Window"
        case .fullscreen: return "Fullscreen"
        case .scrolling: return "Scrolling"
        case .text: return "Text"
        }
    }
}

struct HistoryItem: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let imagePath: String     // Full-res PNG on disk
    let thumbnailPath: String // Smaller PNG for list UI
    let captureRect: CodableRect?
    /// Text recognized in the capture (Vision OCR), used for history search.
    /// nil = not indexed yet; "" = indexed, no text found (never re-OCRed).
    /// Optional so index.json files written before this field existed still decode.
    var ocrText: String? = nil
    /// Raw CaptureType. Stored as a String, not the enum, so an index written
    /// by a newer version with a type this one doesn't know still decodes.
    var captureTypeRaw: String? = nil

    var captureType: CaptureType? { captureTypeRaw.flatMap(CaptureType.init(rawValue:)) }

    var fullImage: NSImage { HistoryImageCache.fullImage(for: imagePath) }
    var thumbnail: NSImage { HistoryImageCache.thumbnail(for: thumbnailPath) }

    /// The same capture with its files in `directory`. The index stores
    /// absolute paths, which go stale when the home folder is renamed or
    /// History is moved to another Mac.
    func relocated(to directory: URL) -> HistoryItem {
        func moved(_ path: String) -> String {
            directory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path
        }
        return HistoryItem(
            id: id,
            createdAt: createdAt,
            imagePath: moved(imagePath),
            thumbnailPath: moved(thumbnailPath),
            captureRect: captureRect,
            ocrText: ocrText,
            captureTypeRaw: captureTypeRaw
        )
    }
}

struct CodableRect: Codable {
    let x, y, width, height: Double
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; width = r.width; height = r.height }
}

/// Shared in-memory cache for history images. Eliminates repeated disk reads
/// when the user clicks Copy / Edit / Save / Pin on the same cell. Bounded so
/// memory never grows unbounded regardless of history size.
enum HistoryImageCache {

    private static let fullCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 30
        c.totalCostLimit = 200 * 1024 * 1024
        return c
    }()

    private static let thumbCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        c.totalCostLimit = 100 * 1024 * 1024
        return c
    }()

    static func fullImage(for path: String) -> NSImage {
        let key = path as NSString
        if let hit = fullCache.object(forKey: key) { return hit }
        guard let img = NSImage(contentsOfFile: path) else { return NSImage() }
        fullCache.setObject(img, forKey: key, cost: imageCost(img))
        return img
    }

    static func thumbnail(for path: String) -> NSImage {
        let key = path as NSString
        if let hit = thumbCache.object(forKey: key) { return hit }
        guard let img = NSImage(contentsOfFile: path) else { return NSImage() }
        thumbCache.setObject(img, forKey: key, cost: imageCost(img))
        return img
    }

    /// Pure cache lookup — never touches disk. Cell population uses this and
    /// decodes misses off the main thread.
    static func thumbnailIfCached(for path: String) -> NSImage? {
        thumbCache.object(forKey: path as NSString)
    }

    /// Loads AND fully decodes a thumbnail (NSCache is thread-safe, so this is
    /// safe off the main thread) and primes the cache. `NSImage(contentsOfFile:)`
    /// defers pixel decode to first draw — forcing `rep.cgImage` here keeps that
    /// cost off the main thread too.
    static func loadThumbnailDecoded(for path: String) -> NSImage? {
        if let hit = thumbCache.object(forKey: path as NSString) { return hit }
        guard let data = FileManager.default.contents(atPath: path),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        _ = rep.cgImage
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        thumbCache.setObject(image, forKey: path as NSString, cost: imageCost(image))
        return image
    }

    static func primeFull(_ image: NSImage, for path: String) {
        fullCache.setObject(image, forKey: path as NSString, cost: imageCost(image))
    }

    static func primeThumbnail(_ image: NSImage, for path: String) {
        thumbCache.setObject(image, forKey: path as NSString, cost: imageCost(image))
    }

    static func evict(fullPath: String, thumbnailPath: String) {
        fullCache.removeObject(forKey: fullPath as NSString)
        thumbCache.removeObject(forKey: thumbnailPath as NSString)
    }

    static func evictAll() {
        fullCache.removeAllObjects()
        thumbCache.removeAllObjects()
    }

    private static func imageCost(_ image: NSImage) -> Int {
        let px = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        return max(px * 4, 1)
    }
}
