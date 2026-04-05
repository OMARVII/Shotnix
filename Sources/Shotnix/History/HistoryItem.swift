import AppKit

struct HistoryItem: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let imagePath: String     // Full-res PNG on disk
    let thumbnailPath: String // Smaller PNG for list UI
    let captureRect: CodableRect?

    var fullImage: NSImage { NSImage(contentsOfFile: imagePath) ?? NSImage() }
    var thumbnail: NSImage  { NSImage(contentsOfFile: thumbnailPath) ?? NSImage() }
}

struct CodableRect: Codable {
    let x, y, width, height: Double
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; width = r.width; height = r.height }
}
