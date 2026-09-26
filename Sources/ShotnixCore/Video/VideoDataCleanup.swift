import AppKit
import SwiftUI

/// Video data Shotnix keeps beside recordings: camera footage (~750 MB per
/// 30 minutes), the cleaned-up voice, drafts, each recording's own data,
/// pictures and songs added to videos, and clipboard exports.
///
/// The sweep only removes what belongs to recordings that are gone for
/// good — not at their path, not in the Trash, not on a drive that's
/// unplugged, and not found anywhere else by Spotlight — plus clipboard
/// exports older than a day. Anything touched in the last day is left
/// alone (a recording being saved, a draft being written).
enum VideoDataCleanup {
    struct Report: Equatable {
        var removedFiles = 0
        var freedBytes: Int64 = 0
    }

    /// Finds a moved recording by name (Spotlight in the app; tests swap it).
    typealias Finder = @Sendable (_ fileName: String) -> [URL]

    static let grace: TimeInterval = 24 * 3600

    /// Tests point these at throwaway folders.
    nonisolated(unsafe) static var clipboardExportsOverride: URL?
    nonisolated(unsafe) static var trashOverride: URL?

    private static var shotnixFolder: URL {
        VideoStorageLocation.root.appendingPathComponent("Shotnix", isDirectory: true)
    }

    static var clipboardExports: URL {
        clipboardExportsOverride ?? FileManager.default.temporaryDirectory.appendingPathComponent("Shotnix Exports", isDirectory: true)
    }

    private static var trash: URL {
        trashOverride ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    /// Every folder the video editor writes to.
    static var folders: [URL] {
        ["VideoCameras", "VideoAudio", "VideoDrafts", "VideoMetadata", "VideoIDs", "VideoAssets"].map {
            shotnixFolder.appendingPathComponent($0, isDirectory: true)
        } + [clipboardExports]
    }

    // MARK: Usage

    /// Bytes on disk used by video data.
    static func usage() -> Int64 {
        folders.reduce(0) { $0 + size(of: $1) }
    }

    private static func size(of folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Sweep

    private struct Record {
        let url: URL
        let key: String
        let recordingPath: String
        let recordingSize: Int64?
    }

    private struct DraftOwner: Decodable {
        let sourcePath: String
        let sourceSize: Int64?
    }

    private struct SidecarOwner: Decodable {
        struct Webcam: Decodable { let path: String }
        let videoURLPath: String
        let webcam: Webcam?
    }

    private struct IDPointer: Decodable {
        let id: String
    }

    /// Removes leftover data (see the type's notes). Safe to run any time,
    /// off the main thread.
    @discardableResult
    static func sweep(now: Date = Date(), finder: Finder = spotlight) -> Report {
        var report = Report()
        let fileManager = FileManager.default
        let drafts = records(in: "VideoDrafts") { data in
            (try? JSONDecoder().decode(DraftOwner.self, from: data)).map { ($0.sourcePath, $0.sourceSize) }
        }
        var webcams: [String: String] = [:]
        let sidecars = records(in: "VideoMetadata") { data in
            guard let owner = try? JSONDecoder().decode(SidecarOwner.self, from: data) else { return nil }
            return (owner.videoURLPath, nil)
        }
        for sidecar in sidecars {
            if let data = try? Data(contentsOf: sidecar.url), let owner = try? JSONDecoder().decode(SidecarOwner.self, from: data), let webcam = owner.webcam {
                webcams[sidecar.url.path] = webcam.path
            }
        }

        // A recording is alive when any record that knows it finds it.
        var aliveKeys = Set<String>()
        var alivePaths = Set<String>()
        var lookedUp: [String: Bool] = [:]
        func alive(_ record: Record) -> Bool {
            let cacheKey = record.key + "|" + record.recordingPath
            if let known = lookedUp[cacheKey] { return known }
            let found = recordingExists(path: record.recordingPath, key: record.key, size: record.recordingSize, finder: finder)
            lookedUp[cacheKey] = found
            return found
        }
        for record in drafts + sidecars where alive(record) {
            aliveKeys.insert(record.key)
            alivePaths.insert(record.recordingPath)
        }

        func old(_ url: URL) -> Bool {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return now.timeIntervalSince(modified) > grace
        }
        func remove(_ url: URL) {
            let bytes = Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            guard (try? fileManager.removeItem(at: url)) != nil else { return }
            report.removedFiles += 1
            report.freedBytes += bytes
        }

        // Drafts and recording data of recordings that are gone.
        var keptCameras = Set<String>()
        for record in drafts where !aliveKeys.contains(record.key) && old(record.url) {
            remove(record.url)
        }
        for record in sidecars {
            if aliveKeys.contains(record.key) {
                if let webcam = webcams[record.url.path] { keptCameras.insert(URL(fileURLWithPath: webcam).standardizedFileURL.path) }
            } else if old(record.url) {
                remove(record.url)
            } else if let webcam = webcams[record.url.path] {
                keptCameras.insert(URL(fileURLWithPath: webcam).standardizedFileURL.path)
            }
        }

        // Camera footage no live recording points to.
        for url in files(in: "VideoCameras") where !keptCameras.contains(url.standardizedFileURL.path) && old(url) {
            remove(url)
        }

        // Cleaned-up voice for recordings that are gone (or changed since).
        var keptVoice = Set<String>()
        for path in alivePaths {
            let url = URL(fileURLWithPath: path)
            for track in 0..<4 {
                keptVoice.insert(VideoVoiceEnhancer.cacheURL(for: url, trackIndex: track).standardizedFileURL.path)
            }
        }
        for url in files(in: "VideoAudio") where !keptVoice.contains(url.standardizedFileURL.path) && old(url) {
            remove(url)
        }

        // Pictures and songs no remaining draft uses.
        let liveDrafts = drafts.filter { aliveKeys.contains($0.key) || !old($0.url) }
        let draftTexts = liveDrafts.compactMap { try? String(contentsOf: $0.url, encoding: .utf8) }
        for url in files(in: "VideoAssets") where old(url) {
            let name = url.lastPathComponent
            if !draftTexts.contains(where: { $0.contains(name) }) { remove(url) }
        }

        // ID pointers of recordings nothing knows any more.
        for url in files(in: "VideoIDs") where old(url) {
            guard let data = try? Data(contentsOf: url),
                  let pointer = try? JSONDecoder().decode(IDPointer.self, from: data) else { continue }
            if !aliveKeys.contains(VideoFileIdentity.idKey(pointer.id)) { remove(url) }
        }

        // Clipboard exports and working files older than a day.
        for url in (try? fileManager.contentsOfDirectory(at: clipboardExports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where old(url) {
            remove(url)
        }
        if clipboardExportsOverride == nil {
            let temporary = fileManager.temporaryDirectory
            for url in (try? fileManager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where (url.lastPathComponent.hasPrefix("shotnix-export-") || url.lastPathComponent.contains(".shotnix-partial.")) && old(url) {
                remove(url)
            }
        }
        return report
    }

    private static func files(in folder: String) -> [URL] {
        let url = shotnixFolder.appendingPathComponent(folder, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private static func records(in folder: String, owner: (Data) -> (String, Int64?)?) -> [Record] {
        files(in: folder).filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let (path, size) = owner(data) else { return nil }
            return Record(url: url, key: url.deletingPathExtension().lastPathComponent, recordingPath: path, recordingSize: size)
        }
    }

    /// Whether a recording can still be found: at its path, on a drive
    /// that isn't plugged in (unknown — kept), in the Trash (it can come
    /// back), or somewhere else Spotlight knows with the same ID.
    static func recordingExists(path: String, key: String, size: Int64?, finder: Finder) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) { return true }
        let components = URL(fileURLWithPath: path).pathComponents
        if components.count > 2, components[1] == "Volumes", !fileManager.fileExists(atPath: "/Volumes/\(components[2])") {
            return true
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        if fileManager.fileExists(atPath: trash.appendingPathComponent(name).path) { return true }
        if components.count > 2, components[1] == "Volumes" {
            let volumeTrash = URL(fileURLWithPath: "/Volumes/\(components[2])/.Trashes/\(getuid())/\(name)")
            if fileManager.fileExists(atPath: volumeTrash.path) { return true }
        }
        let id = key.hasPrefix("id-") ? String(key.dropFirst(3)) : nil
        for candidate in finder(name) where candidate.lastPathComponent == name {
            if let id {
                if VideoFileIdentity.id(of: candidate) == id { return true }
            } else if let size, VideoFileIdentity.fingerprint(candidate)?.size == size {
                return true
            }
        }
        return false
    }

    /// Spotlight lookup by exact file name (a few seconds at most).
    static let spotlight: Finder = { name in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-name", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    // MARK: Launch

    /// Sweeps quietly after launch, at most once a day, off the main thread.
    @MainActor
    static func sweepAfterLaunch() {
        if let last = Settings.videoDataLastSweep, Date().timeIntervalSince(last) < grace { return }
        Settings.videoDataLastSweep = Date()
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 30) {
            let report = sweep()
            if report.removedFiles > 0 {
                print("[Shotnix] Cleaned up \(report.removedFiles) leftover video files (\(ByteCountFormatter.string(fromByteCount: report.freedBytes, countStyle: .file)))")
            }
        }
    }
}

// MARK: - Settings

/// "Video data uses 1.2 GB" with a Clean Up button, for the Recording pane.
struct VideoDataSettingsRow: View {
    @State private var usage: Int64?
    @State private var working = false
    @State private var result: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(usage.map { "Video data uses \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? "Video data")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(1)
                Text(result ?? "Camera footage, cleaned-up voice, drafts, and clipboard exports")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if working {
                ProgressView().controlSize(.small)
            }
            Button("Clean Up") { cleanUp() }
                .controlSize(.small)
                .disabled(working)
                .help("Removes data for recordings that no longer exist anywhere, and clipboard exports older than a day")
        }
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .padding(.horizontal, 12)
        .task { await measure() }
    }

    private func measure() async {
        usage = await Task.detached(priority: .utility) { VideoDataCleanup.usage() }.value
    }

    private func cleanUp() {
        working = true
        result = nil
        Task {
            let report = await Task.detached(priority: .userInitiated) { VideoDataCleanup.sweep() }.value
            working = false
            result = report.removedFiles == 0
                ? "Nothing to clean up — everything belongs to recordings you still have"
                : "Freed \(ByteCountFormatter.string(fromByteCount: report.freedBytes, countStyle: .file)) (\(report.removedFiles) file\(report.removedFiles == 1 ? "" : "s"))"
            await measure()
        }
    }
}
