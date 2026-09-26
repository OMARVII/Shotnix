import CryptoKit
import Foundation

/// Where video drafts, recording metadata, and the export index live.
/// Tests point it at a temporary folder so they never touch real data.
enum VideoStorageLocation {
    nonisolated(unsafe) static var overrideRoot: URL?

    static var root: URL {
        overrideRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}

/// How the editor recognises a video file across renames and moves: a
/// recording ID stamped on the file itself (an extended attribute, which
/// Finder keeps when moving, renaming, or copying), with the file's path as
/// the fallback. Keys are short hashes, so any path length works.
enum VideoFileIdentity {
    static let attribute = "com.shotnix.recording-id"

    /// The same file however it was reached (symlinks resolved).
    static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The recording ID for this file: the one stamped on it — or, if the
    /// stamp was stripped (some tools drop extended attributes), the ID last
    /// seen at this path for a file of this size, stamped back on.
    static func id(of url: URL) -> String? {
        let canonical = canonicalURL(url)
        if let stamped = readStamp(canonical) { return stamped }
        guard let pointer = readPointer(for: canonical),
              let size = fingerprint(canonical)?.size, pointer.size == size else { return nil }
        _ = writeStamp(pointer.id, on: canonical)
        return pointer.id
    }

    /// The file's recording ID, stamping a new one if it has none. Nil when
    /// the file can't keep one (a read-only volume): the path is used then.
    @discardableResult
    static func ensureID(of url: URL) -> String? {
        let canonical = canonicalURL(url)
        if let existing = id(of: canonical) {
            writePointer(existing, for: canonical)
            return existing
        }
        return restamp(canonical)
    }

    /// A new ID (a copy carried its original's).
    static func restamp(_ url: URL) -> String? {
        let canonical = canonicalURL(url)
        let value = UUID().uuidString
        guard writeStamp(value, on: canonical) else { return nil }
        writePointer(value, for: canonical)
        return value
    }

    static func idKey(_ id: String) -> String { "id-\(id)" }

    /// A fixed-length key for the file's path.
    static func pathKey(_ url: URL) -> String {
        SHA256.hash(data: Data(canonicalURL(url).path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// How older versions named files (base64 of the path — too long for
    /// deep folders). Read, then moved to the new name.
    static func legacyKey(_ url: URL) -> String {
        Data(url.standardizedFileURL.path.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The ID stamped on the file, read only (nothing is written — for
    /// looking through other files).
    static func stampedID(of url: URL) -> String? {
        readStamp(canonicalURL(url))
    }

    /// The size of the file last stamped at this path (it may be gone).
    static func lastKnownSize(at url: URL) -> Int64? {
        readPointer(for: canonicalURL(url))?.size
    }

    /// The ID an ID note (a VideoIDs file) records.
    static func pointerID(in noteURL: URL) -> String? {
        guard let data = try? Data(contentsOf: noteURL) else { return nil }
        return (try? JSONDecoder().decode(Pointer.self, from: data))?.id
    }

    /// Size and modification date: a different file saved under the same
    /// name has other ones.
    static func fingerprint(_ url: URL) -> (size: Int64, modified: Date)? {
        guard let values = try? canonicalURL(url).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return (Int64(size), modified)
    }

    // MARK: The stamp

    private static func readStamp(_ canonical: URL) -> String? {
        canonical.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0, size < 128 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard getxattr(path, attribute, &buffer, size, 0, XATTR_NOFOLLOW) == size else { return nil }
            let value = String(decoding: buffer, as: UTF8.self)
            return UUID(uuidString: value) != nil ? value : nil
        }
    }

    /// Writes the stamp and reads it back (some file systems accept the
    /// write but don't keep it).
    private static func writeStamp(_ value: String, on canonical: URL) -> Bool {
        let written = canonical.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return value.withCString { setxattr(path, attribute, $0, strlen($0), 0, XATTR_NOFOLLOW) == 0 }
        }
        return written && readStamp(canonical) == value
    }

    // MARK: Pointers (path → ID), for when a stamp goes missing

    private struct Pointer: Codable, Equatable {
        let id: String
        let size: Int64?
    }

    private static func pointerURL(for canonical: URL) -> URL {
        VideoStorageLocation.root
            .appendingPathComponent("Shotnix", isDirectory: true)
            .appendingPathComponent("VideoIDs", isDirectory: true)
            .appendingPathComponent(pathKey(canonical))
            .appendingPathExtension("json")
    }

    private static func readPointer(for canonical: URL) -> Pointer? {
        guard let data = try? Data(contentsOf: pointerURL(for: canonical)) else { return nil }
        return try? JSONDecoder().decode(Pointer.self, from: data)
    }

    private static func writePointer(_ id: String, for canonical: URL) {
        let pointer = Pointer(id: id, size: fingerprint(canonical)?.size)
        guard readPointer(for: canonical) != pointer, let data = try? JSONEncoder().encode(pointer) else { return }
        let url = pointerURL(for: canonical)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

struct VideoDemoDraftRecord: Codable, Equatable {
    var sourcePath: String
    var savedAt: Date
    var project: VideoDemoProject
    /// The video the draft was made for, so a different file saved under
    /// the same name doesn't inherit its edits.
    var sourceSize: Int64? = nil
    var sourceModified: Date? = nil
    /// Finds the video again after a rename or a move on the same drive
    /// (the leftover-data cleanup looks it up).
    var sourceBookmark: Data? = nil
}

enum VideoDemoDraftStore {
    /// Just who a draft belongs to (without decoding the whole project).
    private struct Owner: Decodable {
        let sourcePath: String
        var resolved: String { URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().path }
    }

    private static func owner(of url: URL) -> Owner? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Owner.self, from: data)
    }

    static func load(for videoURL: URL, baseDirectory: URL? = nil) -> VideoDemoDraftRecord? {
        let folder = directory(baseDirectory: baseDirectory)
        let canonical = VideoFileIdentity.canonicalURL(videoURL)
        let size = VideoFileIdentity.fingerprint(canonical)?.size
        func url(_ key: String) -> URL { folder.appendingPathComponent(key).appendingPathExtension("json") }
        let idURL = VideoFileIdentity.id(of: canonical).map { url(VideoFileIdentity.idKey($0)) }

        /// A readable draft made for a file of this size (else set aside —
        /// never silently dropped or overwritten).
        func record(at url: URL) -> VideoDemoDraftRecord? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(VideoDemoDraftRecord.self, from: data) else {
                setAside(url, reason: "unreadable")
                return nil
            }
            if let recorded = record.sourceSize, let size, recorded != size {
                setAside(url, reason: "other-file")
                return nil
            }
            return record
        }

        // 1. This file's own draft, by ID or by path.
        if let idURL, FileManager.default.fileExists(atPath: idURL.path) {
            if let owner = owner(of: idURL) {
                if owner.resolved == canonical.path, let record = record(at: idURL) { return record }
            } else {
                // Unreadable (a newer version wrote it?): kept, not overwritten.
                setAside(idURL, reason: "unreadable")
            }
        }
        if let record = record(at: url(VideoFileIdentity.pathKey(canonical))) {
            return record
        }
        // 2. Its ID's draft from where it used to be (moved or renamed) —
        // not while that file is still there (this one is a copy).
        if let idURL, let owner = owner(of: idURL), !FileManager.default.fileExists(atPath: owner.resolved), let record = record(at: idURL) {
            return record
        }
        // 3. Earlier versions' names.
        return record(at: url(VideoFileIdentity.legacyKey(videoURL)))
    }

    @discardableResult
    static func save(_ project: VideoDemoProject, for videoURL: URL, baseDirectory: URL? = nil) -> Bool {
        let folder = directory(baseDirectory: baseDirectory)
        let canonical = VideoFileIdentity.canonicalURL(videoURL)
        var id = VideoFileIdentity.ensureID(of: canonical)
        // A copy carries its original's ID: give it its own (bringing the
        // recording's data along) rather than share or take over a draft.
        if let current = id,
           let owner = owner(of: folder.appendingPathComponent(VideoFileIdentity.idKey(current)).appendingPathExtension("json")),
           owner.resolved != canonical.path, FileManager.default.fileExists(atPath: owner.resolved) {
            id = VideoFileIdentity.restamp(canonical)
            if let fresh = id { VideoDemoSidecarStore.copyData(fromID: current, toID: fresh) }
        }
        let key = id.map(VideoFileIdentity.idKey) ?? VideoFileIdentity.pathKey(canonical)
        let url = folder.appendingPathComponent(key).appendingPathExtension("json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let fingerprint = VideoFileIdentity.fingerprint(canonical)
            let record = VideoDemoDraftRecord(
                sourcePath: canonical.path,
                savedAt: Date(),
                project: project,
                sourceSize: fingerprint?.size,
                sourceModified: fingerprint?.modified,
                sourceBookmark: try? canonical.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            )
            try encoder.encode(record).write(to: url, options: .atomic)
            // This file's drafts under older names are superseded.
            for old in [VideoFileIdentity.pathKey(canonical), VideoFileIdentity.legacyKey(videoURL)] where old != key {
                let oldURL = folder.appendingPathComponent(old).appendingPathExtension("json")
                if let owner = owner(of: oldURL), owner.resolved != canonical.path { continue }
                try? FileManager.default.removeItem(at: oldURL)
            }
            return true
        } catch {
            print("[Shotnix] Video draft save failed: \(error)")
            return false
        }
    }

    @discardableResult
    static func delete(for videoURL: URL, baseDirectory: URL? = nil) -> Bool {
        let folder = directory(baseDirectory: baseDirectory)
        let canonical = VideoFileIdentity.canonicalURL(videoURL)
        var keys = [VideoFileIdentity.pathKey(canonical), VideoFileIdentity.legacyKey(videoURL)]
        if let id = VideoFileIdentity.id(of: canonical) { keys.append(VideoFileIdentity.idKey(id)) }
        var ok = true
        for key in keys {
            let url = folder.appendingPathComponent(key).appendingPathExtension("json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { try FileManager.default.removeItem(at: url) } catch {
                print("[Shotnix] Video draft delete failed: \(error)")
                ok = false
            }
        }
        return ok
    }

    private static func setAside(_ url: URL, reason: String) {
        let aside = url.deletingPathExtension().appendingPathExtension("\(reason)-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: aside)
    }

    private static func directory(baseDirectory: URL?) -> URL {
        let root = baseDirectory ?? VideoStorageLocation.root
        return root
            .appendingPathComponent("Shotnix", isDirectory: true)
            .appendingPathComponent("VideoDrafts", isDirectory: true)
    }
}

struct VideoDemoRecentExport: Codable, Equatable, Identifiable {
    var id: UUID
    var sourcePath: String
    var exportPath: String
    var exportedAt: Date
    var fileSize: Int

    var exportURL: URL {
        URL(fileURLWithPath: exportPath)
    }

    init(id: UUID = UUID(), sourcePath: String, exportPath: String, exportedAt: Date = Date(), fileSize: Int = 0) {
        self.id = id
        self.sourcePath = sourcePath
        self.exportPath = exportPath
        self.exportedAt = exportedAt
        self.fileSize = fileSize
    }
}

enum VideoDemoRecentExportStore {
    static let maximumItems = 8

    static func load(baseDirectory: URL? = nil) -> [VideoDemoRecentExport] {
        let url = indexURL(baseDirectory: baseDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([VideoDemoRecentExport].self, from: data)
        } catch {
            print("[Shotnix] Recent video exports load failed: \(error)")
            return []
        }
    }

    static func load(for sourceURL: URL, baseDirectory: URL? = nil) -> [VideoDemoRecentExport] {
        let sourcePath = sourceURL.standardizedFileURL.path
        return load(baseDirectory: baseDirectory).filter { $0.sourcePath == sourcePath }
    }

    @discardableResult
    static func add(exportURL: URL, sourceURL: URL, baseDirectory: URL? = nil) -> [VideoDemoRecentExport] {
        let fileSize = (try? exportURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sourcePath = sourceURL.standardizedFileURL.path
        let exportPath = exportURL.standardizedFileURL.path
        let entry = VideoDemoRecentExport(
            sourcePath: sourcePath,
            exportPath: exportPath,
            fileSize: max(fileSize, 0)
        )
        var exports = load(baseDirectory: baseDirectory)
            .filter { $0.exportPath != exportPath }
        exports.insert(entry, at: 0)
        exports = Array(exports.prefix(maximumItems))
        save(exports, baseDirectory: baseDirectory)
        return exports.filter { $0.sourcePath == sourcePath }
    }

    @discardableResult
    static func save(_ exports: [VideoDemoRecentExport], baseDirectory: URL? = nil) -> Bool {
        let url = indexURL(baseDirectory: baseDirectory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(exports).write(to: url, options: .atomic)
            return true
        } catch {
            print("[Shotnix] Recent video exports save failed: \(error)")
            return false
        }
    }

    private static func indexURL(baseDirectory: URL?) -> URL {
        let root = baseDirectory ?? VideoStorageLocation.root
        return root
            .appendingPathComponent("Shotnix", isDirectory: true)
            .appendingPathComponent("VideoExports", isDirectory: true)
            .appendingPathComponent("recent.json", isDirectory: false)
    }
}
