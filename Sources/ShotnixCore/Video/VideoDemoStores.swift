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

    /// The recording ID stamped on the file, if any.
    static func id(of url: URL) -> String? {
        canonicalURL(url).withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0, size < 128 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            guard getxattr(path, attribute, &buffer, size, 0, XATTR_NOFOLLOW) == size else { return nil }
            let value = String(decoding: buffer, as: UTF8.self)
            return UUID(uuidString: value) != nil ? value : nil
        }
    }

    /// The file's recording ID, stamping a new one if it has none. Nil when
    /// the file can't take one (read-only volume).
    @discardableResult
    static func ensureID(of url: URL) -> String? {
        if let existing = id(of: url) { return existing }
        let value = UUID().uuidString
        let stamped = canonicalURL(url).withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return value.withCString { setxattr(path, attribute, $0, strlen($0), 0, XATTR_NOFOLLOW) == 0 }
        }
        return stamped ? value : nil
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

    /// Size and modification date: a different file saved under the same
    /// name has other ones.
    static func fingerprint(_ url: URL) -> (size: Int64, modified: Date)? {
        guard let values = try? canonicalURL(url).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return (Int64(size), modified)
    }
}

struct VideoDemoDraftRecord: Codable, Equatable {
    var sourcePath: String
    var savedAt: Date
    var project: VideoDemoProject
    /// The video the draft was made for (size and date), so a new file with
    /// the same name doesn't inherit someone else's edits.
    var sourceSize: Int64? = nil
    var sourceModified: Date? = nil
}

enum VideoDemoDraftStore {
    static func load(for videoURL: URL, baseDirectory: URL? = nil) -> VideoDemoDraftRecord? {
        let folder = directory(baseDirectory: baseDirectory)
        let canonical = VideoFileIdentity.canonicalURL(videoURL)
        let fingerprint = VideoFileIdentity.fingerprint(canonical)
        var keys: [String] = []
        if let id = VideoFileIdentity.id(of: canonical) { keys.append(VideoFileIdentity.idKey(id)) }
        keys += [VideoFileIdentity.pathKey(canonical), VideoFileIdentity.legacyKey(videoURL)]
        for key in keys {
            let url = folder.appendingPathComponent(key).appendingPathExtension("json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(VideoDemoDraftRecord.self, from: data) else {
                // Unreadable (a newer version wrote it?): set it aside
                // rather than overwrite it.
                let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: aside)
                continue
            }
            // A different video under the same name: not its draft.
            if let size = record.sourceSize, let modified = record.sourceModified, let fingerprint,
               size != fingerprint.size || abs(modified.timeIntervalSince(fingerprint.modified)) > 1 {
                continue
            }
            // A copy of the file (the original is still there): start fresh.
            let owner = URL(fileURLWithPath: record.sourcePath).resolvingSymlinksInPath().path
            if owner != canonical.path, FileManager.default.fileExists(atPath: owner) {
                continue
            }
            return record
        }
        return nil
    }

    @discardableResult
    static func save(_ project: VideoDemoProject, for videoURL: URL, baseDirectory: URL? = nil) -> Bool {
        let folder = directory(baseDirectory: baseDirectory)
        let canonical = VideoFileIdentity.canonicalURL(videoURL)
        var key = VideoFileIdentity.ensureID(of: canonical).map(VideoFileIdentity.idKey) ?? VideoFileIdentity.pathKey(canonical)
        // A copy carries the original's ID: it keeps its own draft by path
        // instead of overwriting the original's.
        let idURL = folder.appendingPathComponent(key).appendingPathExtension("json")
        if key.hasPrefix("id-"), let data = try? Data(contentsOf: idURL),
           let record = try? JSONDecoder().decode(VideoDemoDraftRecord.self, from: data) {
            let owner = URL(fileURLWithPath: record.sourcePath).resolvingSymlinksInPath().path
            if owner != canonical.path, FileManager.default.fileExists(atPath: owner) {
                key = VideoFileIdentity.pathKey(canonical)
            }
        }
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
                sourceModified: fingerprint?.modified
            )
            try encoder.encode(record).write(to: url, options: .atomic)
            // Drafts under older names are superseded.
            for old in [VideoFileIdentity.pathKey(canonical), VideoFileIdentity.legacyKey(videoURL)] where old != key {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(old).appendingPathExtension("json"))
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
