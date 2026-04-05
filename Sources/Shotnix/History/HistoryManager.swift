import AppKit

/// Persists captures to ~/Library/Application Support/Shotnix/History/
@MainActor
final class HistoryManager: ObservableObject {

    private(set) var items: [HistoryItem] = []
    private let storageDir: URL
    private let indexURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        storageDir = appSupport.appendingPathComponent("Shotnix/History", isDirectory: true)
        indexURL   = storageDir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: – Add

    @discardableResult
    func add(image: NSImage, rect: CGRect?) -> HistoryItem {
        let id = UUID()
        let imagePath = storageDir.appendingPathComponent("\(id.uuidString).png").path
        let thumbPath = storageDir.appendingPathComponent("\(id.uuidString)_thumb.png").path

        saveImage(image, to: imagePath, size: nil)
        saveImage(image, to: thumbPath, size: CGSize(width: 240, height: 240))
        HistoryManager.applyScreenshotMetadata(to: imagePath, rect: rect)

        let item = HistoryItem(
            id: id,
            createdAt: Date(),
            imagePath: imagePath,
            thumbnailPath: thumbPath,
            captureRect: rect.map(CodableRect.init)
        )
        items.insert(item, at: 0)
        persist()
        return item
    }

    // MARK: – Delete

    func delete(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        try? FileManager.default.removeItem(atPath: item.imagePath)
        try? FileManager.default.removeItem(atPath: item.thumbnailPath)
        persist()
    }

    func deleteAll() {
        items.forEach {
            try? FileManager.default.removeItem(atPath: $0.imagePath)
            try? FileManager.default.removeItem(atPath: $0.thumbnailPath)
        }
        items.removeAll()
        persist()
    }

    // MARK: – Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            // Encoding/write failed — do NOT overwrite existing index with empty data
            print("[Shotnix] History persist failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return }
        // Filter out items whose files no longer exist on disk
        items = decoded.filter { FileManager.default.fileExists(atPath: $0.imagePath) }
    }

    // MARK: – Image saving

    private func saveImage(_ image: NSImage, to path: String, size: CGSize?) {
        if let size {
            let thumb = image.resizedForThumbnail(to: size)
            guard let png = ImageExporter.pngData(from: thumb) else { return }
            try? png.write(to: URL(fileURLWithPath: path))
        } else {
            guard let png = ImageExporter.pngData(from: image) else { return }
            try? png.write(to: URL(fileURLWithPath: path))
        }
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
                return setxattr(cPath, "com.apple.metadata:kMDItemIsScreenCapture", (plist as NSData).bytes, plist.count, 0, 0)
            }
        }

        // Screenshot type
        let typeData = try? PropertyListSerialization.data(fromPropertyList: "selection" as NSString, format: .binary, options: 0)
        if let typeData {
            _ = (url as URL).withUnsafeFileSystemRepresentation { cPath -> Int32 in
                guard let cPath else { return -1 }
                return setxattr(cPath, "com.apple.metadata:kMDItemScreenCaptureType", (typeData as NSData).bytes, typeData.count, 0, 0)
            }
        }

        // Capture rect
        if let rect {
            let rectArray = [rect.origin.x, rect.origin.y, rect.width, rect.height] as NSArray
            let rectData = try? PropertyListSerialization.data(fromPropertyList: rectArray, format: .binary, options: 0)
            if let rectData {
                _ = (url as URL).withUnsafeFileSystemRepresentation { cPath -> Int32 in
                    guard let cPath else { return -1 }
                    return setxattr(cPath, "com.apple.metadata:kMDItemScreenCaptureGlobalRect", (rectData as NSData).bytes, rectData.count, 0, 0)
                }
            }
        }
    }
}

private extension NSImage {
    func resizedForThumbnail(to maxSize: CGSize) -> NSImage {
        let scale = min(maxSize.width / size.width, maxSize.height / size.height, 1)
        let newSize = CGSize(width: round(size.width * scale), height: round(size.height * scale))
        let result = NSImage(size: newSize)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: CGRect(origin: .zero, size: newSize))
        result.unlockFocus()
        return result
    }
}
