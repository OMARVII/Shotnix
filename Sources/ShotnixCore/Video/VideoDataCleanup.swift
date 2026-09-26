import AppKit
import SwiftUI

/// Video data Shotnix keeps beside recordings: camera footage (~750 MB per
/// 30 minutes), the cleaned-up voice, drafts, each recording's own data,
/// pictures and songs added to videos, and clipboard exports.
///
/// Two ways it goes away:
/// - Quietly, once a day after launch: only clipboard exports older than a
///   day (and, at launch, Shotnix's own unfinished export files). Nothing
///   that belongs to a recording is ever removed on its own: a recording
///   that can't be found (renamed, moved, on a drive that isn't plugged in,
///   somewhere Spotlight doesn't look) may come back, and its camera footage
///   and pointer data can't be made again. The sweep only notes since when
///   a recording has been missing.
/// - Settings → Clean Up: data of recordings not found right now, camera
///   footage and cleaned-up voice nothing uses, and pictures and songs no
///   video uses — listed by name before anything is removed.
enum VideoDataCleanup {
    struct Report: Equatable {
        var removedFiles = 0
        var freedBytes: Int64 = 0
    }

    /// Looks moved recordings up (Spotlight in the app; tests swap it).
    struct Finder: Sendable {
        /// Files with exactly this name.
        var byName: @Sendable (_ fileName: String) -> [URL]
        /// Movies of exactly this many bytes.
        var bySize: @Sendable (_ bytes: Int64) -> [URL]

        static let spotlight = Finder(
            byName: { VideoDataCleanup.mdfind(["-name", $0]) },
            bySize: { VideoDataCleanup.mdfind(["kMDItemFSSize == \($0) && kMDItemContentTypeTree == 'public.movie'"]) }
        )
        static let nowhere = Finder(byName: { _ in [] }, bySize: { _ in [] })
    }

    /// Data touched this recently is never removed (a recording being
    /// saved, a draft being written).
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
            total += bytes(of: url)
        }
        return total
    }

    static func bytes(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return 0 }
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    // MARK: Recordings

    /// What Shotnix keeps for one recording, and how to find the recording.
    struct Recording: Equatable {
        /// "id-…" (the ID stamped on the file) or a hash of its old path.
        let key: String
        /// Where it was last seen.
        var path: String
        var bookmark: Data?
        var size: Int64?
        var draft: URL?
        var sidecar: URL?
        /// Its camera footage (only ever a file in Shotnix's own folder).
        var camera: URL?

        var id: String? { key.hasPrefix("id-") ? String(key.dropFirst(3)) : nil }
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
        var dataFiles: [URL] { [draft, sidecar, camera].compactMap { $0 } }
    }

    enum Whereabouts: Equatable {
        case found(URL)
        /// On a drive that isn't plugged in: can't tell.
        case unknown
        case missing
    }

    private struct DraftOwner: Decodable {
        let sourcePath: String
        let sourceSize: Int64?
        let sourceBookmark: Data?
    }

    private struct SidecarOwner: Decodable {
        struct Webcam: Decodable { let path: String }
        let videoURLPath: String
        let webcam: Webcam?
        let bookmark: Data?
    }

    /// Every recording a draft or a recording's data knows about.
    static func recordings() -> [Recording] {
        var byKey: [String: Recording] = [:]
        let cameras = shotnixFolder.appendingPathComponent("VideoCameras", isDirectory: true).standardizedFileURL.path
        for url in files(in: "VideoMetadata") where url.pathExtension == "json" && isRecordName(url) {
            guard let data = try? Data(contentsOf: url), let owner = try? JSONDecoder().decode(SidecarOwner.self, from: data) else { continue }
            let key = url.deletingPathExtension().lastPathComponent
            var recording = byKey[key] ?? Recording(key: key, path: owner.videoURLPath)
            recording.sidecar = url
            recording.bookmark = recording.bookmark ?? owner.bookmark
            if let webcam = owner.webcam {
                let camera = URL(fileURLWithPath: webcam.path).standardizedFileURL
                if camera.deletingLastPathComponent().path == cameras { recording.camera = camera }
            }
            byKey[key] = recording
        }
        for url in files(in: "VideoDrafts") where url.pathExtension == "json" && isRecordName(url) {
            guard let data = try? Data(contentsOf: url), let owner = try? JSONDecoder().decode(DraftOwner.self, from: data) else { continue }
            let key = url.deletingPathExtension().lastPathComponent
            var recording = byKey[key] ?? Recording(key: key, path: owner.sourcePath)
            // The draft is saved whenever the video is edited: its path is
            // the newest one.
            recording.path = owner.sourcePath
            recording.draft = url
            recording.bookmark = owner.sourceBookmark ?? recording.bookmark
            recording.size = owner.sourceSize ?? recording.size
            byKey[key] = recording
        }
        return byKey.values.map { recording in
            var recording = recording
            if recording.size == nil { recording.size = VideoFileIdentity.lastKnownSize(at: URL(fileURLWithPath: recording.path)) }
            return recording
        }.sorted { $0.key < $1.key }
    }

    /// "id-…json" or a 64-character path hash — not a draft set aside.
    private static func isRecordName(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        return !name.contains(".")
    }

    /// Where a recording is now: at its path; wherever its bookmark leads
    /// (renames and moves on the same drive); in the Trash; next to where it
    /// was under another name; or somewhere Spotlight knows — always
    /// matched by the ID stamped on it, not by its name.
    static func locate(_ recording: Recording, finder: Finder) -> Whereabouts {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: recording.path)
        if fileManager.fileExists(atPath: url.path) { return .found(url) }
        if let bookmark = recording.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
               fileManager.fileExists(atPath: resolved.path) {
                return .found(resolved)
            }
        }
        let name = url.lastPathComponent
        let components = url.pathComponents
        let onVolume = components.count > 2 && components[1] == "Volumes"
        // In the Trash, it can still come back.
        if fileManager.fileExists(atPath: trash.appendingPathComponent(name).path) { return .found(trash.appendingPathComponent(name)) }
        if onVolume {
            let volumeTrash = URL(fileURLWithPath: "/Volumes/\(components[2])/.Trashes/\(getuid())/\(name)")
            if fileManager.fileExists(atPath: volumeTrash.path) { return .found(volumeTrash) }
            // A drive that isn't plugged in: can't tell.
            if !fileManager.fileExists(atPath: "/Volumes/\(components[2])") { return .unknown }
        }
        if let volume = bookmarkVolume(recording.bookmark), !fileManager.fileExists(atPath: volume.path) { return .unknown }

        guard let id = recording.id else {
            // No ID to go by (a drive that can't keep one): the same name
            // and size, as before.
            for candidate in finder.byName(name) where candidate.lastPathComponent == name {
                if let size = recording.size {
                    if VideoFileIdentity.fingerprint(candidate)?.size == size { return .found(candidate) }
                } else if fileManager.fileExists(atPath: candidate.path) {
                    return .found(candidate)
                }
            }
            return .missing
        }
        // Renamed where it was.
        let folder = url.deletingLastPathComponent()
        let siblings = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        for candidate in siblings.prefix(5000) where VideoFileIdentity.stampedID(of: candidate) == id {
            return .found(candidate)
        }
        // Moved (and maybe renamed) somewhere Spotlight looks.
        for candidate in finder.byName(name) where VideoFileIdentity.stampedID(of: candidate) == id {
            return .found(candidate)
        }
        if let size = recording.size {
            for candidate in finder.bySize(size) where VideoFileIdentity.stampedID(of: candidate) == id {
                return .found(candidate)
            }
        }
        return .missing
    }

    /// The drive a bookmark points into (nil: can't tell).
    private static func bookmarkVolume(_ bookmark: Data?) -> URL? {
        guard let bookmark,
              let values = URL.resourceValues(forKeys: [.volumeURLKey], fromBookmarkData: bookmark) else { return nil }
        return values.volume
    }

    // MARK: Missing ledger

    /// When each recording was first found missing (cleared once it turns
    /// up again).
    private struct Ledger: Codable {
        var missingSince: [String: Date] = [:]
    }

    private static var ledgerURL: URL { shotnixFolder.appendingPathComponent("VideoCleanupLedger.json") }

    private static func loadLedger() -> Ledger {
        guard let data = try? Data(contentsOf: ledgerURL), let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else { return Ledger() }
        return ledger
    }

    private static func save(_ ledger: Ledger) {
        try? FileManager.default.createDirectory(at: shotnixFolder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(ledger) { try? data.write(to: ledgerURL, options: .atomic) }
    }

    /// Since when a recording has been missing, sweep after sweep (nil: it
    /// was seen, or not looked for yet).
    static func missingSince(_ key: String) -> Date? {
        loadLedger().missingSince[key]
    }

    // MARK: The quiet sweep

    /// What the daily sweep does (see the type's notes): old clipboard
    /// exports go; recordings that can't be found are only noted.
    @discardableResult
    static func sweep(now: Date = Date(), finder: Finder = .spotlight) -> Report {
        var report = Report()
        var ledger = loadLedger()
        let known = recordings()
        for recording in known {
            switch locate(recording, finder: finder) {
            case .found, .unknown:
                ledger.missingSince[recording.key] = nil
            case .missing:
                ledger.missingSince[recording.key] = ledger.missingSince[recording.key] ?? now
            }
        }
        // Recordings whose data is gone some other way.
        let keys = Set(known.map(\.key))
        ledger.missingSince = ledger.missingSince.filter { keys.contains($0.key) }
        save(ledger)
        removeOldClipboardExports(now: now, into: &report)
        return report
    }

    // MARK: Clean Up (Settings)

    /// Everything Clean Up would remove, grouped so it can be said exactly.
    struct Plan: Equatable {
        /// Recordings that can't be found now, with their data.
        var missingRecordings: [Recording] = []
        /// Camera footage no recording's data points to.
        var unusedCameraFootage: [URL] = []
        /// Cleaned-up voice of recordings not found (or changed since).
        var unusedVoice: [URL] = []
        /// Pictures and songs no draft, open editor, or export uses.
        var unusedAssets: [URL] = []
        var oldClipboardExports: [URL] = []
        /// Small ID notes of recordings nothing knows any more.
        var staleIDNotes: [URL] = []

        var files: [URL] {
            missingRecordings.flatMap(\.dataFiles) + unusedCameraFootage + unusedVoice + unusedAssets + oldClipboardExports + staleIDNotes
        }

        var isEmpty: Bool { files.isEmpty }
        var bytes: Int64 { files.reduce(0) { $0 + VideoDataCleanup.bytes(of: $1) } }

        /// The confirmation's words: every group, and each recording by name.
        var summary: String {
            func size(_ urls: [URL]) -> String {
                ByteCountFormatter.string(fromByteCount: urls.reduce(0) { $0 + VideoDataCleanup.bytes(of: $1) }, countStyle: .file)
            }
            func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
            var lines: [String] = []
            if !missingRecordings.isEmpty {
                let names = missingRecordings.prefix(8).map { recording -> String in
                    let folder = URL(fileURLWithPath: recording.path).deletingLastPathComponent().lastPathComponent
                    return "“\(recording.name)” (was in \(folder))"
                }
                let more = missingRecordings.count > 8 ? ", and \(missingRecordings.count - 8) more" : ""
                lines.append("• Edits, recording details, and camera footage of \(count(missingRecordings.count, "recording", "recordings")) Shotnix can't find (\(size(missingRecordings.flatMap(\.dataFiles)))): \(names.joined(separator: ", "))\(more)")
            }
            if !unusedCameraFootage.isEmpty {
                lines.append("• Camera footage no recording uses — \(count(unusedCameraFootage.count, "file", "files")), \(size(unusedCameraFootage))")
            }
            if !unusedVoice.isEmpty {
                lines.append("• Cleaned-up voice of recordings not found or changed since — \(count(unusedVoice.count, "file", "files")), \(size(unusedVoice))")
            }
            if !unusedAssets.isEmpty {
                lines.append("• Pictures and songs no video uses — \(count(unusedAssets.count, "file", "files")), \(size(unusedAssets))")
            }
            if !oldClipboardExports.isEmpty {
                lines.append("• Clipboard exports older than a day — \(count(oldClipboardExports.count, "file", "files")), \(size(oldClipboardExports))")
            }
            if !staleIDNotes.isEmpty {
                lines.append("• \(count(staleIDNotes.count, "small note", "small notes")) about recordings that are gone")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// What Clean Up would remove now. `inUse` lists pictures and songs in
    /// use outside the saved drafts (open editors' undo and redo, closed
    /// editors' kept history, queued exports).
    static func plan(now: Date = Date(), finder: Finder = .spotlight, inUse: Set<String> = []) -> Plan {
        var plan = Plan()
        let known = recordings()
        var foundURLs: [URL] = []
        var liveKeys = Set<String>()
        for recording in known {
            switch locate(recording, finder: finder) {
            case .found(let url):
                foundURLs.append(url)
                liveKeys.insert(recording.key)
            case .unknown:
                liveKeys.insert(recording.key)
            case .missing:
                // Touched in the last day: kept (it may be mid-save).
                if recording.dataFiles.allSatisfy({ isOld($0, now: now) }) {
                    plan.missingRecordings.append(recording)
                } else {
                    liveKeys.insert(recording.key)
                }
            }
        }
        let live = known.filter { liveKeys.contains($0.key) }

        // Camera footage no recording's data points to.
        let keptCameras = Set(known.compactMap { $0.camera?.standardizedFileURL.path })
        plan.unusedCameraFootage = files(in: "VideoCameras").filter { !keptCameras.contains($0.standardizedFileURL.path) && isOld($0, now: now) }

        // Cleaned-up voice of recordings not found (or changed since).
        var keptVoice = Set<String>()
        for url in foundURLs {
            for track in 0..<4 { keptVoice.insert(VideoVoiceEnhancer.cacheURL(for: url, trackIndex: track).standardizedFileURL.path) }
        }
        plan.unusedVoice = files(in: "VideoAudio").filter { !keptVoice.contains($0.standardizedFileURL.path) && isOld($0, now: now) }

        // Pictures and songs no remaining draft, open editor, or export uses.
        let draftTexts = live.compactMap { $0.draft }.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        let inUseNames = Set(inUse.map { URL(fileURLWithPath: $0).lastPathComponent })
        plan.unusedAssets = files(in: "VideoAssets").filter { url in
            let name = url.lastPathComponent
            return isOld(url, now: now) && !inUseNames.contains(name) && !draftTexts.contains { $0.contains(name) }
        }

        plan.oldClipboardExports = oldClipboardExports(now: now)

        // ID notes of recordings nothing still knows.
        let liveIDs = Set(live.compactMap(\.id))
        plan.staleIDNotes = files(in: "VideoIDs").filter { url in
            guard isOld(url, now: now), let id = VideoFileIdentity.pointerID(in: url) else { return false }
            return !liveIDs.contains(id)
        }
        return plan
    }

    /// Removes exactly what `plan` lists (a file changed since stays).
    @discardableResult
    static func perform(_ plan: Plan, now: Date = Date()) -> Report {
        var report = Report()
        for url in plan.files where isOld(url, now: now) || plan.oldClipboardExports.contains(url) {
            remove(url, into: &report)
        }
        var ledger = loadLedger()
        for recording in plan.missingRecordings { ledger.missingSince[recording.key] = nil }
        save(ledger)
        return report
    }

    // MARK: Helpers

    private static func isOld(_ url: URL, now: Date) -> Bool {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return now.timeIntervalSince(modified) > grace
    }

    private static func remove(_ url: URL, into report: inout Report) {
        let freed = bytes(of: url)
        guard (try? FileManager.default.removeItem(at: url)) != nil else { return }
        report.removedFiles += 1
        report.freedBytes += freed
    }

    private static func oldClipboardExports(now: Date) -> [URL] {
        let fileManager = FileManager.default
        var urls = ((try? fileManager.contentsOfDirectory(at: clipboardExports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { isOld($0, now: now) }
        if clipboardExportsOverride == nil {
            let temporary = fileManager.temporaryDirectory
            urls += ((try? fileManager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { ($0.lastPathComponent.hasPrefix("shotnix-export-") || $0.lastPathComponent.contains(".shotnix-partial.")) && isOld($0, now: now) }
        }
        return urls
    }

    private static func removeOldClipboardExports(now: Date, into report: inout Report) {
        for url in oldClipboardExports(now: now) { remove(url, into: &report) }
    }

    private static func files(in folder: String) -> [URL] {
        let url = shotnixFolder.appendingPathComponent(folder, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    /// Spotlight (a few seconds at most).
    static func mdfind(_ arguments: [String]) -> [URL] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = arguments
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
        return output.split(separator: "\n").prefix(500).map { URL(fileURLWithPath: String($0)) }
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
            Button("Clean Up…") { cleanUp() }
                .controlSize(.small)
                .disabled(working)
                .help("Shows what can be removed — data of recordings Shotnix can't find, unused footage and pictures, old clipboard exports — and asks before removing it")
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
        Task { @MainActor in
            let inUse = VideoDemoEditorWindowController.assetPathsInUse()
            let plan = await Task.detached(priority: .userInitiated) { VideoDataCleanup.plan(inUse: inUse) }.value
            guard !plan.isEmpty else {
                working = false
                result = "Nothing to clean up — everything belongs to recordings you still have"
                return
            }
            // Says exactly what goes before anything does.
            let alert = NSAlert()
            alert.messageText = "Remove \(ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)) of video data?"
            alert.informativeText = plan.summary + "\n\nRecordings in the Trash or on a drive that isn't plugged in keep their data. This can't be undone."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                working = false
                return
            }
            let report = await Task.detached(priority: .userInitiated) { VideoDataCleanup.perform(plan) }.value
            working = false
            result = "Freed \(ByteCountFormatter.string(fromByteCount: report.freedBytes, countStyle: .file)) (\(report.removedFiles) file\(report.removedFiles == 1 ? "" : "s"))"
            await measure()
        }
    }
}
