import AppKit
import Darwin

/// Persists captures to ~/Library/Application Support/Shotnix/History/
@MainActor
final class HistoryManager: ObservableObject {

    private(set) var items: [HistoryItem] = []
    private let storageDir: URL
    private let indexURL: URL

    init() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("[Shotnix] Application Support directory not found")
        }
        storageDir = appSupport.appendingPathComponent("Shotnix/History", isDirectory: true)
        indexURL   = storageDir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: – Add
    //
    // Two-phase insert: the HistoryItem is returned synchronously so the UI
    // (overlay, auto-copy, auto-save) unblocks immediately. PNG encoding,
    // thumbnail generation, xattr metadata and JSON index write all happen on
    // a detached background Task. We prime HistoryImageCache with the
    // in-memory NSImage so any call to `item.fullImage` / `item.thumbnail`
    // before the disk write finishes serves from memory.

    @discardableResult
    func add(image: NSImage, rect: CGRect?) -> HistoryItem {
        let id = UUID()
        let imagePath = storageDir.appendingPathComponent("\(id.uuidString).png").path
        let thumbPath = storageDir.appendingPathComponent("\(id.uuidString)_thumb.png").path

        let item = HistoryItem(
            id: id,
            createdAt: Date(),
            imagePath: imagePath,
            thumbnailPath: thumbPath,
            captureRect: rect.map(CodableRect.init)
        )
        items.insert(item, at: 0)

        // Serve the full image from memory until the disk write lands.
        HistoryImageCache.primeFull(image, for: imagePath)
        // Stand-in thumbnail: the full image scales down fine in NSImageView
        // until the real thumbnail is generated. Cheap perceptual win.
        HistoryImageCache.primeThumbnail(image, for: thumbPath)

        Task.detached(priority: .userInitiated) { [weak self] in
            Self.encodeAndPersist(
                image: image,
                imagePath: imagePath,
                thumbPath: thumbPath,
                rect: rect,
                manager: self
            )
        }
        return item
    }

    /// Called from the detached encode task once the index needs to be written.
    /// Runs on the main actor because it reads `items`, which is actor-isolated.
    func persistCurrentIndex() {
        Self.persist(items: items, to: indexURL)
    }

    // MARK: – Thumbnail access (UI convenience)

    func cachedThumbnail(for item: HistoryItem) -> NSImage? {
        HistoryImageCache.thumbnail(for: item.thumbnailPath)
    }

    // MARK: – Delete

    func delete(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        HistoryImageCache.evict(fullPath: item.imagePath, thumbnailPath: item.thumbnailPath)
        let imgPath = item.imagePath
        let thumbPath = item.thumbnailPath
        persistCurrentIndex()
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(atPath: imgPath)
            try? FileManager.default.removeItem(atPath: thumbPath)
        }
    }

    func deleteAll() {
        let removed = items
        items.removeAll()
        HistoryImageCache.evictAll()
        persistCurrentIndex()
        Task.detached(priority: .utility) {
            removed.forEach {
                try? FileManager.default.removeItem(atPath: $0.imagePath)
                try? FileManager.default.removeItem(atPath: $0.thumbnailPath)
            }
        }
    }

    // MARK: – Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        do {
            let data = try Data(contentsOf: indexURL)
            let decoded = try JSONDecoder().decode([HistoryItem].self, from: data)
            items = decoded.filter { FileManager.default.fileExists(atPath: $0.imagePath) }
        } catch {
            print("[Shotnix] History index corrupted, starting fresh: \(error)")
            // Don't overwrite — the corrupt file may be recoverable manually.
        }
    }

    @discardableResult
    nonisolated private static func persist(items: [HistoryItem], to indexURL: URL) -> Bool {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: indexURL, options: .atomic)
            return true
        } catch {
            print("[Shotnix] History persist failed: \(error)")
            return false
        }
    }

    // MARK: – Encode + persist (off-main)
    //
    // Runs on a detached background Task. Does the expensive PNG encode, the
    // thumbnail downsample + encode, xattr metadata, and JSON index write —
    // none of which need the main actor. Once the files are on disk, we
    // reach back to the main actor to prime the thumbnail cache with the
    // downsampled version so the history grid picks it up.

    nonisolated private static func encodeAndPersist(
        image: NSImage,
        imagePath: String,
        thumbPath: String,
        rect: CGRect?,
        manager: HistoryManager?
    ) {
        guard let fullCG = image.bestCGImage else {
            print("[Shotnix] History persist failed: image has no CGImage backing")
            return
        }

        guard let pngFull = ImageExporter.pngData(from: fullCG) else {
            print("[Shotnix] History persist failed: unable to encode full image")
            return
        }

        do {
            try pngFull.write(to: URL(fileURLWithPath: imagePath), options: .atomic)
            applyScreenshotMetadata(to: imagePath, rect: rect)
        } catch {
            print("[Shotnix] History persist failed at \(imagePath): \(error)")
            return
        }

        // Thumbnail via CoreGraphics (thread-safe, ~2–3× faster than lockFocus).
        var thumbImage: NSImage?
        if let thumbCG = downsample(cg: fullCG, maxDimension: 240),
           let pngThumb = ImageExporter.pngData(from: thumbCG) {
            do {
                try pngThumb.write(to: URL(fileURLWithPath: thumbPath), options: .atomic)
                let logicalSize = NSSize(width: thumbCG.width, height: thumbCG.height)
                thumbImage = CaptureEngine.nsImage(from: thumbCG, logicalSize: logicalSize)
            } catch {
                print("[Shotnix] History thumbnail persist failed at \(thumbPath): \(error)")
            }
        }

        Task { @MainActor in
            if let thumbImage {
                HistoryImageCache.primeThumbnail(thumbImage, for: thumbPath)
            }
            manager?.persistCurrentIndex()
        }
    }

    /// Downsample a CGImage so its longest edge is `maxDimension` points.
    /// Returns the input unchanged if it already fits.
    nonisolated private static func downsample(cg: CGImage, maxDimension: CGFloat) -> CGImage? {
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let longest = max(w, h)
        guard longest > maxDimension else { return cg }
        let scale = maxDimension / longest
        let newW = max(1, Int((w * scale).rounded()))
        let newH = max(1, Int((h * scale).rounded()))
        let colorSpace = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }

    // MARK: – Screenshot metadata

    nonisolated static func applyScreenshotMetadata(to path: String, rect: CGRect?) {
        let url = URL(fileURLWithPath: path) as NSURL
        // Mark as screenshot for Spotlight/Finder (same as macOS native + CleanShot X)
        let isScreenCapture = true as NSNumber
        let plist = try? PropertyListSerialization.data(fromPropertyList: isScreenCapture, format: .binary, options: 0)
        if let plist {
            _ = (url as URL).withUnsafeFileSystemRepresentation { cPath -> Int32 in
                guard let cPath else { return -1 }
                return setxattr(cPath, "com.apple.metadata:kMDItemIsScreenCapture", (plist as NSData).bytes, plist.count, 0, XATTR_NOFOLLOW)
            }
        }

        // Screenshot type
        let typeData = try? PropertyListSerialization.data(fromPropertyList: "selection" as NSString, format: .binary, options: 0)
        if let typeData {
            _ = (url as URL).withUnsafeFileSystemRepresentation { cPath -> Int32 in
                guard let cPath else { return -1 }
                return setxattr(cPath, "com.apple.metadata:kMDItemScreenCaptureType", (typeData as NSData).bytes, typeData.count, 0, XATTR_NOFOLLOW)
            }
        }

        // Capture rect
        if let rect {
            let rectArray = [rect.origin.x, rect.origin.y, rect.width, rect.height] as NSArray
            let rectData = try? PropertyListSerialization.data(fromPropertyList: rectArray, format: .binary, options: 0)
            if let rectData {
                _ = (url as URL).withUnsafeFileSystemRepresentation { cPath -> Int32 in
                    guard let cPath else { return -1 }
                    return setxattr(cPath, "com.apple.metadata:kMDItemScreenCaptureGlobalRect", (rectData as NSData).bytes, rectData.count, 0, XATTR_NOFOLLOW)
                }
            }
        }
    }
}
