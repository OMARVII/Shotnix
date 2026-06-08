import Foundation

struct VideoDemoDraftRecord: Codable, Equatable {
    var sourcePath: String
    var savedAt: Date
    var project: VideoDemoProject
}

enum VideoDemoDraftStore {
    static func draftURL(for videoURL: URL, baseDirectory: URL? = nil) -> URL {
        directory(baseDirectory: baseDirectory)
            .appendingPathComponent(fileKey(for: videoURL), isDirectory: false)
            .appendingPathExtension("json")
    }

    static func load(for videoURL: URL, baseDirectory: URL? = nil) -> VideoDemoDraftRecord? {
        let url = draftURL(for: videoURL, baseDirectory: baseDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(VideoDemoDraftRecord.self, from: data)
        } catch {
            print("[Shotnix] Video draft load failed: \(error)")
            return nil
        }
    }

    @discardableResult
    static func save(_ project: VideoDemoProject, for videoURL: URL, baseDirectory: URL? = nil) -> Bool {
        let url = draftURL(for: videoURL, baseDirectory: baseDirectory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let record = VideoDemoDraftRecord(
                sourcePath: videoURL.standardizedFileURL.path,
                savedAt: Date(),
                project: project
            )
            try encoder.encode(record).write(to: url, options: .atomic)
            return true
        } catch {
            print("[Shotnix] Video draft save failed: \(error)")
            return false
        }
    }

    @discardableResult
    static func delete(for videoURL: URL, baseDirectory: URL? = nil) -> Bool {
        let url = draftURL(for: videoURL, baseDirectory: baseDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            print("[Shotnix] Video draft delete failed: \(error)")
            return false
        }
    }

    private static func directory(baseDirectory: URL?) -> URL {
        let root = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("Shotnix", isDirectory: true)
            .appendingPathComponent("VideoDrafts", isDirectory: true)
    }

    private static func fileKey(for videoURL: URL) -> String {
        Data(videoURL.standardizedFileURL.path.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
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
        let root = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("Shotnix", isDirectory: true)
            .appendingPathComponent("VideoExports", isDirectory: true)
            .appendingPathComponent("recent.json", isDirectory: false)
    }
}
