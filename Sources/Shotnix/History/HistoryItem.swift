import AppKit

struct HistoryItem: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let imagePath: String     // Full-res PNG on disk
    let thumbnailPath: String // Smaller PNG for list UI
    let captureRect: CodableRect?

    var fullImage: NSImage { HistoryImageCache.fullImage(for: imagePath) }
    var thumbnail: NSImage { HistoryImageCache.thumbnail(for: thumbnailPath) }
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
