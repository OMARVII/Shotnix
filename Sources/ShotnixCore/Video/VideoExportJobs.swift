import AppKit
import AVFoundation
import SwiftUI

// MARK: - Files

enum VideoExportFiles {
    /// A hidden file next to where the video goes — the same disk, so the
    /// final swap is instant — or the temporary folder when that folder
    /// can't be written.
    static func temporaryURL(beside destination: URL, fileExtension: String) -> URL {
        let folder = destination.deletingLastPathComponent()
        let name = ".\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).shotnix-partial.\(fileExtension)"
        if FileManager.default.isWritableFile(atPath: folder.path) {
            return folder.appendingPathComponent(name)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    /// Free space where `url` would be written (the space macOS would make
    /// for important files, purgeable caches included).
    static func availableBytes(at url: URL) -> Int64? {
        var folder = url.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            folder = folder.deletingLastPathComponent()
        }
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    static func volumeName(at url: URL) -> String {
        (try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "this disk"
    }

    /// Stops before starting when the estimate can't fit.
    static func checkSpace(for url: URL, needed: Int64, available: Int64? = nil) throws {
        guard let free = available ?? availableBytes(at: url) else { return }
        let margin: Int64 = 50_000_000
        guard free < needed + margin else { return }
        throw VideoDemoExportError.exportFailed(
            "There isn't enough free space on “\(volumeName(at: url))”: this export needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) and \(ByteCountFormatter.string(fromByteCount: max(free, 0), countStyle: .file)) is free. Free up some space (empty the Trash, delete old recordings) or export to another drive."
        )
    }

    /// Removes the working file and the scratch files the writer keeps
    /// beside it ("….sb-…", made while it moves the index to the front).
    static func cleanUp(_ temporary: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: temporary)
        let folder = temporary.deletingLastPathComponent()
        let prefix = temporary.lastPathComponent + ".sb-"
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Puts the finished file in place. An existing file is replaced in one
    /// step, and only once the new one is complete.
    static func replace(_ destination: URL, with temporary: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }
}

// MARK: - Range

enum VideoExportRange: Equatable {
    case whole
    /// Output-timeline seconds.
    case timeline(ClosedRange<Double>)
}

extension VideoDemoProject {
    /// Just the part of the video between two timeline moments, as a
    /// project of its own: clips cut to fit, cards kept only where the range
    /// reaches them, and where the song was at the range's start.
    func trimmed(toTimeline span: ClosedRange<Double>, totalDuration: Double) -> (project: VideoDemoProject, musicOffset: Double) {
        let segments = timelineSegments(totalDuration: totalDuration)
        let full = outputDuration(segments: segments)
        let lower = min(max(span.lowerBound, 0), full)
        let upper = min(max(span.upperBound, lower), full)
        guard upper - lower > 0.05, lower > 0.001 || upper < full - 0.001 else { return (self, 0) }
        let introEnd = timelineLeadIn
        let outroStart = segments.last?.timelineEnd ?? introEnd

        var project = self
        // Cut on the clips alone (no cards: their times start at 0).
        project.cards = VideoTitleCards()
        let clipsEnd = outroStart - introEnd
        let a = min(max(lower - introEnd, 0), clipsEnd)
        let b = min(max(upper - introEnd, 0), clipsEnd)
        if b < clipsEnd - VideoDemoProject.minimumClipDuration, b > a {
            _ = project.deleteTimelineRange(start: b, end: clipsEnd, totalDuration: totalDuration)
        }
        if a > VideoDemoProject.minimumClipDuration {
            _ = project.deleteTimelineRange(start: 0, end: a, totalDuration: totalDuration)
        }
        // The cards the range reaches, shortened to what it covers.
        if cards.intro.enabled, lower < introEnd - 0.05 {
            project.cards.intro = cards.intro
            project.cards.intro.duration = max(introEnd - lower, VideoTitleCard.durationRange.lowerBound)
        }
        if cards.outro.enabled, upper > outroStart + 0.05 {
            project.cards.outro = cards.outro
            project.cards.outro.duration = max(upper - outroStart, VideoTitleCard.durationRange.lowerBound)
        }
        return (project, lower)
    }
}

// MARK: - Failures

/// Export failures in plain words, with what to do next.
enum VideoExportFailure {
    static func message(for error: Error) -> String {
        if let export = error as? VideoDemoExportError {
            switch export {
            case .system(let underlying): return message(for: underlying as NSError, fallback: underlying.localizedDescription)
            case .cancelled: return "Export cancelled."
            default: return export.localizedDescription
            }
        }
        return message(for: error as NSError, fallback: error.localizedDescription)
    }

    private static func message(for error: NSError, fallback: String) -> String {
        if let known = known(error) { return known }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, let known = known(underlying) { return known }
        return "The export stopped unexpectedly (\(fallback)). Try again — if it keeps happening, export at a lower resolution or in H.264."
    }

    static let diskFull = "Your disk is full. Free up some space (empty the Trash, delete old recordings) or export to another drive, then try again."
    static let noPermission = "Shotnix can't save to that folder. Pick another place, like Desktop or Movies, and export again."
    static let readOnly = "That drive is read-only. Pick another place to save, then export again."
    static let missingSource = "The recording's file can't be found — it may have been moved or deleted. Put it back and export again."

    private static func known(_ error: NSError) -> String? {
        switch error.domain {
        case NSCocoaErrorDomain:
            switch error.code {
            case NSFileWriteOutOfSpaceError: return diskFull
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return noPermission
            case NSFileWriteVolumeReadOnlyError: return readOnly
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return missingSource
            default: return nil
            }
        case NSPOSIXErrorDomain:
            switch Int32(error.code) {
            case ENOSPC, EDQUOT: return diskFull
            case EACCES, EPERM: return noPermission
            case EROFS: return readOnly
            case ENOENT: return missingSource
            default: return nil
            }
        case AVFoundationErrorDomain:
            switch AVError.Code(rawValue: error.code) {
            case .diskFull?: return diskFull
            case .outOfMemory?: return "Your Mac ran low on memory. Close some apps or pick a lower resolution, then export again."
            case .encoderNotFound?, .encoderTemporarilyUnavailable?:
                return "The video encoder is busy — another app may be recording or exporting. Wait a moment and try again, or choose H.264."
            case .decoderNotFound?, .decoderTemporarilyUnavailable?, .decodeFailed?, .invalidSourceMedia?, .fileFailedToParse?, .fileFormatNotRecognized?:
                return "Part of the recording couldn't be read — the file may be damaged. Try exporting a shorter part of the video."
            case .contentIsProtected?: return "This video is copy-protected and can't be exported."
            case .fileAlreadyExists?: return "A file with that name is in the way. Pick another name and export again."
            default: return nil
            }
        default:
            return nil
        }
    }
}

// MARK: - Queue

/// Exports run in the background, one after another: the editor stays
/// usable, each export works from a snapshot of the project taken when it
/// started, and quitting waits for them (asking first).
@MainActor
final class VideoExportQueue: ObservableObject {
    static let shared = VideoExportQueue()

    @MainActor
    final class Job: ObservableObject, Identifiable {
        enum State: Equatable {
            case queued
            case enhancingVoice(Double)
            case running(VideoDemoExporter.Phase)
            case finished(bytes: Int64)
            case failed(String)
            case cancelled
        }

        let id = UUID()
        let project: VideoDemoProject
        let recording: VideoDemoRecordingMetadata?
        let settings: VideoExportSettings
        let range: VideoExportRange
        let destination: URL
        let toClipboard: Bool
        let queuedAt = Date()
        @Published fileprivate(set) var state: State = .queued
        @Published fileprivate(set) var startedAt: Date?
        /// Share sheet / completion notes ("Exported without Enhance voice").
        @Published fileprivate(set) var note: String?
        /// Subtitles written next to it.
        fileprivate(set) var subtitlesURL: URL?
        fileprivate var cancelRequested = false
        fileprivate var token: AppTermination.Token?
        fileprivate var quitWaiters: [@MainActor () -> Void] = []

        init(project: VideoDemoProject, recording: VideoDemoRecordingMetadata?, settings: VideoExportSettings, range: VideoExportRange, destination: URL, toClipboard: Bool) {
            self.project = project
            self.recording = recording
            self.settings = settings
            self.range = range
            self.destination = destination
            self.toClipboard = toClipboard
        }

        var sourcePath: String { project.sourcePath }
        var isDone: Bool {
            switch state {
            case .finished, .failed, .cancelled: return true
            default: return false
            }
        }

        var progress: Double {
            switch state {
            case .running(.rendering(let value)): return value
            case .finished: return 1
            default: return 0
            }
        }

        /// What it's doing, in words.
        var statusText: String {
            switch state {
            case .queued: return "Waiting…"
            case .enhancingVoice(let value): return "Cleaning up your voice… \(Int((value * 100).rounded()))%"
            case .running(.preparing): return "Preparing…"
            case .running(.balancingLoudness): return "Balancing loudness…"
            case .running(.rendering(let value)): return toClipboard ? "Rendering for the clipboard… \(Int((value * 100).rounded()))%" : "Exporting… \(Int((value * 100).rounded()))%"
            case .finished(let bytes): return toClipboard ? "On your clipboard · \(VideoEditorModel.formatBytes(bytes))" : "Exported · \(VideoEditorModel.formatBytes(bytes))"
            case .failed(let message): return message
            case .cancelled: return "Cancelled"
            }
        }
    }

    @Published private(set) var jobs: [Job] = []
    private var running: Job?
    /// Editors still open, by recording path (finished jobs of closed
    /// editors announce themselves in a small panel instead).
    private var openEditors: [String: Int] = [:]

    func jobs(for sourcePath: String) -> [Job] {
        jobs.filter { $0.sourcePath == sourcePath }
    }

    var isBusy: Bool { jobs.contains { !$0.isDone } }

    @discardableResult
    func enqueue(project: VideoDemoProject, recording: VideoDemoRecordingMetadata?, settings: VideoExportSettings, range: VideoExportRange = .whole, destination: URL, toClipboard: Bool) -> Job {
        let job = Job(project: project, recording: recording, settings: settings, range: range, destination: destination, toClipboard: toClipboard)
        let name = toClipboard ? "a video for the clipboard" : "“\(destination.lastPathComponent)”"
        job.token = AppTermination.begin("Exporting \(name)", asksBeforeQuit: true) { [weak job] done in
            // "Finish and Quit": the export finishes first.
            guard let job, !job.isDone else { return done() }
            job.quitWaiters.append(done)
        }
        jobs.append(job)
        startNext()
        return job
    }

    func cancel(_ job: Job) {
        switch job.state {
        case .queued:
            finish(job, .cancelled)
            startNext()
        case .enhancingVoice, .running:
            job.cancelRequested = true
        default:
            break
        }
    }

    /// Forgets a finished, failed, or cancelled export.
    func dismiss(_ job: Job) {
        guard job.isDone else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func editorOpened(sourcePath: String) {
        openEditors[sourcePath, default: 0] += 1
    }

    func editorClosed(sourcePath: String) {
        openEditors[sourcePath] = max((openEditors[sourcePath] ?? 1) - 1, 0)
    }

    private func finish(_ job: Job, _ state: Job.State) {
        job.state = state
        AppTermination.end(job.token)
        job.token = nil
        let waiters = job.quitWaiters
        job.quitWaiters.removeAll()
        waiters.forEach { $0() }
        if (openEditors[job.sourcePath] ?? 0) == 0, !isRunningTests {
            if case .finished = state { VideoExportCompletionPanel.show(for: job) }
            if case .failed = state { VideoExportCompletionPanel.show(for: job) }
        }
    }

    private var isRunningTests: Bool { NSClassFromString("XCTestCase") != nil }

    private func startNext() {
        guard running == nil, let next = jobs.first(where: { $0.state == .queued }) else { return }
        running = next
        next.startedAt = Date()
        Task { await run(next) }
    }

    private func run(_ job: Job) async {
        defer {
            running = nil
            startNext()
        }
        do {
            let voiceFailed = await enhanceVoiceIfNeeded(job)
            if job.cancelRequested { throw VideoDemoExportError.cancelled }
            job.state = .running(.preparing)
            let bridge = JobBridge(job: job)
            _ = try await VideoDemoExporter.export(
                project: job.project,
                recording: job.recording,
                destinationURL: job.destination,
                settings: job.settings,
                range: job.range,
                phase: { phase in await bridge.phase(phase) },
                shouldCancel: { await bridge.isCancelled() }
            )
            let bytes = (try? job.destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
            if job.toClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([job.destination as NSURL])
            } else {
                VideoDemoRecentExportStore.add(exportURL: job.destination, sourceURL: job.project.sourceURL)
                job.subtitlesURL = writeSubtitles(for: job)
            }
            if voiceFailed { job.note = "Exported without Enhance voice — it couldn't finish." }
            finish(job, .finished(bytes: bytes))
        } catch {
            var cancelled = job.cancelRequested
            if case VideoDemoExportError.cancelled = error { cancelled = true }
            finish(job, cancelled ? .cancelled : .failed(VideoExportFailure.message(for: error)))
        }
    }

    /// The cleaned-up voice has to exist before it can go into the export.
    /// Returns true when it was wanted but couldn't be made.
    private func enhanceVoiceIfNeeded(_ job: Job) async -> Bool {
        guard job.project.audio.enhanceVoice else { return false }
        let url = job.project.sourceURL
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else { return false }
        var counts: [Int] = []
        for track in tracks {
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            counts.append(Int(formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 2))
        }
        let kinds = VideoAudioKind.resolve(recorded: job.recording?.audioTracks, channelCounts: counts)
        guard let index = VideoAudioKind.voiceTrackIndex(in: kinds), tracks.indices.contains(index) else { return false }
        let destination = VideoVoiceEnhancer.cacheURL(for: url, trackIndex: index)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return false }
        guard VideoVoiceEnhancer.isAvailable else { return true }
        job.state = .enhancingVoice(0)
        let bridge = JobBridge(job: job)
        do {
            try await VideoVoiceEnhancer.enhance(asset: asset, track: tracks[index], to: destination) { value in
                Task { await bridge.voice(value) }
            }
            return false
        } catch {
            return true
        }
    }

    /// "Demo.srt" (or .vtt) next to the video, when captions exist.
    private func writeSubtitles(for job: Job) -> URL? {
        guard let format = job.settings.subtitles, !job.project.captions.isEmpty else { return nil }
        let base = job.destination.deletingPathExtension()
        let language = job.project.captionTracks.active.map { ".\($0)" } ?? ""
        let url = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent)\(language).\(format.fileExtension)")
        var project = job.project
        // Every clip ends by the last one's end: enough to lay them out.
        let total = project.sourceAxisDuration ?? max(project.trimEnd, project.timelineClips.map(\.sourceEnd).max() ?? 0)
        if case .timeline(let span) = job.range {
            project = project.trimmed(toTimeline: span, totalDuration: total).project
        }
        let segments = project.timelineSegments(totalDuration: total)
        let text = VideoCaptionBuilder.subtitles(format, project: project, segments: segments)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// Hops export callbacks onto the main actor.
private final class JobBridge: @unchecked Sendable {
    @MainActor private weak var job: VideoExportQueue.Job?

    @MainActor
    init(job: VideoExportQueue.Job) {
        self.job = job
    }

    @MainActor
    func phase(_ phase: VideoDemoExporter.Phase) {
        guard let job, !job.isDone else { return }
        job.state = .running(phase)
    }

    @MainActor
    func voice(_ value: Double) {
        guard let job, !job.isDone else { return }
        job.state = .enhancingVoice(value)
    }

    @MainActor
    func isCancelled() -> Bool {
        job?.cancelRequested ?? true
    }
}

// MARK: - Editor

extension VideoEditorModel {
    /// This editor's exports, newest last.
    var exportJobs: [VideoExportQueue.Job] { VideoExportQueue.shared.jobs(for: project.sourcePath) }

    /// Starts an export in the background from a snapshot of the project.
    func enqueueExport(to destination: URL, settings: VideoExportSettings, toClipboard: Bool, range: VideoExportRange = .whole) {
        playback.pause()
        var snapshot = project
        // The pointer path lives in the recording's sidecar; the snapshot
        // needs it whole.
        if snapshot.cursorSamples.isEmpty, let recording { snapshot.cursorSamples = recording.cursorSamples }
        let job = VideoExportQueue.shared.enqueue(project: snapshot, recording: recording, settings: settings, range: range, destination: destination, toClipboard: toClipboard)
        exportPhase = .running(progress: 0, started: Date(), destination: destination, toClipboard: toClipboard)
        observeExport(job)
    }

    /// Mirrors a job into the export sheet's phase until it ends.
    private func observeExport(_ job: VideoExportQueue.Job) {
        Task { [weak self, weak job] in
            while let job, let self {
                switch job.state {
                case .finished(let bytes):
                    self.exportPhase = .finished(url: job.destination, bytes: bytes, copied: job.toClipboard)
                    if let note = job.note { self.showNotice(note, symbol: "exclamationmark.triangle.fill") }
                    return
                case .failed(let message):
                    self.exportPhase = .failed(message)
                    return
                case .cancelled:
                    if case .running(_, _, let destination, _) = self.exportPhase, destination == job.destination {
                        self.exportPhase = .idle
                    }
                    self.showNotice("Export cancelled", symbol: "xmark.circle")
                    return
                default:
                    if case .running(_, let started, let destination, let clipboard) = self.exportPhase, destination == job.destination {
                        self.exportPhase = .running(progress: job.progress, started: job.startedAt ?? started, destination: destination, toClipboard: clipboard)
                    }
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    /// Cancels this editor's newest running export.
    func cancelLatestExport() {
        guard let job = exportJobs.last(where: { !$0.isDone }) else { return }
        VideoExportQueue.shared.cancel(job)
    }

    /// The export sheet's running view: what the newest export is doing.
    var latestExportStatus: String? {
        exportJobs.last(where: { !$0.isDone })?.statusText
    }
}

// MARK: - Pill

/// Exports in progress (and just finished) for this editor, over the
/// preview's corner: progress, cancel, and — when done — share and show.
struct VideoExportJobsPill: View {
    @ObservedObject var model: VideoEditorModel
    @ObservedObject private var queue = VideoExportQueue.shared

    var body: some View {
        let jobs = queue.jobs(for: model.project.sourcePath).suffix(3)
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(Array(jobs)) { job in
                VideoExportJobRow(job: job)
            }
        }
    }
}

private struct VideoExportJobRow: View {
    @ObservedObject var job: VideoExportQueue.Job

    var body: some View {
        HStack(spacing: 9) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(job.toClipboard ? "Copy to clipboard" : job.destination.lastPathComponent)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(job.statusText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isFailed ? Color(red: 1, green: 0.6, blue: 0.55) : Color.white.opacity(0.7))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !job.isDone {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(Color.accentColor)
                }
            }
            .frame(width: 190, alignment: .leading)
            actions
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.8)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }

    private var isFailed: Bool {
        if case .failed = job.state { return true }
        return false
    }

    @ViewBuilder
    private var icon: some View {
        switch job.state {
        case .finished:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green).font(.system(size: 16))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange).font(.system(size: 15))
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(Color.white.opacity(0.6)).font(.system(size: 15))
        case .queued:
            Image(systemName: "clock").foregroundStyle(Color.white.opacity(0.7)).font(.system(size: 14))
        default:
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            if case .finished = job.state, !job.toClipboard {
                VideoShareButton(url: job.destination, compact: true)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([job.destination])
                } label: {
                    Image(systemName: "folder").frame(width: 24, height: 24)
                }
                .buttonStyle(VideoToolButtonStyle())
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }
            Button {
                if job.isDone {
                    VideoExportQueue.shared.dismiss(job)
                } else {
                    VideoExportQueue.shared.cancel(job)
                }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 24, height: 24)
            }
            .buttonStyle(VideoToolButtonStyle())
            .help(job.isDone ? "Dismiss" : "Cancel this export")
            .accessibilityLabel(job.isDone ? "Dismiss" : "Cancel export")
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(.white)
    }
}

// MARK: - Share

/// Opens the system share menu (Mail, Messages, AirDrop…) for a file,
/// anchored to the button.
struct VideoShareButton: View {
    let url: URL
    var compact = false

    @State private var anchor = VideoShareAnchor.Box()

    var body: some View {
        Button {
            anchor.share(url)
        } label: {
            if compact {
                Image(systemName: "square.and.arrow.up").frame(width: 24, height: 24)
            } else {
                Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(ShareStyle(compact: compact))
        .background(VideoShareAnchor(box: anchor))
        .help("Share — Mail, Messages, AirDrop…")
        .accessibilityLabel("Share")
    }

    private struct ShareStyle: ButtonStyle {
        let compact: Bool

        func makeBody(configuration: Configuration) -> some View {
            if compact {
                VideoToolButtonStyle().makeBody(configuration: configuration)
            } else {
                VideoSecondaryButtonStyle().makeBody(configuration: configuration)
            }
        }
    }
}

/// An invisible view the share menu points at.
struct VideoShareAnchor: NSViewRepresentable {
    @MainActor
    final class Box {
        weak var view: NSView?

        func share(_ url: URL) {
            guard let view else { return }
            NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    let box: Box

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}

// MARK: - Completion panel

/// A finished export whose editor was closed says so in a small panel.
@MainActor
final class VideoExportCompletionPanel: NSPanel {
    private static var active: [VideoExportCompletionPanel] = []
    private var dismissTimer: Timer?

    static func show(for job: VideoExportQueue.Job) {
        let panel = VideoExportCompletionPanel(job: job)
        active.append(panel)
        panel.present()
    }

    private init(job: VideoExportQueue.Job) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 96), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        let host = NSHostingView(rootView: VideoExportCompletionView(job: job) { [weak self] in self?.close() })
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 96)
        contentView = host
    }

    private func present() {
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 18, y: visible.maxY - frame.height - 18))
        }
        orderFrontRegardless()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.close() }
        }
    }

    override func close() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        super.close()
        Self.active.removeAll { $0 === self }
    }
}

private struct VideoExportCompletionView: View {
    @ObservedObject var job: VideoExportQueue.Job
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(failed ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(failed ? "Export failed" : (job.toClipboard ? "Video copied" : "Video exported"))
                    .font(.system(size: 13, weight: .bold))
                Text(failed ? job.statusText : job.destination.lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if !failed, !job.toClipboard {
                    HStack(spacing: 8) {
                        VideoShareButton(url: job.destination)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([job.destination])
                            close()
                        }
                        .controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close")
        }
        .padding(14)
        .frame(width: 360, height: 96, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .environment(\.colorScheme, .dark)
    }

    private var failed: Bool {
        if case .failed = job.state { return true }
        return false
    }
}
