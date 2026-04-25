import AppKit
import UniformTypeIdentifiers
import ImageIO

enum ImageExporter {

    // MARK: – Clipboard

    static func copyToClipboard(image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        // PNG only — NSPasteboard synthesizes TIFF on demand for legacy readers,
        // and every modern macOS app (Slack, Notion, Figma, Preview, Messages)
        // prefers PNG. Skipping the TIFF encode saves ~30 MB + ~50 ms per 4K copy.
        guard let cg = image.bestCGImage, let png = pngData(from: cg) else { return }
        pb.declareTypes([.png], owner: nil)
        pb.setData(png, forType: .png)
    }

    private static let nameFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return df
    }()

    static var timestampedName: String {
        "Shotnix \(nameFormatter.string(from: Date()))"
    }

    // MARK: – Save with panel

    static func saveWithPanel(image: NSImage, suggestedName: String, completion: ((Bool) -> Void)? = nil) {
        let panel = NSSavePanel()
        let preferredExt = Settings.screenshotFormat
        panel.nameFieldStringValue = "\(suggestedName).\(preferredExt)"
        panel.allowedContentTypes = [.png, .jpeg, UTType("org.webmproject.webp") ?? .data]
        panel.canCreateDirectories = true
        panel.begin { response in
            if response == .OK, let url = panel.url {
                save(image: image, to: url)
                completion?(true)
            } else {
                completion?(false)
            }
        }
    }

    // MARK: – Silent save

    static func save(image: NSImage, to url: URL) {
        // Extract the CGImage once and reuse it for whichever encoder runs.
        guard let cg = image.bestCGImage else { return }
        let ext = url.pathExtension.lowercased()
        let data: Data?
        switch ext {
        case "jpg", "jpeg": data = jpegData(from: cg)
        case "webp":        data = webpData(from: cg)
        default:            data = pngData(from: cg)
        }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data?.write(to: url)
        HistoryManager.applyScreenshotMetadata(to: url.path, rect: nil)
    }

    // MARK: – Format helpers
    //
    // The CGImage-taking variants are the primitive — each encode extracts the
    // best CGImage off the NSImage at most once per call site. The NSImage
    // overloads are kept for callers that don't already hold a CGImage.

    static func pngData(from cg: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func jpegData(from cg: CGImage, quality: CGFloat = 0.95) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func webpData(from cg: CGImage, quality: CGFloat = 0.90) -> Data? {
        let data = NSMutableData()
        let webpUTI = "org.webmproject.webp" as CFString
        guard let dest = CGImageDestinationCreateWithData(data, webpUTI, 1, nil) else {
            return pngData(from: cg)
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return pngData(from: cg) }
        return data as Data
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let cg = image.bestCGImage else { return nil }
        return pngData(from: cg)
    }

    static func jpegData(from image: NSImage, quality: CGFloat = 0.95) -> Data? {
        guard let cg = image.bestCGImage else { return nil }
        return jpegData(from: cg, quality: quality)
    }

    static func webpData(from image: NSImage, quality: CGFloat = 0.90) -> Data? {
        guard let cg = image.bestCGImage else { return nil }
        return webpData(from: cg, quality: quality)
    }
}

extension NSImage {
    /// Extract the highest-resolution CGImage backing this NSImage.
    /// Prefers the raw CGImage from NSBitmapImageRep (zero resampling) over
    /// `cgImage(forProposedRect:)` which re-renders through CoreGraphics and
    /// can introduce interpolation blur.
    ///
    /// Cached per-instance via associated object so repeated export paths
    /// (history PNG + thumbnail + clipboard) only compute this once.
    var bestCGImage: CGImage? {
        if let cached = objc_getAssociatedObject(self, &NSImage.bestCGImageKey) as! CGImage? {
            return cached
        }
        let computed = computeBestCGImage()
        if let computed {
            objc_setAssociatedObject(self, &NSImage.bestCGImageKey, computed, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        return computed
    }

    private static var bestCGImageKey: UInt8 = 0

    private func computeBestCGImage() -> CGImage? {
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

        let maxRep = representations.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh })
        let pixelW = maxRep?.pixelsWide ?? Int(size.width)
        let pixelH = maxRep?.pixelsHigh ?? Int(size.height)
        var proposedRect = CGRect(x: 0, y: 0, width: pixelW, height: pixelH)
        return cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}
