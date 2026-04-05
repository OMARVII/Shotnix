import AppKit
import UniformTypeIdentifiers
import ImageIO

enum ImageExporter {

    // MARK: – Clipboard

    static func copyToClipboard(image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        // Write both PNG + TIFF for maximum compatibility (clipboard managers, apps)
        // Same approach as CleanShot X
        var types: [NSPasteboard.PasteboardType] = []
        var dataMap: [(NSPasteboard.PasteboardType, Data)] = []
        if let png = pngData(from: image) {
            types.append(.png)
            dataMap.append((.png, png))
        }
        if let tiff = image.tiffRepresentation {
            types.append(.tiff)
            dataMap.append((.tiff, tiff))
        }
        pb.declareTypes(types, owner: nil)
        for (type, data) in dataMap {
            pb.setData(data, forType: type)
        }
    }

    // MARK: – Save with panel

    static func saveWithPanel(image: NSImage, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).png"
        panel.allowedContentTypes = [.png, .jpeg, UTType("org.webmproject.webp") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(image: image, to: url)
    }

    // MARK: – Silent save

    static func save(image: NSImage, to url: URL) {
        let ext = url.pathExtension.lowercased()
        let data: Data?
        switch ext {
        case "jpg", "jpeg":
            data = jpegData(from: image)
        default:
            data = pngData(from: image)
        }
        try? data?.write(to: url)
        HistoryManager.applyScreenshotMetadata(to: url.path, rect: nil)
    }

    // MARK: – Format helpers (CGImage-based, no TIFF roundtrip)

    static func pngData(from image: NSImage) -> Data? {
        guard let cgImage = image.bestCGImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func jpegData(from image: NSImage, quality: CGFloat = 0.95) -> Data? {
        guard let cgImage = image.bestCGImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

extension NSImage {
    /// Extract the highest-resolution CGImage backing this NSImage.
    var bestCGImage: CGImage? {
        // Prefer the CGImage directly from representations (avoids resampling)
        for rep in representations {
            if let bitmapRep = rep as? NSBitmapImageRep, let cg = bitmapRep.cgImage {
                return cg
            }
        }
        // Fallback: render into a CGImage at full pixel dimensions
        var proposedRect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: [.ctm: AffineTransform.identity])
    }
}
