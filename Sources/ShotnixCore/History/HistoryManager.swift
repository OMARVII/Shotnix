import AppKit
import Darwin

extension Notification.Name {
    /// Posted on the main actor after any user-visible history mutation
    /// (add / delete / restore / clear) so an open history panel stays live.
    static let shotnixHistoryDidChange = Notification.Name("shotnixHistoryDidChange")
}

/// Tombstone for a deleted capture. The item's paths still point at the
/// original History/ locations; the actual files sit in History/Trash/ under
/// the same file names until the entry is restored or purged.
struct HistoryTrashEntry: Codable {
    let item: HistoryItem
    let deletedAt: Date
    /// Position the item occupied in `items` when it was deleted, so undo can
    /// reinsert it where it was (clamped to the current count).
    let originalIndex: Int
}

/// Persists captures to ~/Library/Application Support/Shotnix/History/
@MainActor
final class HistoryManager: ObservableObject {

    private(set) var items: [HistoryItem] = []
    private(set) var trashEntries: [HistoryTrashEntry] = []
    private let storageDir: URL
    private let indexURL: URL
    private let trashDir: URL
    private let trashIndexURL: URL

    /// Trash entries older than this are permanently deleted on launch.
    private static let trashRetention: TimeInterval = 7 * 24 * 60 * 60

    init(storageDir overrideStorageDir: URL? = nil) {
        if let overrideStorageDir {
            storageDir = overrideStorageDir
        } else {
            guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                fatalError("[Shotnix] Application Support directory not found")
            }
            storageDir = appSupport.appendingPathComponent("Shotnix/History", isDirectory: true)
        }
        indexURL      = storageDir.appendingPathComponent("index.json")
        trashDir      = storageDir.appendingPathComponent("Trash", isDirectory: true)
        trashIndexURL = trashDir.appendingPathComponent("trash.json")
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        load()
        loadTrash()
        purgeExpiredTrash()
        scheduleOCRIndexing()
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
        // Index the new capture for text search in the background.
        scheduleOCRIndexing()
        notifyChanged()
        return item
    }

    // MARK: – Edits

    /// One edit write at a time, in order: a quick copy-then-save must leave
    /// the later edit on disk.
    private static let editWriteQueue = DispatchQueue(label: "com.shotnix.history.edits", qos: .userInitiated)

    /// The untouched capture, kept next to an item's image once it's edited.
    nonisolated static func originalImagePath(for item: HistoryItem) -> String {
        (item.imagePath as NSString).deletingPathExtension + "_original.png"
    }

    /// Shows an edited version of a capture (saved or copied from the
    /// annotation editor) in place of the capture. The first edit keeps the
    /// capture itself at `originalImagePath`, so it's never lost.
    func replaceImage(of item: HistoryItem, with image: NSImage) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let current = items[index]
        let originalPath = Self.originalImagePath(for: current)
        if !FileManager.default.fileExists(atPath: originalPath) {
            if FileManager.default.fileExists(atPath: current.imagePath) {
                try? FileManager.default.copyItem(atPath: current.imagePath, toPath: originalPath)
            } else if let png = ImageExporter.pngData(from: current.fullImage) {
                // The capture's own write hasn't landed yet: keep it from memory.
                try? png.write(to: URL(fileURLWithPath: originalPath), options: .atomic)
            }
        }
        // The edit can add text (labels, callouts), so search re-indexes it.
        items[index].ocrText = nil
        HistoryImageCache.primeFull(image, for: current.imagePath)
        HistoryImageCache.primeThumbnail(image, for: current.thumbnailPath)
        let rect = current.captureRect?.cgRect
        Self.editWriteQueue.async { [weak self] in
            Self.encodeAndPersist(image: image, imagePath: current.imagePath, thumbPath: current.thumbnailPath, rect: rect, manager: self)
        }
        scheduleOCRIndexing()
        notifyChanged()
    }

    /// Posted after any user-visible history mutation so an open history panel
    /// refreshes live. Background OCR-text writes deliberately do NOT post —
    /// that would spam one refresh per indexed item.
    private func notifyChanged() {
        NotificationCenter.default.post(name: .shotnixHistoryDidChange, object: self)
    }

    /// Called from the detached encode task once the index needs to be written.
    /// Runs on the main actor because it reads `items`, which is actor-isolated.
    func persistCurrentIndex() {
        Self.persist(items: items, to: indexURL)
    }

    // MARK: – Thumbnail access (UI convenience)

    /// Pure in-memory lookup — never hits disk. The history grid decodes
    /// misses off the main thread instead of stalling cell population.
    func cachedThumbnail(for item: HistoryItem) -> NSImage? {
        HistoryImageCache.thumbnailIfCached(for: item.thumbnailPath)
    }

    // MARK: – Delete (moves to trash, undoable)

    /// Moves the item's files into History/Trash/ and records a tombstone so
    /// the delete can be undone. Files are permanently removed only when the
    /// tombstone expires (see `purgeExpiredTrash`).
    func delete(_ item: HistoryItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let removed = items.remove(at: index)
        HistoryImageCache.evict(fullPath: removed.imagePath, thumbnailPath: removed.thumbnailPath)
        moveToTrash(HistoryTrashEntry(item: removed, deletedAt: Date(), originalIndex: index))
        persistCurrentIndex()
        persistTrashIndex()
        notifyChanged()
    }

    func deleteAll() {
        guard !items.isEmpty else { return }
        let removed = items
        items.removeAll()
        HistoryImageCache.evictAll()
        let now = Date()
        for (index, item) in removed.enumerated() {
            moveToTrash(HistoryTrashEntry(item: item, deletedAt: now, originalIndex: index))
        }
        persistCurrentIndex()
        persistTrashIndex()
        notifyChanged()
    }

    /// Undo a delete: move the files back out of History/Trash/ and reinsert
    /// the item at the position it was deleted from (clamped).
    @discardableResult
    func restoreFromTrash(id: UUID) -> HistoryItem? {
        guard let entryIndex = trashEntries.firstIndex(where: { $0.item.id == id }) else { return nil }
        let entry = trashEntries.remove(at: entryIndex)
        restoreFileFromTrash(toPath: entry.item.imagePath)
        restoreFileFromTrash(toPath: entry.item.thumbnailPath)
        restoreFileFromTrash(toPath: Self.originalImagePath(for: entry.item))
        let insertAt = min(max(entry.originalIndex, 0), items.count)
        items.insert(entry.item, at: insertAt)
        persistCurrentIndex()
        persistTrashIndex()
        // The restored item may predate OCR indexing.
        scheduleOCRIndexing()
        notifyChanged()
        return entry.item
    }

    // MARK: – Trash internals

    private func moveToTrash(_ entry: HistoryTrashEntry) {
        moveFileToTrash(atPath: entry.item.imagePath)
        moveFileToTrash(atPath: entry.item.thumbnailPath)
        moveFileToTrash(atPath: Self.originalImagePath(for: entry.item))
        trashEntries.append(entry)
    }

    private func moveFileToTrash(atPath path: String) {
        let source = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        let destination = trashDir.appendingPathComponent(source.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            print("[Shotnix] Failed to move \(path) to trash: \(error)")
        }
    }

    private func restoreFileFromTrash(toPath path: String) {
        let destination = URL(fileURLWithPath: path)
        let source = trashDir.appendingPathComponent(destination.lastPathComponent)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            print("[Shotnix] Failed to restore \(path) from trash: \(error)")
        }
    }

    /// Permanently deletes trash entries older than `trashRetention`.
    private func purgeExpiredTrash() {
        let cutoff = Date().addingTimeInterval(-Self.trashRetention)
        let expired = trashEntries.filter { $0.deletedAt < cutoff }
        guard !expired.isEmpty else { return }
        trashEntries.removeAll { $0.deletedAt < cutoff }
        persistTrashIndex()
        let trashDir = self.trashDir
        let fileURLs = expired
            .flatMap { [$0.item.imagePath, $0.item.thumbnailPath, Self.originalImagePath(for: $0.item)] }
            .map { trashDir.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent) }
        Task.detached(priority: .utility) {
            fileURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    private func loadTrash() {
        guard FileManager.default.fileExists(atPath: trashIndexURL.path) else { return }
        do {
            let data = try Data(contentsOf: trashIndexURL)
            trashEntries = try JSONDecoder().decode([HistoryTrashEntry].self, from: data)
        } catch {
            print("[Shotnix] Trash index corrupted, starting fresh: \(error)")
            // Don't overwrite — the corrupt file may be recoverable manually.
        }
    }

    private func persistTrashIndex() {
        Self.persistTrash(entries: trashEntries, to: trashIndexURL)
    }

    nonisolated private static func persistTrash(entries: [HistoryTrashEntry], to url: URL) {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[Shotnix] Trash persist failed: \(error)")
        }
    }

    // MARK: – OCR indexing
    //
    // A single low-priority serial loop OCRs every item whose `ocrText` is
    // still nil (oldest index files predate the field; new captures start
    // nil). Image decode + Vision recognition run off the main actor; only
    // the result write-back touches manager state. Results are persisted
    // every few items so progress survives a quit mid-index. Failures store
    // "" so an unreadable capture is never re-queued forever.

    private var ocrIndexingActive = false
    private var ocrProcessedSinceSave = 0
    private static let ocrSaveInterval = 4

    private func scheduleOCRIndexing() {
        guard !ocrIndexingActive else { return }
        guard items.contains(where: { $0.ocrText == nil }) else { return }
        ocrIndexingActive = true
        Task(priority: .utility) { [weak self] in
            while let job = self?.nextOCRJob() {
                let text = await Self.recognizeText(atImagePath: job.imagePath)
                self?.storeOCRText(text, forItemID: job.id)
            }
            self?.finishOCRIndexing()
        }
    }

    private func nextOCRJob() -> (id: UUID, imagePath: String)? {
        guard let item = items.first(where: { $0.ocrText == nil }) else { return nil }
        return (item.id, item.imagePath)
    }

    private func storeOCRText(_ text: String, forItemID id: UUID) {
        // The item may have been deleted while OCR was running — drop the result.
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].ocrText = text
        ocrProcessedSinceSave += 1
        if ocrProcessedSinceSave >= Self.ocrSaveInterval {
            ocrProcessedSinceSave = 0
            persistCurrentIndex()
        }
    }

    private func finishOCRIndexing() {
        if ocrProcessedSinceSave > 0 {
            ocrProcessedSinceSave = 0
            persistCurrentIndex()
        }
        ocrIndexingActive = false
    }

    /// Loads the image and runs Vision OCR, entirely off the main actor.
    /// Returns "" on any failure so the item is marked as indexed regardless.
    nonisolated private static func recognizeText(atImagePath path: String) async -> String {
        // Prefer a fresh decode from disk (avoids churning the shared cache);
        // fall back to the primed in-memory image for captures whose PNG
        // hasn't landed on disk yet (two-phase add).
        let image = NSImage(contentsOfFile: path) ?? HistoryImageCache.fullImage(for: path)
        do {
            return try await OCREngine.recognizeText(in: image)
        } catch {
            return ""
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
        // Mark as screenshot for Spotlight/Finder (as macOS marks its own screenshots)
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
