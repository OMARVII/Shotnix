import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// One recording in a project with several. Recordings sit back to back on
/// a single "source axis", so everything timed in source seconds (clips,
/// zooms, annotations, captions, clicks, shortcuts, the pointer path)
/// keeps working unchanged; each recording's own data is moved to where it
/// sits. A project with one recording has no entries at all.
struct VideoProjectSource: Codable, Equatable, Identifiable {
    var id: UUID
    /// The recording the project belongs to (its path is the project's).
    var isPrimary: Bool
    var path: String
    /// Finds the file again after a move.
    var bookmark: Data?
    var name: String
    var duration: Double
    /// Upright pixel size.
    var width: Double
    var height: Double
    /// Where it starts on the source axis.
    var offset: Double
    /// What each of its sound tracks carries.
    var audioKinds: [VideoAudioKind]
    /// A Shotnix recording with an editable pointer (the editor draws it).
    var hasPointer: Bool
    var pointPixelScale: Double?
    /// Camera footage recorded with it.
    var webcam: VideoWebcamRecording?

    init(
        id: UUID = UUID(),
        isPrimary: Bool = false,
        path: String,
        bookmark: Data? = nil,
        name: String,
        duration: Double,
        width: Double,
        height: Double,
        offset: Double = 0,
        audioKinds: [VideoAudioKind] = [],
        hasPointer: Bool = false,
        pointPixelScale: Double? = nil,
        webcam: VideoWebcamRecording? = nil
    ) {
        self.id = id
        self.isPrimary = isPrimary
        self.path = path
        self.bookmark = bookmark
        self.name = name
        self.duration = duration
        self.width = width
        self.height = height
        self.offset = offset
        self.audioKinds = audioKinds
        self.hasPointer = hasPointer
        self.pointPixelScale = pointPixelScale
        self.webcam = webcam
    }

    var end: Double { offset + duration }

    /// Where this recording's picture sits in the project's frame (the
    /// first recording's shape): fitted and centered, normalized, y down.
    func frameRect(inFrame frame: CGSize) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard !isPrimary, width > 0, height > 0, frame.width > 0, frame.height > 0 else { return full }
        let scale = min(frame.width / width, frame.height / height)
        let w = width * scale / frame.width
        let h = height * scale / frame.height
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    /// The project frame's pixels per pixel of this recording.
    func fitScale(inFrame frame: CGSize) -> Double {
        guard !isPrimary, width > 0, height > 0, frame.width > 0, frame.height > 0 else { return 1 }
        return min(frame.width / width, frame.height / height)
    }

    private enum CodingKeys: String, CodingKey {
        case id, isPrimary, path, bookmark, name, duration, width, height, offset, audioKinds, hasPointer, pointPixelScale, webcam
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        isPrimary = try c.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
        path = try c.decode(String.self, forKey: .path)
        bookmark = try? c.decodeIfPresent(Data.self, forKey: .bookmark)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? URL(fileURLWithPath: path).lastPathComponent
        duration = try c.decode(Double.self, forKey: .duration)
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0
        offset = try c.decodeIfPresent(Double.self, forKey: .offset) ?? 0
        audioKinds = (try? c.decode([VideoAudioKind].self, forKey: .audioKinds)) ?? []
        hasPointer = try c.decodeIfPresent(Bool.self, forKey: .hasPointer) ?? false
        pointPixelScale = try? c.decodeIfPresent(Double.self, forKey: .pointPixelScale)
        webcam = try? c.decodeIfPresent(VideoWebcamRecording.self, forKey: .webcam)
    }
}

/// A stretch of the source axis inside one recording.
struct VideoSourcePiece: Equatable {
    let source: VideoProjectSource
    /// Source-axis seconds.
    let axisStart: Double
    let axisEnd: Double

    var localStart: Double { axisStart - source.offset }
    var length: Double { max(axisEnd - axisStart, 0) }
}

extension VideoDemoProject {
    /// More than one recording.
    var hasAppendedSources: Bool { sources.count > 1 }

    /// An added Shotnix recording brings its own editable pointer.
    var appendedSourceHasPointer: Bool { sources.contains { !$0.isPrimary && $0.hasPointer } }

    /// The source axis's length with every recording (nil: just one).
    var sourceAxisDuration: Double? { hasAppendedSources ? sources.map(\.end).max() : nil }

    /// Where this project's own recording sits on the axis.
    var primaryOffset: Double { sources.first(where: \.isPrimary)?.offset ?? 0 }

    /// The recording at a source-axis moment (a boundary belongs to the
    /// recording that starts there).
    func source(at time: Double) -> VideoProjectSource? {
        guard hasAppendedSources else { return nil }
        return sources.last { time >= $0.offset - 0.0001 } ?? sources.first
    }

    func url(of source: VideoProjectSource) -> URL {
        source.isPrimary ? sourceURL : URL(fileURLWithPath: source.path)
    }

    /// A source-axis span split where the recording changes.
    func sourcePieces(from start: Double, to end: Double) -> [VideoSourcePiece] {
        guard end > start else { return [] }
        return sources.compactMap { source in
            let a = max(start, source.offset)
            let b = min(end, source.end)
            return b - a > 0.0005 ? VideoSourcePiece(source: source, axisStart: a, axisEnd: b) : nil
        }
    }

    /// Timeline moments where one recording hands over to the next.
    func sourceBoundaries(segments: [VideoDemoTimelineSegment]) -> [(time: Double, name: String)] {
        guard hasAppendedSources else { return [] }
        var boundaries: [(Double, String)] = []
        var previous: UUID?
        for segment in segments {
            for piece in sourcePieces(from: segment.clip.sourceStart, to: segment.clip.sourceEnd) {
                if let previous, previous != piece.source.id {
                    boundaries.append((segment.timelineTime(forSourceTime: piece.axisStart), piece.source.name))
                }
                previous = piece.source.id
            }
        }
        return boundaries
    }

    /// Starts listing recordings (the first time one is added).
    mutating func ensurePrimarySource(duration: Double, kinds: [VideoAudioKind], webcam: VideoWebcamRecording?, pointPixelScale: Double?) {
        guard sources.isEmpty else { return }
        sources = [VideoProjectSource(
            isPrimary: true,
            path: sourcePath,
            name: sourceURL.lastPathComponent,
            duration: duration,
            width: sourceWidth,
            height: sourceHeight,
            offset: 0,
            audioKinds: kinds,
            hasPointer: !nativeCursorVisible && !cursorSamples.isEmpty,
            pointPixelScale: pointPixelScale,
            webcam: webcam
        )]
    }

    /// The project's frame (the first recording's upright size).
    var frameSize: CGSize { CGSize(width: sourceWidth, height: sourceHeight) }

    /// Adds a recording after the others and a clip for all of it at the
    /// end of the timeline. Its clicks, shortcuts, and pointer path join the
    /// project's, moved to where it sits — in time, and in the frame when
    /// its shape differs (it's fitted into the first recording's).
    mutating func appendSource(_ incoming: VideoProjectSource, metadata: VideoDemoRecordingMetadata?) {
        guard let last = sources.last else { return }
        var source = incoming
        source.isPrimary = false
        source.offset = last.end
        sources.append(source)
        let shift = source.offset
        let rect = source.frameRect(inFrame: frameSize)
        func place(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            (Double(rect.minX) + x * Double(rect.width), Double(rect.minY) + y * Double(rect.height))
        }
        if let metadata {
            clickEvents += metadata.clickEvents.map { click in
                var moved = click
                moved.id = UUID()
                moved.time += shift
                moved.endTime = click.endTime.map { $0 + shift }
                (moved.x, moved.y) = place(click.x, click.y)
                return moved
            }
            keystrokes += (metadata.keystrokes ?? []).map { VideoKeystrokeEvent(time: $0.time + shift, keys: $0.keys) }
            if source.hasPointer {
                cursorSamples += metadata.cursorSamples.map { sample in
                    let point = place(sample.x, sample.y)
                    return VideoDemoCursorSample(time: sample.time + shift, x: point.x, y: point.y)
                }
                cursorSamples.sort { $0.time < $1.time }
            }
        }
        clickEvents.sort { $0.time < $1.time }
        keystrokes.sort { $0.time < $1.time }
        timelineClips.append(VideoDemoTimelineClip(sourceStart: source.offset, sourceEnd: source.end))
    }

    /// Start Over: the recordings an older version of this project had,
    /// back in their order, each with its own clicks, shortcuts, and
    /// pointer — the edits made to them stay behind.
    mutating func restoreSources(from old: VideoDemoProject, metadata: [UUID: VideoDemoRecordingMetadata?]) {
        guard old.hasAppendedSources, var primary = old.sources.first(where: \.isPrimary) else { return }
        primary.offset = 0
        sources = [primary]
        for added in old.sources where !added.isPrimary {
            appendSource(added, metadata: metadata[added.id] ?? nil)
        }
        if let index = old.sources.firstIndex(where: \.isPrimary), index > 0 {
            moveSource(from: 0, to: index)
        }
    }

    /// Moves a whole recording to another place in the order: its clips
    /// move on the timeline, and everything timed inside it goes along.
    mutating func moveSource(from: Int, to: Int) {
        guard sources.indices.contains(from), sources.indices.contains(to), from != to else { return }
        let old = sources
        // Clips in recording order follow their recording to its new place;
        // clips arranged by hand keep their places on the timeline.
        let inRecordingOrder = zip(timelineClips, timelineClips.dropFirst()).allSatisfy { $0.sourceStart <= $1.sourceStart + 0.0001 }
        var reordered = sources
        reordered.insert(reordered.remove(at: from), at: to)
        var offset = 0.0
        for index in reordered.indices {
            reordered[index].offset = offset
            offset += reordered[index].duration
        }
        let newOffsets = Dictionary(reordered.map { ($0.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        func owner(_ time: Double) -> VideoProjectSource? {
            old.last { time >= $0.offset - 0.0001 } ?? old.first
        }
        func map(_ time: Double, in source: VideoProjectSource?) -> Double {
            guard let source, let newOffset = newOffsets[source.id] else { return time }
            return time - source.offset + newOffset
        }
        func map(_ time: Double) -> Double { map(time, in: owner(time)) }

        // Clips split at recording boundaries first: the halves may part.
        var clips: [VideoDemoTimelineClip] = []
        for clip in timelineClips {
            let pieces = sourcePieces(from: clip.sourceStart, to: clip.sourceEnd)
            for (index, piece) in pieces.enumerated() {
                var part = clip
                if index > 0 { part.id = UUID() }
                part.sourceStart = map(piece.axisStart, in: piece.source)
                part.sourceEnd = map(piece.axisEnd, in: piece.source)
                if index > 0 { part.fadeIn = 0 }
                if index < pieces.count - 1 { part.fadeOut = 0 }
                clips.append(part)
            }
        }
        timelineClips = inRecordingOrder ? clips.sorted { $0.sourceStart < $1.sourceStart } : clips

        zoomRegions = zoomRegions.map { region in
            var moved = region
            let source = owner(region.start)
            let end = min(region.end, source?.end ?? region.end)
            moved.start = map(region.start, in: source)
            moved.end = map(end, in: source)
            return moved
        }.sorted { $0.start < $1.start }
        overlayEffects = overlayEffects.map { effect in
            var moved = effect
            moved.time = map(effect.time)
            return moved
        }
        captions = captions.map { line in
            var moved = line
            let source = owner(line.start)
            moved.start = map(line.start, in: source)
            moved.end = map(line.end, in: source)
            moved.words = line.words.map { VideoCaptionWord(text: $0.text, start: map($0.start, in: source), end: map($0.end, in: source)) }
            return moved
        }.sorted { $0.start < $1.start }
        clickEvents = clickEvents.map { click in
            var moved = click
            let source = owner(click.time)
            moved.time = map(click.time, in: source)
            moved.endTime = click.endTime.map { map($0, in: source) }
            return moved
        }.sorted { $0.time < $1.time }
        keystrokes = keystrokes.map { VideoKeystrokeEvent(id: $0.id, time: map($0.time), keys: $0.keys) }.sorted { $0.time < $1.time }
        cameraLayouts = cameraLayouts.map { region in
            var moved = region
            let source = owner(region.start)
            moved.start = map(region.start, in: source)
            moved.end = map(min(region.end, source?.end ?? region.end), in: source)
            return moved
        }.sorted { $0.start < $1.start }
        cursorSamples = cursorSamples.map { VideoDemoCursorSample(time: map($0.time), x: $0.x, y: $0.y) }.sorted { $0.time < $1.time }
        sources = reordered
        if let total = sourceAxisDuration { ensureTimeline(totalDuration: total) }
    }

    /// Takes an added recording (never the project's own) out: its clips
    /// and everything timed inside it go; later recordings close the gap.
    @discardableResult
    mutating func removeSource(id: UUID) -> Bool {
        guard let index = sources.firstIndex(where: { $0.id == id }), !sources[index].isPrimary else { return false }
        let removed = sources[index]
        let kept = timelineClips.filter { $0.sourceEnd <= removed.offset + 0.0005 || $0.sourceStart >= removed.end - 0.0005 }
        guard !kept.isEmpty else { return false }
        let gap = removed.duration
        func inside(_ time: Double) -> Bool { time >= removed.offset - 0.0005 && time < removed.end - 0.0005 }
        func map(_ time: Double) -> Double { time >= removed.end - 0.0005 ? time - gap : time }
        timelineClips = kept.map { clip in
            var moved = clip
            moved.sourceStart = map(clip.sourceStart)
            moved.sourceEnd = map(clip.sourceEnd)
            return moved
        }
        zoomRegions = zoomRegions.filter { !inside($0.start) }.map { region in
            var moved = region
            moved.start = map(region.start)
            moved.end = map(region.end)
            return moved
        }
        overlayEffects = overlayEffects.filter { !inside($0.time) }.map { effect in
            var moved = effect
            moved.time = map(effect.time)
            return moved
        }
        captions = captions.filter { !inside($0.start) }.map { line in
            var moved = line
            moved.start = map(line.start)
            moved.end = map(line.end)
            moved.words = line.words.map { VideoCaptionWord(text: $0.text, start: map($0.start), end: map($0.end)) }
            return moved
        }
        clickEvents = clickEvents.filter { !inside($0.time) }.map { click in
            var moved = click
            moved.time = map(click.time)
            moved.endTime = click.endTime.map(map)
            return moved
        }
        keystrokes = keystrokes.filter { !inside($0.time) }.map { VideoKeystrokeEvent(id: $0.id, time: map($0.time), keys: $0.keys) }
        cameraLayouts = cameraLayouts.filter { !inside($0.start) }.map { region in
            var moved = region
            moved.start = map(region.start)
            moved.end = map(region.end)
            return moved
        }
        cursorSamples = cursorSamples.filter { !inside($0.time) }.map { VideoDemoCursorSample(time: map($0.time), x: $0.x, y: $0.y) }
        sources.remove(at: index)
        for later in sources.indices where later >= index {
            sources[later].offset -= gap
        }
        // The length of what's left, before the list may go (with just one
        // recording left, it has none).
        let total = sources.map(\.end).max() ?? removed.offset
        if sources.count == 1 {
            // Back to a single recording.
            sources = []
        }
        ensureTimeline(totalDuration: total)
        return true
    }

    /// Stretches of the source axis where a drawn pointer belongs (nil: the
    /// whole recording, as with a single one).
    var pointerCoverage: [ClosedRange<Double>]? {
        guard hasAppendedSources else { return nil }
        return sources.filter { $0.isPrimary ? (!nativeCursorVisible && $0.hasPointer) : $0.hasPointer }.map { $0.offset...$0.end }
    }

    /// Source ranges cut down to recordings that have pointer data — a
    /// plain video with no pointer can't tell idle from busy.
    func limitedToPointerCoverage(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        guard let coverage = pointerCoverage else { return ranges }
        var limited: [ClosedRange<Double>] = []
        for range in ranges {
            for covered in coverage {
                let a = max(range.lowerBound, covered.lowerBound)
                let b = min(range.upperBound, covered.upperBound)
                if b > a { limited.append(a...b) }
            }
        }
        return limited
    }
}

/// Transcription across every recording of a video: each is transcribed
/// on its own (on this Mac) and its words moved to where it sits.
enum VideoSourcesTranscription {
    /// `primary` is the project's own recording's voice (see
    /// `VideoCaptionTranscriber.source`); each added recording's voice is
    /// picked the same way.
    static func transcribe(
        project: VideoDemoProject,
        primary: VideoCaptionTranscriber.Source,
        languageIdentifier: String?,
        progress: @escaping @Sendable (VideoCaptionTranscriber.Stage) -> Void
    ) async throws -> VideoCaptionTranscriber.Result {
        guard project.hasAppendedSources else {
            return try await VideoCaptionTranscriber.transcribe(url: primary.url, trackIndex: primary.trackIndex, timeOffset: primary.offset, languageIdentifier: languageIdentifier, progress: progress)
        }
        var words: [VideoCaptionWord] = []
        var language = languageIdentifier
        let count = Double(project.sources.count)
        for (index, source) in project.sources.enumerated() {
            let input: VideoCaptionTranscriber.Source
            if source.isPrimary {
                input = primary
            } else {
                guard let url = VideoSourceLocator.resolve(source) else { continue }
                input = await voice(of: source, at: url)
            }
            let base = Double(index)
            let scaled: @Sendable (VideoCaptionTranscriber.Stage) -> Void = { stage in
                switch stage {
                case .transcribing(let fraction): progress(.transcribing((base + fraction) / count))
                default: progress(stage)
                }
            }
            do {
                // The first recording's language is used for the rest.
                let result = try await VideoCaptionTranscriber.transcribe(url: input.url, trackIndex: input.trackIndex, timeOffset: input.offset, languageIdentifier: language, progress: scaled)
                language = language ?? result.language
                words += result.words.compactMap { word in
                    guard word.start < source.duration else { return nil }
                    return VideoCaptionWord(text: word.text, start: word.start + source.offset, end: min(word.end, source.duration) + source.offset)
                }
            } catch VideoCaptionTranscriber.Failure.noAudio {
                continue
            } catch VideoCaptionTranscriber.Failure.nothingHeard {
                continue
            }
        }
        guard !words.isEmpty else { throw VideoCaptionTranscriber.Failure.nothingHeard }
        return VideoCaptionTranscriber.Result(words: words.sorted { $0.start < $1.start }, language: language ?? Locale.current.identifier(.bcp47))
    }

    /// An added recording's voice on its own — its cleaned-up version when
    /// that's ready — like the project's own.
    static func voice(of source: VideoProjectSource, at url: URL) async -> VideoCaptionTranscriber.Source {
        var enhanced: URL?
        var voiceStart = 0.0
        if let index = VideoAudioKind.voiceTrackIndex(in: source.audioKinds) {
            let cache = VideoVoiceEnhancer.cacheURL(for: url, trackIndex: index)
            if FileManager.default.fileExists(atPath: cache.path) { enhanced = cache }
            if let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio), tracks.indices.contains(index),
               let range = try? await tracks[index].load(.timeRange), range.start.seconds.isFinite {
                voiceStart = range.start.seconds
            }
        }
        return VideoCaptionTranscriber.source(recording: url, kinds: source.audioKinds, enhancedVoice: enhanced, voiceStart: voiceStart)
    }
}

// MARK: - Pointer across recordings

enum VideoSourcesPointer {
    /// One pointer track across every recording: each recording's own path
    /// is smoothed on its own (so the pointer never glides across a cut
    /// between recordings, and each one's dash to Stop is tidied), and
    /// recordings without an editable pointer show none.
    static func cursorTrack(project: VideoDemoProject, duration: Double) -> VideoCursorTrack? {
        guard project.hasAppendedSources else {
            return VideoCursorTrack.build(
                samples: project.cursorSamples,
                clicks: project.clickEvents,
                smoothing: project.cursor.smoothing,
                hideWhenIdle: project.cursor.hideWhenIdle,
                tidyEnding: project.cursor.tidyEnding,
                crop: project.crop.normalized,
                duration: duration
            )
        }
        let coverage = project.pointerCoverage ?? []
        var tracks: [(source: VideoProjectSource, track: VideoCursorTrack)] = []
        for source in project.sources where coverage.contains(where: { abs($0.lowerBound - source.offset) < 0.001 }) {
            let samples = project.cursorSamples
                .filter { $0.time >= source.offset - 0.0001 && $0.time <= source.end + 0.0001 }
                .map { VideoDemoCursorSample(time: $0.time - source.offset, x: $0.x, y: $0.y) }
            let clicks = project.clickEvents
                .filter { $0.time >= source.offset - 0.0001 && $0.time < source.end }
                .map { click -> VideoDemoClickEvent in
                    var local = click
                    local.time -= source.offset
                    local.endTime = click.endTime.map { $0 - source.offset }
                    return local
                }
            // Outside its own picture (the bars around a recording of
            // another shape), a recording's pointer hides.
            let crop = project.crop.normalized
            let picture = source.frameRect(inFrame: project.frameSize)
            let x0 = max(crop.x, Double(picture.minX)), y0 = max(crop.y, Double(picture.minY))
            let x1 = min(crop.x + crop.width, Double(picture.maxX)), y1 = min(crop.y + crop.height, Double(picture.maxY))
            let kept = x1 > x0 && y1 > y0 ? VideoCropRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : crop
            guard let track = VideoCursorTrack.build(
                samples: samples,
                clicks: clicks,
                smoothing: project.cursor.smoothing,
                hideWhenIdle: project.cursor.hideWhenIdle,
                tidyEnding: project.cursor.tidyEnding,
                crop: kept,
                duration: source.duration
            ) else { continue }
            tracks.append((source, track))
        }
        guard !tracks.isEmpty, duration > 0 else { return nil }
        let count = Int((duration * VideoCursorTrack.sampleRate).rounded(.up)) + 1
        var xs = [Float](repeating: 0.5, count: count)
        var ys = [Float](repeating: 0.5, count: count)
        var alphas = [Float](repeating: 0, count: count)
        for (source, track) in tracks {
            let first = max(Int((source.offset * VideoCursorTrack.sampleRate).rounded(.up)), 0)
            let last = min(Int((source.end * VideoCursorTrack.sampleRate).rounded(.down)), count - 1)
            guard first <= last else { continue }
            for index in first...last {
                let local = Double(index) / VideoCursorTrack.sampleRate - source.offset
                let position = track.position(at: local)
                xs[index] = Float(position.x)
                ys[index] = Float(position.y)
                alphas[index] = Float(track.alpha(at: local))
            }
        }
        return VideoCursorTrack(duration: duration, xs: xs, ys: ys, alphas: alphas)
    }

    /// Pointer pictures from every recording, their changes moved to where
    /// each recording sits (the arrow at each start that has none).
    static func artworkMetadata(primary: VideoDemoRecordingMetadata?, project: VideoDemoProject, appended: [UUID: VideoDemoRecordingMetadata]) -> VideoDemoRecordingMetadata? {
        guard project.hasAppendedSources else { return primary }
        var shapes: [String: VideoCursorShape] = [:]
        var events: [VideoCursorShapeEvent] = []
        for source in project.sources {
            let metadata = source.isPrimary ? primary : appended[source.id]
            for shape in metadata?.cursorShapes ?? [] { shapes[shape.id] = shape }
            let own = (metadata?.cursorShapeEvents ?? []).map { VideoCursorShapeEvent(time: $0.time + source.offset, shapeID: $0.shapeID) }
            if own.first.map({ $0.time > source.offset + 0.001 }) ?? true {
                events.append(VideoCursorShapeEvent(time: source.offset, shapeID: "arrow"))
            }
            events += own
        }
        guard var merged = primary ?? appended.values.first else { return nil }
        merged.cursorShapes = shapes.isEmpty ? nil : shapes.values.sorted { $0.id < $1.id }
        merged.cursorShapeEvents = events.sorted { $0.time < $1.time }
        return merged
    }
}

// MARK: - Loaded recordings

/// Every recording's tracks, ready for an edit.
struct VideoSourceLayout {
    struct Entry {
        let source: VideoProjectSource
        let tracks: VideoSourceTracks
        let audio: [VideoAudioSource]
        let camera: VideoCameraSource?
    }

    let entries: [Entry]

    var identity: [String] { entries.map { "\($0.source.id)@\($0.source.offset)#\($0.audio.map(\.identity).joined(separator: ","))" } }

    func entry(for source: VideoProjectSource) -> Entry? {
        entries.first { $0.source.id == source.id }
    }

    /// The project's own recording as the edit has it now (its sound may
    /// have been swapped for the enhanced voice since loading).
    func replacingPrimary(tracks: VideoSourceTracks, audio: [VideoAudioSource], camera: VideoCameraSource?) -> VideoSourceLayout {
        VideoSourceLayout(entries: entries.map { entry in
            entry.source.isPrimary ? Entry(source: entry.source, tracks: tracks, audio: audio, camera: camera) : entry
        })
    }

    /// Pieces of a source-axis span with the recording each comes from.
    func pieces(from start: Double, to end: Double) -> [(entry: Entry, piece: VideoSourcePiece)] {
        entries.compactMap { entry in
            let a = max(start, entry.source.offset)
            let b = min(end, entry.source.end)
            return b - a > 0.0005 ? (entry, VideoSourcePiece(source: entry.source, axisStart: a, axisEnd: b)) : nil
        }
    }

    /// Loads the added recordings (the primary's tracks are passed in),
    /// each voice swapped for its cleaned-up version when that's wanted.
    static func load(project: VideoDemoProject, primary: VideoSourceTracks, primaryAudio: [VideoAudioSource], primaryCamera: VideoCameraSource?, includeCameras: Bool = true, enhanceVoice: Bool = false) async -> VideoSourceLayout? {
        guard project.hasAppendedSources else { return nil }
        var entries: [Entry] = []
        for source in project.sources {
            if source.isPrimary {
                entries.append(Entry(source: source, tracks: primary, audio: primaryAudio, camera: primaryCamera))
                continue
            }
            guard let url = VideoSourceLocator.resolve(source),
                  let tracks = try? await VideoSourceTracks.load(url: url) else { continue }
            let kinds = VideoAudioKind.resolve(recorded: source.audioKinds.isEmpty ? nil : source.audioKinds, channelCounts: tracks.audioChannelCounts)
            var camera: VideoCameraSource?
            if includeCameras, let webcam = source.webcam {
                camera = await VideoCameraSource.load(webcam)
            }
            let audio = await VideoAudioSource.resolved(from: tracks, kinds: kinds, enhanceVoice: enhanceVoice)
            entries.append(Entry(source: source, tracks: tracks, audio: audio, camera: camera))
        }
        return VideoSourceLayout(entries: entries)
    }
}

extension VideoCameraComposition {
    /// Camera footage of every recording that has some, cut like the screen.
    static func addCameraTrack(layout: VideoSourceLayout, to composition: AVMutableComposition, placements: [VideoCompositionBuilder.Placement]) -> AVMutableCompositionTrack? {
        guard layout.entries.contains(where: { $0.camera != nil }),
              let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var inserted = false
        for placement in placements {
            let clip = placement.segment.clip
            let speed = clip.normalizedSpeed
            for (entry, piece) in layout.pieces(from: clip.sourceStart, to: clip.sourceEnd) {
                guard let camera = entry.camera else { continue }
                let available = CMTimeRange(start: .zero, duration: VideoCompositionBuilder.time(camera.duration))
                let wantedStart = piece.localStart - camera.offset
                let wanted = CMTimeRange(start: VideoCompositionBuilder.time(wantedStart), duration: VideoCompositionBuilder.time(piece.length))
                let range = wanted.intersection(available)
                guard range.duration.seconds > 0.02 else { continue }
                let offset = piece.axisStart - clip.sourceStart + (range.start.seconds - wantedStart)
                let insertAt = placement.start + VideoCompositionBuilder.time(offset / speed)
                do {
                    try track.insertTimeRange(range, of: camera.track, at: insertAt)
                } catch {
                    continue
                }
                if abs(speed - 1) > 0.0001 {
                    track.scaleTimeRange(CMTimeRange(start: insertAt, duration: range.duration), toDuration: VideoCompositionBuilder.time(range.duration.seconds / speed))
                }
                inserted = true
            }
        }
        guard inserted else {
            composition.removeTrack(track)
            return nil
        }
        return track
    }
}

// MARK: - Voice across recordings

/// One recording's voice track that Enhance voice cleans up (cached like
/// the project's own).
struct VideoVoiceTarget: Equatable {
    let url: URL
    let trackIndex: Int

    var destination: URL { VideoVoiceEnhancer.cacheURL(for: url, trackIndex: trackIndex) }
    var isReady: Bool { FileManager.default.fileExists(atPath: destination.path) }
}

extension VideoDemoProject {
    /// Every recording's voice track, the project's own first.
    func voiceTargets(primaryKinds: [VideoAudioKind]) -> [VideoVoiceTarget] {
        var targets: [VideoVoiceTarget] = []
        if let index = VideoAudioKind.voiceTrackIndex(in: primaryKinds) {
            targets.append(VideoVoiceTarget(url: sourceURL, trackIndex: index))
        }
        for source in sources where !source.isPrimary {
            guard let index = VideoAudioKind.voiceTrackIndex(in: source.audioKinds), let url = VideoSourceLocator.resolve(source) else { continue }
            targets.append(VideoVoiceTarget(url: url, trackIndex: index))
        }
        return targets
    }

    /// An added recording has a voice to clean up (cheap: no file checks).
    var appendedSourceHasVoice: Bool {
        sources.contains { !$0.isPrimary && VideoAudioKind.voiceTrackIndex(in: $0.audioKinds) != nil }
    }
}

extension VideoVoiceEnhancer {
    /// Cleans up each voice that isn't yet, one after another; `progress`
    /// runs 0 → 1 across all of them.
    static func enhance(_ targets: [VideoVoiceTarget], progress: @escaping @Sendable (Double) -> Void) async throws {
        let pending = targets.filter { !$0.isReady }
        for (index, target) in pending.enumerated() {
            let asset = AVURLAsset(url: target.url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard tracks.indices.contains(target.trackIndex) else { continue }
            let done = Double(index)
            let count = Double(pending.count)
            try await enhance(asset: asset, track: tracks[target.trackIndex], to: target.destination) { value in
                progress((done + value) / count)
            }
        }
    }
}

/// Finds an added recording's file (its path, or its bookmark after a move).
enum VideoSourceLocator {
    static func resolve(_ source: VideoProjectSource) -> URL? {
        if FileManager.default.fileExists(atPath: source.path) { return URL(fileURLWithPath: source.path) }
        guard let bookmark = source.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

// MARK: - Editor

extension VideoEditorModel {
    func chooseVideoToAppend() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.message = "Choose a recording or video to add after this one"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await appendVideo(url) }
    }

    /// Adds a recording (or any video) after the timeline. Shotnix
    /// recordings bring their pointer, clicks, shortcuts, and camera.
    @discardableResult
    func appendVideo(_ url: URL) async -> Bool {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let tracks: VideoSourceTracks
        do {
            tracks = try await VideoSourceTracks.load(url: canonical)
        } catch {
            showNotice("Couldn't open that video — \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            return false
        }
        guard tracks.duration > 0.2 else {
            showNotice("That video is empty", symbol: "exclamationmark.triangle.fill")
            return false
        }
        let metadata = VideoDemoSidecarStore.load(for: canonical).map { VideoDemoSidecarStore.recordLocation(of: $0, for: canonical) }
        let kinds = VideoAudioKind.resolve(recorded: metadata?.audioTracks, channelCounts: tracks.audioChannelCounts)
        let hasPointer = metadata.map { $0.shouldRenderCursor && !$0.cursorSamples.isEmpty && !$0.nativeCursorVisible } ?? false
        let webcam = metadata?.webcam.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let source = VideoProjectSource(
            path: canonical.path,
            bookmark: VideoSourceLocator.bookmark(for: canonical),
            name: canonical.lastPathComponent,
            duration: tracks.duration,
            width: Double(tracks.size.width),
            height: Double(tracks.size.height),
            audioKinds: kinds,
            hasPointer: hasPointer,
            pointPixelScale: metadata?.pointPixelScale,
            webcam: webcam
        )
        let primaryDuration = project.sourceAxisDuration ?? sourceDuration
        mutate { project in
            project.ensurePrimarySource(duration: primaryDuration, kinds: audioKinds, webcam: webcamRecording, pointPixelScale: recording?.pointPixelScale)
            project.appendSource(source, metadata: metadata)
        }
        media.appendedMetadata[source.id] = metadata
        activityCache = nil
        await reloadSources()
        // With Enhance voice on, the new recording's voice is cleaned up too.
        if project.audio.enhanceVoice { startVoiceEnhancementIfNeeded() }
        let added = project.sources.last
        if let added, let time = segments.first(where: { $0.clip.sourceStart >= added.offset - 0.001 })?.timelineStart {
            seek(to: time)
        }
        showNotice("Added \(canonical.lastPathComponent) — \(VideoEditorModel.format(tracks.duration))", symbol: "film.stack")
        return true
    }

    /// Start Over keeps the recordings added to the video, in their order.
    func restoreAddedRecordings(into fresh: inout VideoDemoProject) {
        var metadata = media.appendedMetadata
        for source in project.sources where !source.isPrimary && metadata[source.id] == nil {
            metadata[source.id] = VideoSourceLocator.resolve(source).flatMap { VideoDemoSidecarStore.load(for: $0) }
        }
        fresh.restoreSources(from: project, metadata: metadata)
    }

    /// Camera footage anywhere in the video — this recording's or an added
    /// one's (the Camera tab works with either).
    var hasCameraInAnyRecording: Bool {
        webcamRecording != nil || hasWebcamFootage || project.sources.contains { source in
            !source.isPrimary && (source.webcam.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        }
    }

    func moveSource(_ id: UUID, by delta: Int) {
        guard let index = project.sources.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(index + delta, 0), project.sources.count - 1)
        guard target != index else { return }
        mutate { $0.moveSource(from: index, to: target) }
        Task { await reloadSources() }
    }

    func removeSource(_ id: UUID) {
        var removed = false
        mutate { removed = $0.removeSource(id: id) }
        guard removed else {
            showNotice("The video's own recording can't be removed", symbol: "exclamationmark.triangle")
            return
        }
        Task { await reloadSources() }
        showNotice("Recording removed — ⌘Z to undo", symbol: "trash")
    }
}

/// The recordings in this video, in order, in the Style tab.
struct VideoSourcesSection: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        VideoInspectorSection("Recordings") {
            if model.project.hasAppendedSources {
                VStack(spacing: 4) {
                    ForEach(Array(model.project.sources.enumerated()), id: \.element.id) { index, source in
                        row(source, index: index)
                    }
                }
            }
            Button {
                model.chooseVideoToAppend()
            } label: {
                Label("Append Video…", systemImage: "film.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(VideoSecondaryButtonStyle())
            Text(model.project.hasAppendedSources
                 ? "Each recording keeps its own pointer, clicks, and shortcuts. Reorder them here; cut and trim them on the timeline like any clip."
                 : "Add another recording or video after this one — Shotnix recordings keep their pointer, clicks, and shortcuts.")
                .font(.system(size: 10.5))
                .foregroundStyle(VideoEditorTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ source: VideoProjectSource, index: Int) -> some View {
        let missing = !source.isPrimary && VideoSourceLocator.resolve(source) == nil
        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(VideoEditorTheme.textTertiary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(missing ? Color.orange : VideoEditorTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(missing ? "File not found" : "\(VideoEditorModel.format(source.duration))\(source.hasPointer ? " · pointer" : "")\(source.isPrimary ? " · this recording" : "")")
                    .font(.system(size: 10))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
            }
            Spacer(minLength: 0)
            Button { model.moveSource(source.id, by: -1) } label: {
                Image(systemName: "chevron.up").font(.system(size: 9.5, weight: .bold)).frame(width: 20, height: 20)
            }
            .buttonStyle(VideoToolButtonStyle())
            .disabled(index == 0)
            .help("Move earlier")
            .accessibilityLabel("Move \(source.name) earlier")
            Button { model.moveSource(source.id, by: 1) } label: {
                Image(systemName: "chevron.down").font(.system(size: 9.5, weight: .bold)).frame(width: 20, height: 20)
            }
            .buttonStyle(VideoToolButtonStyle())
            .disabled(index == model.project.sources.count - 1)
            .help("Move later")
            .accessibilityLabel("Move \(source.name) later")
            if !source.isPrimary {
                Button { model.removeSource(source.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 20)
                }
                .buttonStyle(VideoToolButtonStyle(destructive: true))
                .help("Remove from this video")
                .accessibilityLabel("Remove \(source.name)")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(VideoEditorTheme.card))
    }
}

/// Where one recording hands over to the next, on the clip track.
struct VideoSourceBoundaryMarkers: View {
    let boundaries: [(time: Double, name: String)]
    let geometry: VideoTimelineGeometry
    let clipTop: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(boundaries.enumerated()), id: \.offset) { _, boundary in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 2, height: VideoTimelineMetrics.clipTrackHeight + 8)
                    Text(boundary.name)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .frame(height: 14)
                        .background(Capsule().fill(Color.white.opacity(0.92)))
                        .fixedSize()
                        .offset(x: 4, y: VideoTimelineMetrics.clipTrackHeight - 12)
                }
                .offset(x: geometry.x(boundary.time) - 1, y: clipTop - 4)
                .allowsHitTesting(false)
            }
        }
    }
}
