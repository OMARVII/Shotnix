import AVFoundation
import AppKit
import CoreImage

/// Still frames from the recordings by source-axis time: the held sides of
/// dissolves (the preview and the export decode them the same way) and
/// clip-edge peeks into added recordings.
final class VideoSourceFrames: @unchecked Sendable {
    typealias Resolver = @Sendable (Double) -> (url: URL, time: Double)?

    private let lock = NSLock()
    private let resolver: Resolver
    /// Frames are decoded no bigger than this (nil: full size — the export).
    let maximumSize: CGSize?
    /// The most the cache keeps, in decoded bytes.
    let byteLimit: Int
    private var generators: [String: AVAssetImageGenerator] = [:]
    private var cache: [String: CIImage] = [:]
    private var order: [String] = []
    private var pending: Set<String> = []
    private(set) var cachedBytes = 0
    /// Frames asked of the decoder so far (tests watch it).
    private(set) var decodeRequests = 0

    init(maximumSize: CGSize? = nil, byteLimit: Int = 512 << 20, resolver: @escaping Resolver) {
        self.maximumSize = maximumSize
        self.byteLimit = byteLimit
        self.resolver = resolver
    }

    /// Frames of a project's recordings (one or several).
    convenience init(project: VideoDemoProject, maximumSize: CGSize? = nil, byteLimit: Int = 512 << 20) {
        let primary = project.sourceURL
        let sources = project.hasAppendedSources ? project.sources : []
        let paths = Dictionary(sources.map { ($0.id, $0.isPrimary ? primary : (VideoSourceLocator.resolve($0) ?? URL(fileURLWithPath: $0.path))) }, uniquingKeysWith: { first, _ in first })
        self.init(maximumSize: maximumSize, byteLimit: byteLimit) { time in
            guard !sources.isEmpty else { return (primary, time) }
            guard let source = sources.last(where: { time >= $0.offset - 0.0001 }) ?? sources.first, let url = paths[source.id] else { return nil }
            return (url, min(max(time - source.offset, 0), source.duration))
        }
    }

    private func key(_ url: URL, _ time: Double) -> String { "\(url.path)@\(Int((time * 1000).rounded()))" }

    private func generator(for url: URL) -> AVAssetImageGenerator {
        if let existing = generators[url.path] { return existing }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maximumSize { generator.maximumSize = maximumSize }
        generators[url.path] = generator
        return generator
    }

    private static func bytes(of image: CIImage) -> Int {
        Int(image.extent.width * image.extent.height) * 4
    }

    /// Keeps the newest frames within the byte budget.
    private func store(_ image: CIImage, for key: String) {
        if let old = cache[key] { cachedBytes -= Self.bytes(of: old) } else { order.append(key) }
        cache[key] = image
        cachedBytes += Self.bytes(of: image)
        while cachedBytes > byteLimit, order.count > 1 {
            let oldest = order.removeFirst()
            if let dropped = cache.removeValue(forKey: oldest) { cachedBytes -= Self.bytes(of: dropped) }
        }
    }

    /// Whether the frame for a source moment is decoded (or on its way).
    func isCachedOrPending(_ sourceTime: Double) -> Bool {
        guard let (url, time) = resolver(sourceTime) else { return false }
        let key = key(url, time)
        lock.lock()
        defer { lock.unlock() }
        return cache[key] != nil || pending.contains(key)
    }

    /// Decodes now (the export's render thread).
    func image(at sourceTime: Double) -> CIImage? {
        guard let (url, time) = resolver(sourceTime) else { return nil }
        let key = key(url, time)
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        let generator = generator(for: url)
        decodeRequests += 1
        lock.unlock()
        guard let cgImage = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil) else { return nil }
        let image = CIImage(cgImage: cgImage)
        lock.lock()
        store(image, for: key)
        lock.unlock()
        return image
    }

    /// Only what's ready (the preview never waits); `loaded` runs on the
    /// main queue once a missing frame arrives.
    func cachedImage(at sourceTime: Double, loaded: @escaping @Sendable () -> Void) -> CIImage? {
        guard let (url, time) = resolver(sourceTime) else { return nil }
        let key = key(url, time)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        decodeRequests += 1
        let generator = generator(for: url)
        generator.generateCGImageAsynchronously(for: CMTime(seconds: time, preferredTimescale: 600)) { [weak self] cgImage, _, _ in
            guard let self else { return }
            self.lock.lock()
            self.pending.remove(key)
            if let cgImage { self.store(CIImage(cgImage: cgImage), for: key) }
            self.lock.unlock()
            DispatchQueue.main.async { loaded() }
        }
        return nil
    }
}

/// What the editor loads beside the recording: the song, the click sound,
/// other recordings, where the voice is (for ducking), and held frames.
@MainActor
final class VideoEditorMedia {
    /// The loaded song, for the path it was loaded from.
    var music: (path: String, file: VideoAudioFile)?
    var musicWaveform: (path: String, waveform: VideoWaveform)?
    var clickSound: VideoAudioFile?
    /// Speech on each recording's voice track, in its own seconds ("" is
    /// the project's own recording; others by source ID).
    var speech: [String: [ClosedRange<Double>]] = [:]
    /// Added recordings, loaded.
    var layout: VideoSourceLayout?
    /// Added recordings' own data (pointer pictures), by source ID.
    var appendedMetadata: [UUID: VideoDemoRecordingMetadata?] = [:]
    var frames: VideoSourceFrames?
    private(set) var framesKey: [String] = []
    private var loading: Set<String> = []
    /// Pointer pictures from every recording (rebuilt when they change).
    var mergedArtwork: (key: [String], artwork: VideoCursorArtwork)?

    func begin(_ key: String) -> Bool { loading.insert(key).inserted }
    func end(_ key: String) { loading.remove(key) }

    /// The preview's held frames: no bigger than a large preview needs, and
    /// a budget that holds the dissolves around the playhead.
    static let previewFrameSize = CGSize(width: 1920, height: 1920)
    static let previewFrameBytes = 160 << 20

    /// Frames for the project's current recordings (rebuilt when they change).
    func frames(for project: VideoDemoProject) -> VideoSourceFrames {
        let key = [project.sourcePath] + project.sources.map { "\($0.id)@\($0.offset)" }
        if let frames, key == framesKey { return frames }
        let built = VideoSourceFrames(project: project, maximumSize: Self.previewFrameSize, byteLimit: Self.previewFrameBytes)
        frames = built
        framesKey = key
        return built
    }
}

// MARK: - Editor glue

extension VideoEditorModel {
    /// Everything the player's edit carries besides the cuts.
    var editExtras: VideoEditExtras {
        var extras = VideoEditExtras()
        extras.tail = project.timelineTail
        extras.layout = project.hasAppendedSources ? media.layout : nil
        if let music = project.music, let loaded = media.music, loaded.path == music.path {
            extras.music = VideoMusicInput(file: loaded.file, settings: music, voice: voiceTimelineRanges)
        }
        if project.clickSounds.enabled, let click = media.clickSound {
            let times = VideoClickSound.times(project: project, segments: segments)
            if !times.isEmpty {
                extras.clicks = VideoClickSoundInput(file: click, times: times, volume: project.clickSounds.volume)
            }
        }
        return extras
    }

    /// The pointer pictures the plan draws with (every recording's).
    var planArtwork: VideoCursorArtwork {
        guard project.hasAppendedSources else { return artwork }
        let key = project.sources.map { "\($0.id)@\($0.offset)" } + media.appendedMetadata.compactMap { $0.value == nil ? nil : $0.key.uuidString }.sorted()
        if let cached = media.mergedArtwork, cached.key == key { return cached.artwork }
        let metadata = VideoSourcesPointer.artworkMetadata(primary: recording, project: project, appended: media.appendedMetadata.compactMapValues { $0 })
        let built = VideoCursorArtwork(metadata: metadata)
        media.mergedArtwork = (key, built)
        return built
    }

    /// When the screen changed (typing, scrolling) — every recording's, where
    /// it sits on the source axis (nil: no recording knows).
    var screenActivityOnAxis: [Double]? {
        guard project.hasAppendedSources else { return recording?.screenActivity }
        var times: [Double] = []
        var known = false
        for source in project.sources {
            let own = source.isPrimary ? recording?.screenActivity : media.appendedMetadata[source.id].flatMap { $0?.screenActivity }
            guard let own else { continue }
            known = true
            times += own.filter { $0 <= source.duration }.map { $0 + source.offset }
        }
        return known ? times.sorted() : nil
    }

    /// Where the voice is heard on the timeline (what the music ducks under).
    var voiceTimelineRanges: [ClosedRange<Double>] {
        VideoMusicDucking.voiceOnTimeline(project: project, primaryKinds: audioKinds, speech: media.speech, segments: segments)
    }

    /// The project changed: load whatever it newly needs.
    func mediaDidChange(from old: VideoDemoProject) {
        guard isReady else { return }
        if project.music?.path != old.music?.path || (project.music?.ducking == true && old.music?.ducking != true) {
            loadMusic()
        }
        if project.clickSounds.enabled, media.clickSound == nil {
            loadClickSound()
        }
        if project.sources.map(\.id) != old.sources.map(\.id) || project.sources.map(\.offset) != old.sources.map(\.offset) {
            Task { await reloadSources() }
        }
    }

    /// Loads what the project needs once the recording is open.
    func prepareMedia() async {
        VideoExportQueue.shared.editorOpened(sourcePath: project.sourcePath)
        if project.hasAppendedSources { await reloadSources() }
        if project.music != nil { loadMusic() }
        if project.clickSounds.enabled { loadClickSound() }
    }

    /// Re-applies the edit to the player (music, clicks, recordings loaded).
    func refreshPlayback() {
        guard isReady else { return }
        if let moved = playback.apply(segments: segments, audio: project.audio, keepSourceTime: sourceTime(forTimeline: clock.time), extras: editExtras), !isPlaying {
            clock.time = moved
        }
        previewRenderer.invalidate()
        refreshTimeline()
    }

    private func loadMusic() {
        guard let music = project.music else {
            media.music = nil
            refreshPlayback()
            return
        }
        let path = music.path
        guard media.begin("music-\(path)") else { return }
        Task {
            defer { media.end("music-\(path)") }
            if media.music?.path != path, let file = await VideoAudioFile.load(URL(fileURLWithPath: path)) {
                media.music = (path, file)
            }
            if let waveform = await VideoMusicWaveform.load(url: URL(fileURLWithPath: path)) {
                media.musicWaveform = (path, waveform)
            }
            await loadSpeech()
            refreshPlayback()
        }
    }

    /// Speech on every recording's voice track (for ducking).
    func loadSpeech() async {
        if media.speech[""] == nil, let index = VideoAudioKind.voiceTrackIndex(in: audioKinds) {
            media.speech[""] = await VideoVoiceActivity.speech(url: project.sourceURL, trackIndex: index)
        }
        for source in project.sources where !source.isPrimary && media.speech[source.id.uuidString] == nil {
            guard let index = VideoAudioKind.voiceTrackIndex(in: source.audioKinds), let url = VideoSourceLocator.resolve(source) else { continue }
            media.speech[source.id.uuidString] = await VideoVoiceActivity.speech(url: url, trackIndex: index)
        }
    }

    private func loadClickSound() {
        guard media.begin("click") else { return }
        Task {
            defer { media.end("click") }
            guard let url = try? VideoClickSound.fileURL(), let file = await VideoAudioFile.load(url) else { return }
            media.clickSound = file
            refreshPlayback()
        }
    }

    /// Loads (or drops) the added recordings and everything drawn from them.
    func reloadSources() async {
        guard let primary = playback.source else { return }
        if project.hasAppendedSources {
            let audio = playback.audioSources ?? VideoAudioSource.sources(from: primary, kinds: audioKinds)
            media.layout = await VideoSourceLayout.load(project: project, primary: primary, primaryAudio: audio, primaryCamera: playback.camera, enhanceVoice: project.audio.enhanceVoice)
            // Their own data (pointer paths: big), read off the main thread;
            // a recording found somewhere new has its data point there.
            let unread = project.sources.filter { !$0.isPrimary && media.appendedMetadata[$0.id] == nil }
            let read = await Task.detached(priority: .userInitiated) { () -> [(id: UUID, metadata: VideoDemoRecordingMetadata?, movedTo: String?)] in
                unread.map { source in
                    guard let url = VideoSourceLocator.resolve(source) else { return (source.id, nil, nil) }
                    let metadata = VideoDemoSidecarStore.load(for: url).map { VideoDemoSidecarStore.recordLocation(of: $0, for: url) }
                    return (source.id, metadata, url.standardizedFileURL.path != source.path ? url.standardizedFileURL.path : nil)
                }
            }.value
            for entry in read {
                media.appendedMetadata[entry.id] = entry.metadata
                // Moved: the project remembers where it is now (not an edit).
                if let path = entry.movedTo, let index = project.sources.firstIndex(where: { $0.id == entry.id }) {
                    project.sources[index].path = path
                }
            }
        } else {
            media.layout = nil
        }
        let total = project.sourceAxisDuration ?? primary.duration
        applySourceDuration(
            total,
            hasAudio: !primary.audio.isEmpty || (media.layout?.entries.contains { !$0.tracks.audio.isEmpty } ?? false),
            hasCamera: playback.camera != nil || (media.layout?.entries.contains { $0.camera != nil } ?? false)
        )
        refreshPlan()
        refreshPlayback()
        if project.music?.ducking == true { await loadSpeech(); refreshPlayback() }
        if project.hasAppendedSources { await loadSourceMedia() }
    }

    /// The added recordings' sound again (Enhance voice turned on or off,
    /// or a cleaned-up voice became ready) — without redoing thumbnails.
    func reloadSourceAudio() async {
        guard project.hasAppendedSources, let primary = playback.source else { return }
        let audio = playback.audioSources ?? VideoAudioSource.sources(from: primary, kinds: audioKinds)
        media.layout = await VideoSourceLayout.load(project: project, primary: primary, primaryAudio: audio, primaryCamera: playback.camera, enhanceVoice: project.audio.enhanceVoice)
    }

    /// Filmstrip thumbnails and the waveform across every recording.
    private func loadSourceMedia() async {
        let entries = project.sources.map { source in (url: project.url(of: source), offset: source.offset, duration: source.duration, resolved: source.isPrimary ? project.sourceURL : VideoSourceLocator.resolve(source)) }
        let result = await Task.detached(priority: .utility) { () -> ([VideoTimelineThumbnail], [Float]) in
            var thumbnails: [VideoTimelineThumbnail] = []
            var peaks: [Float] = []
            for entry in entries {
                guard let url = entry.resolved else { continue }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 320, height: 200)
                generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
                generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
                let count = min(max(Int(entry.duration / 1.2), 6), 120)
                // Frames right at each end too, so a clip's filmstrip never
                // borrows the neighbouring recording's picture.
                let edges = [min(0.05, entry.duration / 2), max(entry.duration - 0.05, entry.duration / 2)]
                let times = edges + (0..<count).map { entry.duration * (Double($0) + 0.5) / Double(count) }
                for local in times {
                    guard let cgImage = try? generator.copyCGImage(at: CMTime(seconds: local, preferredTimescale: 600), actualTime: nil) else { continue }
                    thumbnails.append(VideoTimelineThumbnail(time: entry.offset + local, image: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))))
                }
                let start = Int((entry.offset * VideoWaveform.bucketsPerSecond).rounded())
                if peaks.count < start { peaks += [Float](repeating: 0, count: start - peaks.count) }
                if let waveform = await VideoMusicWaveform.load(url: url) {
                    let limit = Int(entry.duration * VideoWaveform.bucketsPerSecond)
                    peaks = Array(peaks.prefix(start)) + Array(waveform.peaks.prefix(limit))
                }
            }
            return (thumbnails, peaks)
        }.value
        applyTimelineMedia(thumbnails: result.0, waveform: result.1.isEmpty ? nil : VideoWaveform(peaks: result.1))
    }

    /// The held frame a dissolve at `time` needs, if it's ready (the preview
    /// redraws when it arrives). The dissolves just ahead are fetched too.
    func heldFrame(at time: Double) -> CIImage? {
        prefetchHeldFrames(around: time)
        guard let request = plan.heldFrameRequest(at: time) else { return nil }
        let renderer = previewRenderer
        return media.frames(for: project).cachedImage(at: request.sourceTime) {
            MainActor.assumeIsolated { renderer.invalidate() }
        }
    }

    /// Seconds around the playhead whose dissolves are fetched ahead.
    static let heldFrameWindow = 6.0

    /// Fetches the held frames of the dissolves near the playhead — not
    /// while something is being dragged (the plan changes every moment).
    func prefetchHeldFrames(around time: Double? = nil) {
        guard !isGestureInProgress else { return }
        let center = time ?? clock.time
        let frames = media.frames(for: project)
        let renderer = previewRenderer
        for span in plan.transitions where span.kind == .dissolve && span.end >= center - 1 && span.start <= center + Self.heldFrameWindow {
            for sourceTime in [span.incomingSource, span.outgoingSource] where !frames.isCachedOrPending(sourceTime) {
                _ = frames.cachedImage(at: sourceTime) { MainActor.assumeIsolated { renderer.invalidate() } }
            }
        }
    }

    /// A still of the recording at a source-axis moment (clip-edge peeks,
    /// snapshots) — from whichever recording is there.
    func sourceFrameLocation(at sourceTime: Double) -> (url: URL, time: Double) {
        guard project.hasAppendedSources, let source = project.source(at: sourceTime) else { return (project.sourceURL, sourceTime) }
        let url = source.isPrimary ? project.sourceURL : (VideoSourceLocator.resolve(source) ?? URL(fileURLWithPath: source.path))
        return (url, min(max(sourceTime - source.offset, 0), source.duration))
    }

    /// What the timeline draws beyond the recording itself (so it redraws
    /// when these change).
    var timelineExtrasSignature: VideoTimelineExtrasSignature {
        VideoTimelineExtrasSignature(
            music: project.music,
            musicWaveform: media.musicWaveform?.waveform.peaks.count ?? -1,
            voice: project.music?.ducking == true ? voiceTimelineRanges : [],
            cards: project.cards,
            transitions: project.transitions,
            sources: project.sources
        )
    }
}

struct VideoTimelineExtrasSignature: Equatable {
    let music: VideoMusicTrack?
    let musicWaveform: Int
    let voice: [ClosedRange<Double>]
    let cards: VideoTitleCards
    let transitions: VideoTransitionSettings
    let sources: [VideoProjectSource]
}

enum VideoMusicDucking {
    /// Speech from every recording (each in its own seconds) → timeline
    /// stretches still heard: cut and muted clips drop out, and a muted or
    /// silent voice ducks nothing.
    static func voiceOnTimeline(project: VideoDemoProject, primaryKinds: [VideoAudioKind], speech: [String: [ClosedRange<Double>]], segments: [VideoDemoTimelineSegment]) -> [ClosedRange<Double>] {
        guard project.music?.ducking == true else { return [] }
        var axis: [ClosedRange<Double>] = []
        let primaryVoice = VideoAudioKind.voiceTrackIndex(in: primaryKinds).map { primaryKinds[$0] } ?? .mixed
        if project.audio.effectiveVolume(for: primaryVoice) > 0.01 {
            let shift = project.primaryOffset
            axis += (speech[""] ?? []).map { ($0.lowerBound + shift)...($0.upperBound + shift) }
        }
        for source in project.sources where !source.isPrimary {
            let voice = VideoAudioKind.voiceTrackIndex(in: source.audioKinds).map { source.audioKinds[$0] } ?? .mixed
            guard project.audio.effectiveVolume(for: voice) > 0.01 else { continue }
            axis += (speech[source.id.uuidString] ?? []).compactMap { range in
                let a = max(range.lowerBound, 0), b = min(range.upperBound, source.duration)
                return b > a ? (a + source.offset)...(b + source.offset) : nil
            }
        }
        return VideoVoiceActivity.timelineRanges(axis, segments: segments)
    }
}

// MARK: - Undo names

extension VideoEditDescription {
    /// "Undo Add Recording", "Redo Add Music"… (nil: none of these changed).
    static func framing(from old: VideoDemoProject, to new: VideoDemoProject) -> String? {
        if old.sources.map(\.id) != new.sources.map(\.id) {
            if new.sources.count > old.sources.count { return "Add Recording" }
            if new.sources.count < old.sources.count { return "Remove Recording" }
            return "Move Recording"
        }
        if old.music != new.music {
            if old.music == nil { return "Add Music" }
            if new.music == nil { return "Remove Music" }
            return old.music?.path != new.music?.path ? "Replace Music" : "Music Change"
        }
        if old.cards.intro.enabled != new.cards.intro.enabled { return new.cards.intro.enabled ? "Add Intro Card" : "Remove Intro Card" }
        if old.cards.outro.enabled != new.cards.outro.enabled { return new.cards.outro.enabled ? "Add Outro Card" : "Remove Outro Card" }
        if old.cards != new.cards { return "Title Card" }
        if old.transitions != new.transitions { return "Transitions" }
        if old.clickSounds != new.clickSounds { return "Click Sounds" }
        if old.captionTracks != new.captionTracks { return "Caption Translation" }
        return nil
    }
}

// MARK: - Commands

extension VideoCommandPalette {
    /// Images, music, cards, transitions, recordings, and subtitles.
    var framingCommands: [Command] {
        var commands: [Command] = [
            Command(id: "add-image", title: "Add Image or Logo…", symbol: "photo", shortcut: "") { model.chooseImageOverlay() },
            Command(id: "add-music", title: model.project.music == nil ? "Add Music…" : "Replace Music…", symbol: "music.note", shortcut: "") { model.chooseMusic() },
            Command(id: "append-video", title: "Append Video…", symbol: "film.stack", shortcut: "") { model.chooseVideoToAppend() },
            Command(id: "intro-card", title: model.project.cards.intro.enabled ? "Remove Intro Card" : "Add Intro Card", symbol: "textformat.size", shortcut: "") {
                model.setIntroEnabled(!model.project.cards.intro.enabled)
                model.inspectorTab = .background
            },
            Command(id: "outro-card", title: model.project.cards.outro.enabled ? "Remove Outro Card" : "Add Outro Card", symbol: "textformat.size", shortcut: "") {
                model.setOutroEnabled(!model.project.cards.outro.enabled)
                model.inspectorTab = .background
            },
            Command(id: "click-sounds", title: model.project.clickSounds.enabled ? "Turn Off Click Sounds" : "Play Click Sounds", symbol: "cursorarrow.click", shortcut: "") {
                model.setStyle { $0.clickSounds.enabled.toggle() }
            },
        ]
        let dissolving = model.project.transitions.betweenClips == .dissolve
        commands.append(Command(id: "dissolves", title: dissolving ? "Hard Cuts Between Clips" : "Dissolve Between Clips", symbol: "square.on.square.intersection.dashed", shortcut: "") {
            model.setStyle { $0.transitions.betweenClips = dissolving ? .none : .dissolve }
        })
        if model.project.music != nil {
            commands.append(Command(id: "remove-music", title: "Remove Music", symbol: "trash", shortcut: "") { model.removeMusic() })
        }
        if !model.project.captions.isEmpty {
            commands.append(Command(id: "vtt", title: "Save Subtitles (.vtt)…", symbol: "doc.text", shortcut: "") { model.exportSubtitles(.vtt) })
        }
        return commands
    }
}
