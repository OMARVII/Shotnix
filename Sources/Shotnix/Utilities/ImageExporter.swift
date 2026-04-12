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
        CGImageDestinationAddImage(dest, cgImage, dpiProperties(for: image, cgImage: cgImage))
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func jpegData(from image: NSImage, quality: CGFloat = 0.95) -> Data? {
        guard let cgImage = image.bestCGImage else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        var opts = dpiDict(for: image, cgImage: cgImage)
        opts[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Compute DPI metadata from the pixel-to-point ratio of the image.
    /// On Retina (2x), pixels = 2 × points → DPI = 144. On 1x → DPI = 72.
    private static func dpiProperties(for image: NSImage, cgImage: CGImage) -> CFDictionary {
        dpiDict(for: image, cgImage: cgImage) as CFDictionary
    }

    private static func dpiDict(for image: NSImage, cgImage: CGImage) -> [CFString: Any] {
        guard image.size.width > 0 else { return [:] }
        let scale = CGFloat(cgImage.width) / image.size.width
        let dpi = 72.0 * scale
        return [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
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
