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

/// How long captures stay in History (Preferences → Screenshots).
enum HistoryRetention: String, CaseIterable {
    case forever
    case days7 = "7d"
    case days30 = "30d"
    case days90 = "90d"
    case items100 = "100"
    case items500 = "500"
    case items1000 = "1000"

    var title: String {
        switch self {
        case .forever: return "Forever"
        case .days7: return "7 days"
        case .days30: return "30 days"
        case .days90: return "90 days"
        case .items100: return "Last 100 captures"
        case .items500: return "Last 500 captures"
        case .items1000: return "Last 1,000 captures"
        }
    }

    var maxAge: TimeInterval? {
        switch self {
        case .days7: return 7 * 24 * 60 * 60
        case .days30: return 30 * 24 * 60 * 60
        case .days90: return 90 * 24 * 60 * 60
        default: return nil
        }
    }

    var maxCount: Int? {
        switch self {
        case .items100: return 100
        case .items500: return 500
        case .items1000: return 1000
        default: return nil
        }
    }
}

/// NSImage is immutable once built; the box carries one across a detached
/// task boundary without a Sendable warning.
private struct HistoryImageBox: @unchecked Sendable {
    let image: NSImage
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

    /// Disk I/O for index writes and purges — never the main thread. Serial,
    /// so index snapshots land in the order they were taken.
    nonisolated private static let ioQueue = DispatchQueue(label: "com.shotnix.history.io", qos: .utility)

    /// Index writes are batched: a burst of captures, deletes, or OCR results
    /// costs one write instead of one per change.
    private static let indexWriteDelay: UInt64 = 250_000_000
    private var indexWriteScheduled = false
    private var trashWriteScheduled = false
    /// How many index writes actually ran (tests assert batching).
    private(set) var indexWriteCount = 0

    /// Per-capture file work (the background PNG write, moves to and from the
    /// trash, purges) runs in order: a delete right after a capture waits for
    /// its write instead of racing it and stranding an untracked PNG.
    private var fileTasks: [UUID: (generation: Int, task: Task<Void, Never>)] = [:]
    private var fileTaskGeneration = 0

    /// The orphan sweep only trusts indexes that loaded completely. A missing,
    /// unreadable, or partly stale index would make real captures look
    /// orphaned, so the sweep leaves that folder alone.
    private var indexLoadedCleanly = false
    private var trashLoadedCleanly = false
    /// Unlisted files younger than this are left alone: a capture written
    /// just before a crash, or while the index write was still pending.
    static let orphanMinimumAge: TimeInterval = 24 * 60 * 60

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
        applyRetention()
        scheduleOCRIndexing()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reindexIfOCRSettingsChanged() }
        }
        Task { [weak self] in await self?.sweepOrphanedFiles() }
        // Batched writes still pending at quit land before the process exits.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingWrites() }
        }
    }

    // MARK: – Add
    //
    // Two-phase insert: the HistoryItem is returned synchronously so the UI
    // (overlay, auto-copy, auto-save) unblocks immediately. PNG encoding,
    // thumbnail generation, xattr metadata and JSON index write all happen
    // off the main thread. We prime HistoryImageCache with the in-memory
    // NSImage so any call to `item.fullImage` / `item.thumbnail` before the
    // disk write finishes serves from memory.

    @discardableResult
    func add(image: NSImage, rect: CGRect?, type: CaptureType? = nil, ocrText: String? = nil) -> HistoryItem {
        let id = UUID()
        let imagePath = storageDir.appendingPathComponent("\(id.uuidString).png").path
        let thumbPath = storageDir.appendingPathComponent("\(id.uuidString)_thumb.png").path

        let item = HistoryItem(
            id: id,
            createdAt: Date(),
            imagePath: imagePath,
            thumbnailPath: thumbPath,
            captureRect: rect.map(CodableRect.init),
            ocrText: ocrText,
            captureTypeRaw: type?.rawValue
        )
        items.insert(item, at: 0)

        // Serve the full image from memory until the disk write lands.
        HistoryImageCache.primeFull(image, for: imagePath)
        // Stand-in thumbnail: the full image scales down fine in NSImageView
        // until the real thumbnail is generated. Cheap perceptual win.
        HistoryImageCache.primeThumbnail(image, for: thumbPath)

        let box = HistoryImageBox(image: image)
        let write = Task.detached(priority: .userInitiated) {
            Self.encodeAndPersist(image: box.image, imagePath: imagePath, thumbPath: thumbPath, rect: rect, type: type)
        }
        enqueueFileOperation(for: id) { [weak self] in
            let thumbnail = await write.value
            // Deleted while encoding: don't resurrect its cache entry.
            guard let self, self.items.contains(where: { $0.id == id }) else { return }
            if let thumbnail {
                HistoryImageCache.primeThumbnail(thumbnail.image, for: thumbPath)
            }
            self.scheduleIndexWrite()
        }
        scheduleIndexWrite()
        applyRetention()
        // Index the new capture for text search in the background.
        scheduleOCRIndexing()
        notifyChanged()
        return item
    }

    // MARK: – Edits

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
        let id = current.id
        let imagePath = current.imagePath
        let thumbPath = current.thumbnailPath
        let originalPath = Self.originalImagePath(for: current)
        let rect = current.captureRect?.cgRect
        let type = current.captureType
        // Until the capture's own write lands, memory holds the only copy of it.
        let unsavedCapture = FileManager.default.fileExists(atPath: imagePath) ? nil : HistoryImageBox(image: current.fullImage)
        if fileTasks[id] == nil {
            Self.keepOriginal(at: originalPath, of: imagePath, unsaved: unsavedCapture)
        }
        // The old text goes now: it may hold exactly what the edit redacted.
        // The edit is indexed once it's on disk (it can add labels and callouts).
        items[index].ocrText = nil
        imageGenerations[id, default: 0] += 1
        editsInFlight[id, default: 0] += 1
        HistoryImageCache.primeFull(image, for: imagePath)
        HistoryImageCache.primeThumbnail(image, for: thumbPath)
        let edit = HistoryImageBox(image: image)
        // Queued behind the capture's own write and earlier edits, so a quick
        // copy-then-save always leaves the latest edit on disk.
        enqueueFileOperation(for: id) { [weak self] in
            let thumbnail = await Task.detached(priority: .userInitiated) { () -> HistoryImageBox? in
                Self.keepOriginal(at: originalPath, of: imagePath, unsaved: unsavedCapture)
                return Self.encodeAndPersist(image: edit.image, imagePath: imagePath, thumbPath: thumbPath, rect: rect, type: type)
            }.value
            guard let self else { return }
            let remaining = (self.editsInFlight[id] ?? 1) - 1
            self.editsInFlight[id] = remaining > 0 ? remaining : nil
            guard self.items.contains(where: { $0.id == id }) else { return }
            if let thumbnail {
                HistoryImageCache.primeThumbnail(thumbnail.image, for: thumbPath)
            }
            self.scheduleIndexWrite()
            self.scheduleOCRIndexing()
        }
        scheduleIndexWrite()
        notifyChanged()
    }

    /// Copies the capture aside the first time it's edited.
    nonisolated private static func keepOriginal(at originalPath: String, of imagePath: String, unsaved: HistoryImageBox?) {
        let files = FileManager.default
        guard !files.fileExists(atPath: originalPath) else { return }
        if files.fileExists(atPath: imagePath) {
            try? files.copyItem(atPath: imagePath, toPath: originalPath)
        } else if let unsaved, let png = ImageExporter.pngData(from: unsaved.image) {
            try? png.write(to: URL(fileURLWithPath: originalPath), options: .atomic)
        }
    }

    /// Posted after any user-visible history mutation so an open history panel
    /// refreshes live. Background OCR-text writes deliberately do NOT post —
    /// that would spam one refresh per indexed item.
    private func notifyChanged() {
        NotificationCenter.default.post(name: .shotnixHistoryDidChange, object: self)
    }

    // MARK: – Thumbnail access (UI convenience)

    /// Pure in-memory lookup — never hits disk. The history grid decodes
    /// misses off the main thread instead of stalling cell population.
    func cachedThumbnail(for item: HistoryItem) -> NSImage? {
        HistoryImageCache.thumbnailIfCached(for: item.thumbnailPath)
    }

    /// The capture's PNG once it has landed on disk — drags hand this file
    /// over directly instead of re-encoding it.
    func storedImageURL(for item: HistoryItem) -> URL? {
        guard fileTasks[item.id] == nil, FileManager.default.fileExists(atPath: item.imagePath) else { return nil }
        return URL(fileURLWithPath: item.imagePath)
    }

    // MARK: – Delete (moves to trash, undoable)

    /// Moves the item's files into History/Trash/ and records a tombstone so
    /// the delete can be undone. Files are permanently removed only when the
    /// tombstone expires (see `purgeExpiredTrash`).
    func delete(_ item: HistoryItem) {
        delete([item])
    }

    func delete(_ itemsToDelete: [HistoryItem]) {
        let ids = Set(itemsToDelete.map(\.id))
        let now = Date()
        var removedAny = false
        // Highest index first so earlier indices stay valid while removing.
        for index in items.indices.reversed() where ids.contains(items[index].id) {
            let removed = items.remove(at: index)
            HistoryImageCache.evict(fullPath: removed.imagePath, thumbnailPath: removed.thumbnailPath)
            moveToTrash(HistoryTrashEntry(item: removed, deletedAt: now, originalIndex: index))
            removedAny = true
        }
        guard removedAny else { return }
        scheduleIndexWrite()
        scheduleTrashWrite()
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
        scheduleIndexWrite()
        scheduleTrashWrite()
        notifyChanged()
    }

    /// Undo a delete: move the files back out of History/Trash/ and reinsert
    /// the item at the position it was deleted from (clamped).
    @discardableResult
    func restoreFromTrash(id: UUID) -> HistoryItem? {
        guard let entryIndex = trashEntries.firstIndex(where: { $0.item.id == id }) else { return nil }
        let entry = trashEntries.remove(at: entryIndex)
        performFileOperation(for: id) { [weak self] in
            self?.restoreFileFromTrash(toPath: entry.item.imagePath)
            self?.restoreFileFromTrash(toPath: entry.item.thumbnailPath)
            self?.restoreFileFromTrash(toPath: Self.originalImagePath(for: entry.item))
        }
        let insertAt = min(max(entry.originalIndex, 0), items.count)
        items.insert(entry.item, at: insertAt)
        scheduleIndexWrite()
        scheduleTrashWrite()
        // The restored item may predate OCR indexing.
        scheduleOCRIndexing()
        notifyChanged()
        return entry.item
    }

    // MARK: – File operation ordering

    private func enqueueFileOperation(for id: UUID, _ operation: @escaping @MainActor () async -> Void) {
        let previous = fileTasks[id]?.task
        fileTaskGeneration += 1
        let generation = fileTaskGeneration
        // Quitting or relaunching for an update waits for these writes, so a
        // capture or an edit saved right before ⌘Q still reaches History.
        if fileWork == nil {
            fileWork = AppTermination.begin("Saving captures to History") { [weak self] done in
                Task { @MainActor in
                    await self?.waitForPendingFileOperations()
                    done()
                }
            }
        }
        let work = fileWork
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await operation()
            guard let self else {
                AppTermination.end(work)
                return
            }
            if self.fileTasks[id]?.generation == generation {
                self.fileTasks[id] = nil
            }
            self.endFileWorkIfIdle()
        }
        fileTasks[id] = (generation, task)
    }

    private var fileWork: AppTermination.Token?

    private func endFileWorkIfIdle() {
        guard fileTasks.isEmpty else { return }
        AppTermination.end(fileWork)
        fileWork = nil
    }

    /// Runs `operation` right away, or after the item's pending file work.
    private func performFileOperation(for id: UUID, _ operation: @escaping @MainActor () -> Void) {
        if fileTasks[id] != nil {
            enqueueFileOperation(for: id) { operation() }
        } else {
            operation()
        }
    }

    /// Resolves once every queued file operation and disk write has finished.
    func waitForPendingFileOperations() async {
        while !fileTasks.isEmpty {
            for task in fileTasks.values.map(\.task) {
                await task.value
            }
            await Task.yield()
        }
        await Self.onIOQueue {}
    }

    // MARK: – Trash internals

    private func moveToTrash(_ entry: HistoryTrashEntry) {
        trashEntries.append(entry)
        let paths = [entry.item.imagePath, entry.item.thumbnailPath, Self.originalImagePath(for: entry.item)]
        performFileOperation(for: entry.item.id) { [weak self] in
            paths.forEach { self?.moveFileToTrash(atPath: $0) }
        }
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
        purgeTrash(trashEntries.filter { $0.deletedAt < cutoff })
    }

    private func purgeTrash(_ expired: [HistoryTrashEntry]) {
        guard !expired.isEmpty else { return }
        let ids = Set(expired.map(\.item.id))
        trashEntries.removeAll { ids.contains($0.item.id) }
        scheduleTrashWrite()
        for entry in expired {
            let urls = [entry.item.imagePath, entry.item.thumbnailPath, Self.originalImagePath(for: entry.item)]
                .map { trashDir.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent) }
            removeFilesPermanently(urls, for: entry.item.id)
        }
    }

    /// Deletes files off the main thread, after any pending work on the item.
    private func removeFilesPermanently(_ urls: [URL], for id: UUID) {
        performFileOperation(for: id) {
            Self.ioQueue.async {
                urls.forEach { try? FileManager.default.removeItem(at: $0) }
            }
        }
    }

    private func loadTrash() {
        guard FileManager.default.fileExists(atPath: trashIndexURL.path) else {
            trashLoadedCleanly = Self.captureFiles(in: trashDir).isEmpty
            return
        }
        do {
            let data = try Data(contentsOf: trashIndexURL)
            let storageDir = self.storageDir
            trashEntries = try JSONDecoder().decode([HistoryTrashEntry].self, from: data).map {
                HistoryTrashEntry(item: $0.item.relocated(to: storageDir), deletedAt: $0.deletedAt, originalIndex: $0.originalIndex)
            }
            trashLoadedCleanly = true
        } catch {
            print("[Shotnix] Trash index corrupted, starting fresh: \(error)")
            // Don't overwrite — the corrupt file may be recoverable manually.
        }
    }

    nonisolated private static func persistTrash(entries: [HistoryTrashEntry], to url: URL) {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[Shotnix] Trash persist failed: \(error)")
        }
    }

    // MARK: – Retention

    /// Captures the policy would drop right now — Settings asks before a
    /// newly picked limit deletes anything.
    func itemsExceedingRetention(_ policy: HistoryRetention, now: Date = Date()) -> [HistoryItem] {
        var expired: [HistoryItem] = []
        var kept = items.sorted { $0.createdAt > $1.createdAt }
        if let maxAge = policy.maxAge {
            let cutoff = now.addingTimeInterval(-maxAge)
            expired += kept.filter { $0.createdAt < cutoff }
            kept.removeAll { $0.createdAt < cutoff }
        }
        if let maxCount = policy.maxCount, kept.count > maxCount {
            expired += kept[maxCount...]
        }
        return expired
    }

    /// Permanently removes captures beyond the retention policy. Forever (the
    /// default) never removes anything.
    @discardableResult
    func applyRetention(_ policy: HistoryRetention = Settings.historyRetention, now: Date = Date()) -> Int {
        let expired = itemsExceedingRetention(policy, now: now)
        guard !expired.isEmpty else { return 0 }
        let ids = Set(expired.map(\.id))
        items.removeAll { ids.contains($0.id) }
        for item in expired {
            HistoryImageCache.evict(fullPath: item.imagePath, thumbnailPath: item.thumbnailPath)
            removeFilesPermanently([item.imagePath, item.thumbnailPath, Self.originalImagePath(for: item)].map { URL(fileURLWithPath: $0) }, for: item.id)
        }
        scheduleIndexWrite()
        notifyChanged()
        return expired.count
    }

    // MARK: – Disk upkeep

    /// Deletes capture files no history or trash entry points at — PNGs left
    /// by the old delete/write race. Only names Shotnix writes
    /// (<UUID>.png, <UUID>_thumb.png, <UUID>_original.png) are ever touched,
    /// only in a folder whose index loaded completely, and only once they're
    /// older than a day and older than that index's last write.
    @discardableResult
    func sweepOrphanedFiles(now: Date = Date()) async -> Int {
        let storageDir = self.storageDir
        let trashDir = self.trashDir
        let sweepStorage = indexLoadedCleanly
        let sweepTrash = trashLoadedCleanly
        guard sweepStorage || sweepTrash else { return 0 }
        let indexURL = self.indexURL
        let trashIndexURL = self.trashIndexURL
        let cutoff = now.addingTimeInterval(-Self.orphanMinimumAge)
        let listed = await Self.onIOQueue {
            (storage: sweepStorage ? Self.captureFiles(in: storageDir, olderThan: cutoff, andIndexAt: indexURL) : [],
             trash: sweepTrash ? Self.captureFiles(in: trashDir, olderThan: cutoff, andIndexAt: trashIndexURL) : [])
        }
        // Decided on the main actor AFTER listing: a capture added before the
        // listing is already in `items`, so its fresh files never look orphaned.
        // A file named by any entry stays, in either folder: a delete or undo
        // cut short before its index write leaves the file in the other one.
        let entries = items + trashEntries.map(\.item)
        let namedFiles = Set(entries.flatMap { [$0.imagePath, $0.thumbnailPath, Self.originalImagePath(for: $0)] }.map { URL(fileURLWithPath: $0).lastPathComponent })
        let busyIDs = Set(fileTasks.keys)
        func isOrphan(_ url: URL) -> Bool {
            guard !namedFiles.contains(url.lastPathComponent) else { return false }
            return !(Self.captureID(fromFileName: url.lastPathComponent).map(busyIDs.contains) ?? false)
        }
        let orphans = (listed.storage + listed.trash).filter(isOrphan)
        guard !orphans.isEmpty else { return 0 }
        await Self.onIOQueue {
            orphans.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        return orphans.count
    }

    /// Bytes History takes on disk, trash included.
    func diskUsage() async -> Int64 {
        let storageDir = self.storageDir
        return await Self.onIOQueue { Self.directorySize(storageDir) }
    }

    /// Settings → Clean Up: empties the History trash, removes orphaned files,
    /// and applies the retention setting now. Returns the bytes freed.
    @discardableResult
    func cleanUp() async -> Int64 {
        let before = await diskUsage()
        await waitForPendingFileOperations()
        purgeTrash(trashEntries)
        applyRetention()
        await waitForPendingFileOperations()
        // The sweep judges files against the index on disk, so it goes last.
        flushPendingWrites()
        await sweepOrphanedFiles()
        let after = await diskUsage()
        return max(0, before - after)
    }

    nonisolated private static func captureFiles(in directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { captureID(fromFileName: $0.lastPathComponent) != nil }
    }

    /// Capture files last written before `cutoff` and before the index at
    /// `indexURL` was last written.
    nonisolated private static func captureFiles(in directory: URL, olderThan cutoff: Date, andIndexAt indexURL: URL) -> [URL] {
        let indexWritten = (try? indexURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let limit = min(cutoff, indexWritten)
        return captureFiles(in: directory).filter { url in
            guard let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
            return written < limit
        }
    }

    /// The capture UUID in "<UUID>.png" / "<UUID>_thumb.png" / "<UUID>_original.png", else nil.
    nonisolated static func captureID(fromFileName name: String) -> UUID? {
        guard name.hasSuffix(".png") else { return nil }
        var stem = String(name.dropLast(4))
        if stem.hasSuffix("_thumb") { stem = String(stem.dropLast(6)) }
        if stem.hasSuffix("_original") { stem = String(stem.dropLast(9)) }
        guard let id = UUID(uuidString: stem), id.uuidString == stem else { return nil }
        return id
    }

    nonisolated private static func directorySize(_ directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    nonisolated private static func onIOQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: – OCR indexing
    //
    // A single low-priority serial loop OCRs every item whose `ocrText` is
    // still nil (oldest index files predate the field; new captures start
    // nil). Image decode + Vision recognition run off the main actor; only
    // the result write-back touches manager state. Results ride the batched
    // index writes, so progress survives a quit mid-index. Failures store
    // "" so an unreadable capture is never re-queued forever.

    private var ocrIndexingActive = false
    /// Captures whose edited image is still being written: indexing them
    /// now would read the old picture.
    private var editsInFlight: [UUID: Int] = [:]
    /// Bumped when OCR settings change or an image is replaced; a result
    /// read before that is dropped and the capture indexed again.
    private var ocrGeneration = 0
    private var imageGenerations: [UUID: Int] = [:]
    private var indexedWithOptions = OCREngine.Options.current
    private var defaultsObserver: NSObjectProtocol?

    private struct OCRJob {
        let id: UUID
        let imagePath: String
        let stamp: [Int]
    }

    private func scheduleOCRIndexing() {
        guard !ocrIndexingActive else { return }
        guard items.contains(where: needsOCR) else { return }
        ocrIndexingActive = true
        Task(priority: .utility) { [weak self] in
            while let job = self?.nextOCRJob() {
                let text = await Self.recognizeText(atImagePath: job.imagePath)
                self?.storeOCRText(text, for: job)
            }
            self?.ocrIndexingActive = false
        }
    }

    private func needsOCR(_ item: HistoryItem) -> Bool {
        item.ocrText == nil && editsInFlight[item.id] == nil
    }

    private func ocrStamp(for id: UUID) -> [Int] {
        [ocrGeneration, imageGenerations[id, default: 0]]
    }

    private func nextOCRJob() -> OCRJob? {
        guard let item = items.first(where: needsOCR) else { return nil }
        return OCRJob(id: item.id, imagePath: item.imagePath, stamp: ocrStamp(for: item.id))
    }

    private func storeOCRText(_ text: String, for job: OCRJob) {
        // The item may have been deleted while OCR was running — drop the result.
        guard let index = items.firstIndex(where: { $0.id == job.id }) else { return }
        // Read from a replaced image or with old settings: it's queued again.
        guard job.stamp == ocrStamp(for: job.id) else { return }
        items[index].ocrText = text
        scheduleIndexWrite()
    }

    /// Picking other OCR languages or accuracy re-indexes History, newest first.
    private func reindexIfOCRSettingsChanged() {
        let options = OCREngine.Options.current
        guard options != indexedWithOptions else { return }
        indexedWithOptions = options
        ocrGeneration += 1
        for index in items.indices where items[index].ocrText != nil {
            items[index].ocrText = nil
        }
        scheduleIndexWrite()
        scheduleOCRIndexing()
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
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            indexLoadedCleanly = Self.captureFiles(in: storageDir).isEmpty
            return
        }
        do {
            let data = try Data(contentsOf: indexURL)
            let storageDir = self.storageDir
            let decoded = try JSONDecoder().decode([HistoryItem].self, from: data).map { $0.relocated(to: storageDir) }
            items = decoded.filter { FileManager.default.fileExists(atPath: $0.imagePath) }
            indexLoadedCleanly = items.count == decoded.count
        } catch {
            print("[Shotnix] History index corrupted, starting fresh: \(error)")
            // Don't overwrite — the corrupt file may be recoverable manually.
        }
    }

    private func scheduleIndexWrite() {
        guard !indexWriteScheduled else { return }
        indexWriteScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.indexWriteDelay)
            self?.writeIndexIfScheduled()
        }
    }

    private func scheduleTrashWrite() {
        guard !trashWriteScheduled else { return }
        trashWriteScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.indexWriteDelay)
            self?.writeTrashIfScheduled()
        }
    }

    /// Snapshots on the main actor (a cheap copy-on-write array copy), then
    /// encodes and writes on the I/O queue.
    private func writeIndexIfScheduled() {
        guard indexWriteScheduled else { return }
        indexWriteScheduled = false
        indexWriteCount += 1
        let snapshot = items
        let url = indexURL
        Self.ioQueue.async { Self.persist(items: snapshot, to: url) }
    }

    private func writeTrashIfScheduled() {
        guard trashWriteScheduled else { return }
        trashWriteScheduled = false
        let snapshot = trashEntries
        let url = trashIndexURL
        Self.ioQueue.async { Self.persistTrash(entries: snapshot, to: url) }
    }

    /// Writes batched index changes now and waits for queued writes — at quit,
    /// and wherever a caller needs the files current.
    func flushPendingWrites() {
        writeIndexIfScheduled()
        writeTrashIfScheduled()
        Self.ioQueue.sync {}
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
    // Runs on a detached background Task: the expensive PNG encode, the
    // thumbnail downsample + encode, and xattr metadata. Returns the
    // downsampled thumbnail so the main actor can prime the grid's cache.

    nonisolated private static func encodeAndPersist(
        image: NSImage,
        imagePath: String,
        thumbPath: String,
        rect: CGRect?,
        type: CaptureType?
    ) -> HistoryImageBox? {
        guard let fullCG = image.bestCGImage else {
            print("[Shotnix] History persist failed: image has no CGImage backing")
            return nil
        }

        guard let pngFull = ImageExporter.pngData(from: fullCG) else {
            print("[Shotnix] History persist failed: unable to encode full image")
            return nil
        }

        do {
            try pngFull.write(to: URL(fileURLWithPath: imagePath), options: .atomic)
            applyScreenshotMetadata(to: imagePath, rect: rect, type: type)
        } catch {
            print("[Shotnix] History persist failed at \(imagePath): \(error)")
            return nil
        }

        // Thumbnail via CoreGraphics (thread-safe, ~2–3× faster than lockFocus).
        guard let thumbCG = downsample(cg: fullCG, maxDimension: 240),
              let pngThumb = ImageExporter.pngData(from: thumbCG) else { return nil }
        do {
            try pngThumb.write(to: URL(fileURLWithPath: thumbPath), options: .atomic)
            let logicalSize = NSSize(width: thumbCG.width, height: thumbCG.height)
            return HistoryImageBox(image: CaptureEngine.nsImage(from: thumbCG, logicalSize: logicalSize))
        } catch {
            print("[Shotnix] History thumbnail persist failed at \(thumbPath): \(error)")
            return nil
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

    nonisolated static func applyScreenshotMetadata(to path: String, rect: CGRect?, type: CaptureType? = nil) {
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

        // Screenshot type, in the vocabulary macOS uses for its own captures.
        let screenCaptureType: String
        switch type {
        case .window: screenCaptureType = "window"
        case .fullscreen: screenCaptureType = "display"
        default: screenCaptureType = "selection"
        }
        let typeData = try? PropertyListSerialization.data(fromPropertyList: screenCaptureType as NSString, format: .binary, options: 0)
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
