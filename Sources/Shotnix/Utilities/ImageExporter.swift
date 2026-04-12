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

    /// Generates a filename like "Shotnix 2026-04-12 at 10.30.48" (matches CleanShot convention).
    static var timestampedName: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Shotnix \(df.string(from: Date()))"
    }

    // MARK: – Save with panel

    static func saveWithPanel(image: NSImage, suggestedName: String) {
        let panel = NSSavePanel()
        let preferredExt = Settings.screenshotFormat
        panel.nameFieldStringValue = "\(suggestedName).\(preferredExt)"
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
        case "webp":
            data = webpData(from: image)
        default:
            data = pngData(from: image)
        }
        // Ensure parent directory exists (auto-save may target a custom folder)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data?.write(to: url)
        HistoryManager.applyScreenshotMetadata(to: url.path, rect: nil)
    }

    // MARK: – Format helpers (CGImage-based, no TIFF roundtrip)

    static func pngData(from image: NSImage) -> Data? {
        guard let cgImage = image.bestCGImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        // No custom DPI properties — CGImageDestination embeds the CGImage's
        // native ICC profile and lets the OS handle DPI (same as CleanShot X).
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func webpData(from image: NSImage, quality: CGFloat = 0.90) -> Data? {
        guard let cgImage = image.bestCGImage else { return nil }
        let data = NSMutableData()
        // WebP support via ImageIO (macOS 14+). Falls back to PNG on older systems.
        let webpUTI = "org.webmproject.webp" as CFString
        guard let dest = CGImageDestinationCreateWithData(data, webpUTI, 1, nil) else {
            return pngData(from: image)
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            return pngData(from: image)
        }
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
    /// Prefers the raw CGImage from NSBitmapImageRep (zero resampling) over
    /// cgImage(forProposedRect:) which re-renders through CoreGraphics and
    /// can introduce interpolation blur.
    var bestCGImage: CGImage? {
        // 1. Direct extraction from NSBitmapImageRep (pixel-perfect, no resampling)
        var best: CGImage?
        var bestPixels = 0
        for rep in representations {
            if let bitmapRep = rep as? NSBitmapImageRep, let cg = bitmapRep.cgImage {
                let pixels = cg.width * cg.height
                if pixels > bestPixels {
                    best = cg
                    bestPixels = pixels
                }
            }
        }
        if let best { return best }

        // 2. Fallback: render at FULL pixel dimensions (not logical size)
        //    Use the largest representation's pixel size to avoid downscaling.
        let maxRep = representations.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh })
        let pixelW = maxRep?.pixelsWide ?? Int(size.width)
        let pixelH = maxRep?.pixelsHigh ?? Int(size.height)
        var proposedRect = CGRect(x: 0, y: 0, width: pixelW, height: pixelH)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}
