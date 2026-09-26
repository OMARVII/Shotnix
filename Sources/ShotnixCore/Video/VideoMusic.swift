import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// A song under the whole video. It runs on the edited timeline (cuts and
/// speed changes never chop it up), loops to fill when asked, and dips
/// under the voice.
struct VideoMusicTrack: Codable, Equatable {
    static let volumeRange: ClosedRange<Double> = 0...1
    static let fadeRange: ClosedRange<Double> = 0...8

    /// Shotnix's own copy (Application Support).
    var path: String
    var name: String
    /// The file's length, seconds.
    var duration: Double
    var volume = 0.35
    var fadeIn = 1.5
    var fadeOut = 2.5
    /// Starts over from `startOffset` when the song is shorter than the video.
    var loops = true
    /// Seconds into the song where it starts.
    var startOffset = 0.0
    /// Lowers the music while someone talks.
    var ducking = true
    /// The music's level under the voice, as a fraction of `volume`.
    var duckLevel = 0.3

    init(path: String, name: String, duration: Double) {
        self.path = path
        self.name = name
        self.duration = duration
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// The part of the song that plays (and loops).
    var playableLength: Double { max(duration - min(max(startOffset, 0), duration), 0) }

    private enum CodingKeys: String, CodingKey {
        case path, name, duration, volume, fadeIn, fadeOut, loops, startOffset, ducking, duckLevel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? URL(fileURLWithPath: path).lastPathComponent
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0.35
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 1.5
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 2.5
        loops = try c.decodeIfPresent(Bool.self, forKey: .loops) ?? true
        startOffset = try c.decodeIfPresent(Double.self, forKey: .startOffset) ?? 0
        ducking = try c.decodeIfPresent(Bool.self, forKey: .ducking) ?? true
        duckLevel = try c.decodeIfPresent(Double.self, forKey: .duckLevel) ?? 0.3
    }
}

// MARK: - Placement on the timeline

/// Where the song plays on the output timeline: back-to-back pieces of
/// the file (one, or a loop), and the seams between them.
enum VideoMusicLayout {
    struct Piece: Equatable {
        /// Timeline seconds.
        let start: Double
        /// Song seconds.
        let fileStart: Double
        let length: Double
    }

    static func pieces(music: VideoMusicTrack, timelineDuration: Double, timelineOffset: Double = 0) -> [Piece] {
        let loopStart = min(max(music.startOffset, 0), max(music.duration - 0.05, 0))
        let loopLength = music.duration - loopStart
        guard loopLength > 0.05, timelineDuration > 0.01 else { return [] }
        var pieces: [Piece] = []
        // A range export picks the song up where that part of the video
        // heard it.
        var fileTime = loopStart + timelineOffset
        if music.loops {
            fileTime = loopStart + timelineOffset.truncatingRemainder(dividingBy: loopLength)
        }
        var at = 0.0
        while at < timelineDuration - 0.01 {
            guard fileTime < music.duration - 0.01 else { break }
            let length = min(music.duration - fileTime, timelineDuration - at)
            pieces.append(Piece(start: at, fileStart: fileTime, length: length))
            at += length
            guard music.loops else { break }
            fileTime = loopStart
        }
        return pieces
    }

    /// Timeline moments where one loop ends and the next begins.
    static func seams(_ pieces: [Piece]) -> [Double] {
        pieces.dropFirst().map(\.start)
    }

    /// Where on the song a timeline moment lands (nil: the song is over).
    static func fileTime(at time: Double, pieces: [Piece]) -> Double? {
        guard let piece = pieces.last(where: { time >= $0.start - 0.0001 }), time <= piece.start + piece.length + 0.0001 else { return nil }
        return piece.fileStart + (time - piece.start)
    }
}

// MARK: - Mixing

/// The music's volume over the output timeline: its level, faded in and
/// out, lowered under the voice, with a tiny dip at loop seams so they
/// never click.
enum VideoMusicMix {
    struct Keyframe: Equatable {
        var time: Double
        var volume: Double
    }

    static let duckAttack = 0.25
    static let duckRelease = 0.6
    static let seamDip = 0.02

    /// Speech close together ducks as one stretch (no pumping between words).
    static func mergedVoice(_ ranges: [ClosedRange<Double>], within gap: Double = duckAttack + duckRelease + 0.2) -> [ClosedRange<Double>] {
        var merged: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound - last.upperBound <= gap {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    static func gain(at t: Double, music: VideoMusicTrack, duration: Double, voice: [ClosedRange<Double>], seams: [Double]) -> Double {
        var gain = min(max(music.volume, 0), 1)
        let fadeIn = min(max(music.fadeIn, 0), duration / 2)
        if fadeIn > 0.001 { gain *= min(max(t / fadeIn, 0), 1) }
        let fadeOut = min(max(music.fadeOut, 0), duration / 2)
        if fadeOut > 0.001 { gain *= min(max((duration - t) / fadeOut, 0), 1) }
        if music.ducking {
            let level = min(max(music.duckLevel, 0), 1)
            var duck = 1.0
            for range in voice {
                if t >= range.lowerBound - duckAttack, t <= range.upperBound + duckRelease {
                    let into: Double
                    if t < range.lowerBound {
                        into = 1 - (range.lowerBound - t) / duckAttack
                    } else if t > range.upperBound {
                        into = 1 - (t - range.upperBound) / duckRelease
                    } else {
                        into = 1
                    }
                    duck = min(duck, 1 - (1 - level) * min(max(into, 0), 1))
                }
            }
            gain *= duck
        }
        for seam in seams where abs(t - seam) < seamDip {
            gain *= abs(t - seam) / seamDip
        }
        return gain
    }

    /// Keyframes whose straight-line ramps follow `gain` closely.
    static func envelope(music: VideoMusicTrack, duration: Double, voice rawVoice: [ClosedRange<Double>], seams: [Double] = []) -> [Keyframe] {
        guard duration > 0.01 else { return [] }
        let voice = music.ducking ? mergedVoice(rawVoice) : []
        var times: Set<Double> = [0, duration]
        let fadeIn = min(max(music.fadeIn, 0), duration / 2)
        let fadeOut = min(max(music.fadeOut, 0), duration / 2)
        // Fades are sampled finely: where they overlap a duck, the product
        // of the two isn't a straight line.
        for step in stride(from: 0.0, through: fadeIn, by: 0.25) { times.insert(step) }
        times.insert(fadeIn)
        for step in stride(from: duration - fadeOut, through: duration, by: 0.25) { times.insert(step) }
        times.insert(duration - fadeOut)
        for range in voice {
            times.insert(range.lowerBound - duckAttack)
            times.insert(range.lowerBound)
            times.insert(range.upperBound)
            times.insert(range.upperBound + duckRelease)
        }
        for seam in seams {
            times.insert(seam - seamDip)
            times.insert(seam)
            times.insert(seam + seamDip)
        }
        let sorted = times.filter { $0 >= 0 && $0 <= duration }.sorted()
        var keyframes = sorted.map { Keyframe(time: $0, volume: gain(at: $0, music: music, duration: duration, voice: voice, seams: seams)) }
        // Points on a straight line between their neighbours add nothing.
        var index = 1
        while index + 1 < keyframes.count {
            let a = keyframes[index - 1], b = keyframes[index], c = keyframes[index + 1]
            let expected = a.volume + (c.volume - a.volume) * (b.time - a.time) / max(c.time - a.time, 0.000001)
            if abs(expected - b.volume) < 0.0005 {
                keyframes.remove(at: index)
            } else {
                index += 1
            }
        }
        return keyframes
    }

    static func apply(_ keyframes: [Keyframe], to parameters: AVMutableAudioMixInputParameters) {
        guard let first = keyframes.first else { return }
        parameters.setVolume(Float(first.volume), at: .zero)
        for (a, b) in zip(keyframes, keyframes.dropFirst()) where b.time > a.time + 0.0005 {
            parameters.setVolumeRamp(
                fromStartVolume: Float(a.volume),
                toEndVolume: Float(b.volume),
                timeRange: CMTimeRange(start: VideoCompositionBuilder.time(a.time), end: VideoCompositionBuilder.time(b.time))
            )
        }
    }
}

// MARK: - Voice activity

/// Where someone is talking, found from the voice track's loudness on this
/// Mac — what the music ducks under.
enum VideoVoiceActivity {
    static let rate = 50.0

    /// Speech stretches from a loudness envelope (`rate` values a second):
    /// louder than the room's noise floor, short gaps bridged, blips dropped.
    static func speech(levels: [Float], rate: Double = rate) -> [ClosedRange<Double>] {
        guard levels.count > 2 else { return [] }
        let sorted = levels.sorted()
        let floor = Double(sorted[Int(Double(sorted.count - 1) * 0.15)])
        let loud = Double(sorted[Int(Double(sorted.count - 1) * 0.95)])
        // Nothing louder than a quiet room: no one's talking.
        guard loud > 0.015 else { return [] }
        // Well above the noise floor — but a take with no pauses (the floor
        // is the voice itself) still counts as talking.
        let threshold = max(min(floor * 3.2, loud * 0.5), loud * 0.12, 0.008)
        var ranges: [ClosedRange<Double>] = []
        var start: Int?
        for (index, level) in levels.enumerated() {
            if Double(level) > threshold {
                if start == nil { start = index }
            } else if let from = start {
                ranges.append(Double(from) / rate...Double(index) / rate)
                start = nil
            }
        }
        if let from = start { ranges.append(Double(from) / rate...Double(levels.count) / rate) }
        // Bridge gaps under 0.3 s, then drop anything under 0.12 s.
        var bridged: [ClosedRange<Double>] = []
        for range in ranges {
            if let last = bridged.last, range.lowerBound - last.upperBound < 0.3 {
                bridged[bridged.count - 1] = last.lowerBound...range.upperBound
            } else {
                bridged.append(range)
            }
        }
        return bridged.filter { $0.upperBound - $0.lowerBound >= 0.12 }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [ClosedRange<Double>]] = [:]

    static func cacheKey(url: URL, trackIndex: Int) -> String {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)#\(trackIndex)#\(Int(stamp))"
    }

    static func cached(url: URL, trackIndex: Int) -> [ClosedRange<Double>]? {
        lock.lock()
        defer { lock.unlock() }
        return cache[cacheKey(url: url, trackIndex: trackIndex)]
    }

    /// Speech on one track of a file, in that file's own seconds (cached).
    static func speech(url: URL, trackIndex: Int) async -> [ClosedRange<Double>] {
        if let cached = cached(url: url, trackIndex: trackIndex) { return cached }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), tracks.indices.contains(trackIndex),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else { return [] }
        let offset = (try? await tracks[trackIndex].load(.timeRange))?.start.seconds ?? 0
        let window = Int(16_000 / rate)
        var levels: [Float] = []
        var sum: Float = 0
        var count = 0
        var firstStart: Double?
        do {
            try await VideoAudioReader.read(asset: asset, tracks: [tracks[trackIndex]], format: format) { buffer, start in
                if firstStart == nil { firstStart = start.seconds }
                guard let data = buffer.floatChannelData?[0] else { return }
                for index in 0..<Int(buffer.frameLength) {
                    sum += data[index] * data[index]
                    count += 1
                    if count == window {
                        levels.append((sum / Float(window)).squareRoot())
                        sum = 0
                        count = 0
                    }
                }
            }
        } catch {
            return []
        }
        let shift = firstStart ?? offset
        let ranges = speech(levels: levels).map { ($0.lowerBound + shift)...($0.upperBound + shift) }
        store(ranges, key: cacheKey(url: url, trackIndex: trackIndex))
        return ranges
    }

    private static func store(_ ranges: [ClosedRange<Double>], key: String) {
        lock.lock()
        cache[key] = ranges
        lock.unlock()
    }

    /// Source-time speech → timeline stretches that are still heard (cut
    /// and muted clips drop out; speed changes are applied).
    static func timelineRanges(_ speech: [ClosedRange<Double>], segments: [VideoDemoTimelineSegment]) -> [ClosedRange<Double>] {
        let audible = segments.filter { !$0.clip.muted }
        var ranges: [ClosedRange<Double>] = []
        for range in speech {
            ranges.append(contentsOf: VideoDemoProject.timelineRanges(sourceStart: range.lowerBound, sourceEnd: range.upperBound, segments: audible))
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }
}

// MARK: - Waveform

/// The song's loudness, for its lane on the timeline.
enum VideoMusicWaveform {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: VideoWaveform] = [:]

    private static func cached(_ key: String) -> VideoWaveform? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    private static func store(_ waveform: VideoWaveform, key: String) {
        lock.lock()
        cache[key] = waveform
        lock.unlock()
    }

    static func load(url: URL) async -> VideoWaveform? {
        let key = url.standardizedFileURL.path
        if let cached = cached(key) { return cached }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false) else { return nil }
        let perBucket = Int(8_000 / VideoWaveform.bucketsPerSecond)
        var peaks: [Float] = []
        var current: Float = 0
        var counted = 0
        do {
            try await VideoAudioReader.read(asset: asset, tracks: tracks, format: format) { buffer, _ in
                guard let data = buffer.floatChannelData?[0] else { return }
                for index in 0..<Int(buffer.frameLength) {
                    current = max(current, abs(data[index]))
                    counted += 1
                    if counted >= perBucket {
                        peaks.append(current)
                        current = 0
                        counted = 0
                    }
                }
            }
        } catch {
            return nil
        }
        if counted > 0 { peaks.append(current) }
        let top = peaks.max() ?? 0
        let waveform = VideoWaveform(peaks: top > 0.0001 ? peaks.map { min($0 / top, 1) } : peaks)
        store(waveform, key: key)
        return waveform
    }
}

// MARK: - Composition

/// A sound file's track with its asset kept alive (a track can't be read
/// once its asset is gone).
struct VideoAudioFile {
    let asset: AVURLAsset
    let track: AVAssetTrack

    static func load(_ url: URL) async -> VideoAudioFile? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        return VideoAudioFile(asset: asset, track: track)
    }
}

/// The song, ready to go into an edit.
struct VideoMusicInput {
    let file: VideoAudioFile
    let settings: VideoMusicTrack
    /// Timeline stretches with speech (the music dips under them).
    var voice: [ClosedRange<Double>]
    /// Where the timeline starts on the song's loop (range exports).
    var timelineOffset: Double = 0

    struct StructureKey: Equatable {
        let path: String
        let startOffset: Double
        let loops: Bool
        let timelineOffset: Double
    }

    struct MixKey: Equatable {
        let settings: VideoMusicTrack
        let voice: [ClosedRange<Double>]
    }

    var structureKey: StructureKey { StructureKey(path: settings.path, startOffset: settings.startOffset, loops: settings.loops, timelineOffset: timelineOffset) }
    var mixKey: MixKey { MixKey(settings: settings, voice: voice) }
}

extension VideoMusicInput {
    /// Lays the song along `duration` seconds of the edit. Returns the new
    /// track and where its loops meet.
    func insert(into composition: AVMutableComposition, duration: Double) -> (track: AVMutableCompositionTrack, seams: [Double])? {
        let pieces = VideoMusicLayout.pieces(music: settings, timelineDuration: duration, timelineOffset: timelineOffset)
        guard !pieces.isEmpty,
              let music = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var inserted = false
        for piece in pieces {
            let range = CMTimeRange(start: VideoCompositionBuilder.time(piece.fileStart), duration: VideoCompositionBuilder.time(piece.length))
            do {
                try music.insertTimeRange(range, of: file.track, at: VideoCompositionBuilder.time(piece.start))
                inserted = true
            } catch {
                continue
            }
        }
        guard inserted else {
            composition.removeTrack(music)
            return nil
        }
        return (music, VideoMusicLayout.seams(pieces))
    }
}

// MARK: - Editor

extension VideoEditorModel {
    func chooseMusic() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a song to play under the video"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await addMusic(from: url) }
    }

    /// Copies the song in and puts it under the video.
    func addMusic(from url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0.5 else {
            showNotice("Couldn't read that audio file", symbol: "exclamationmark.triangle.fill")
            return
        }
        let stored: URL
        do {
            stored = try await Task.detached(priority: .userInitiated) { try VideoAssetStore.importFile(url) }.value
        } catch {
            showNotice("Couldn't add that song — \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            return
        }
        var music = VideoMusicTrack(path: stored.path, name: url.lastPathComponent, duration: duration)
        if let previous = project.music {
            // Keep the chosen level and behaviour when swapping songs.
            music.volume = previous.volume
            music.fadeIn = previous.fadeIn
            music.fadeOut = previous.fadeOut
            music.loops = previous.loops
            music.ducking = previous.ducking
            music.duckLevel = previous.duckLevel
        }
        mutate { $0.music = music }
        inspectorTab = .audio
        showNotice("Music added — it dips while you talk", symbol: "music.note")
    }

    func removeMusic() {
        mutate { $0.music = nil }
        showNotice("Music removed — ⌘Z to undo", symbol: "trash")
    }

    func updateMusic(coalesce: String? = nil, _ change: (inout VideoMusicTrack) -> Void) {
        mutate(coalesce: coalesce) { project in
            guard var music = project.music else { return }
            change(&music)
            music.volume = min(max(music.volume, 0), 1)
            music.fadeIn = min(max(music.fadeIn, 0), VideoMusicTrack.fadeRange.upperBound)
            music.fadeOut = min(max(music.fadeOut, 0), VideoMusicTrack.fadeRange.upperBound)
            music.startOffset = min(max(music.startOffset, 0), max(music.duration - 1, 0))
            music.duckLevel = min(max(music.duckLevel, 0), 1)
            project.music = music
        }
    }
}

/// The Audio tab's music controls.
struct VideoMusicSection: View {
    @ObservedObject var model: VideoEditorModel

    var body: some View {
        VideoInspectorSection("Music") {
            if let music = model.project.music {
                HStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VideoEditorTheme.music)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(VideoEditorTheme.music.opacity(0.16)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(music.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(VideoEditorTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(VideoEditorModel.timecode(music.duration))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(VideoEditorTheme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("Replace…") { model.chooseMusic() }
                        Divider()
                        Button("Remove Music", role: .destructive) { model.removeMusic() }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 26, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Music options")
                }
                VideoSliderRow(
                    title: "Volume",
                    value: Binding(get: { music.volume }, set: { value in model.updateMusic(coalesce: "music-volume") { $0.volume = value } }),
                    range: VideoMusicTrack.volumeRange,
                    defaultValue: 0.35,
                    format: { "\(Int(($0 * 100).rounded()))%" },
                    onEditingEnded: { model.endGesture() }
                )
                VideoToggleRow(
                    title: "Lower under your voice",
                    detail: model.hasAudio ? "Dips while you talk, comes back in the pauses" : "This recording has no voice to duck under",
                    isOn: Binding(get: { music.ducking }, set: { value in model.updateMusic { $0.ducking = value } })
                )
                if music.ducking {
                    VideoSliderRow(
                        title: "Under the voice",
                        value: Binding(get: { music.duckLevel }, set: { value in model.updateMusic(coalesce: "music-duck") { $0.duckLevel = value } }),
                        range: 0...1,
                        defaultValue: 0.3,
                        format: { "\(Int(($0 * 100).rounded()))%" },
                        onEditingEnded: { model.endGesture() }
                    )
                }
                HStack(spacing: 12) {
                    compactSlider("Fade in", value: music.fadeIn) { value in model.updateMusic(coalesce: "music-fade-in") { $0.fadeIn = value } }
                    compactSlider("Fade out", value: music.fadeOut) { value in model.updateMusic(coalesce: "music-fade-out") { $0.fadeOut = value } }
                }
                VideoToggleRow(
                    title: "Loop to fill",
                    detail: music.playableLength < model.timelineDuration ? "The song is shorter than the video" : nil,
                    isOn: Binding(get: { music.loops }, set: { value in model.updateMusic { $0.loops = value } })
                )
                VideoSliderRow(
                    title: "Start the song at",
                    value: Binding(get: { music.startOffset }, set: { value in model.updateMusic(coalesce: "music-offset") { $0.startOffset = value.rounded() } }),
                    range: 0...max(music.duration - 1, 1),
                    defaultValue: 0,
                    format: { VideoEditorModel.timecode($0) },
                    onEditingEnded: { model.endGesture() }
                )
            } else {
                Button {
                    model.chooseMusic()
                } label: {
                    Label("Add Music…", systemImage: "music.note")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(VideoSecondaryButtonStyle())
                Text("A song under the whole video — it loops to fill, fades in and out, and dips while you talk. Use music you have the rights to.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(VideoEditorTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func compactSlider(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        VideoSliderRow(
            title: title,
            value: Binding(get: { value }, set: { set(($0 * 2).rounded() / 2) }),
            range: VideoMusicTrack.fadeRange,
            defaultValue: nil,
            format: { String(format: "%.1fs", $0) },
            onEditingEnded: { model.endGesture() }
        )
    }
}

extension VideoEditorTheme {
    static let music = Color(red: 0.98, green: 0.42, blue: 0.62)
}

/// The song's lane: its waveform along the timeline, with the fades and
/// the dips under the voice drawn as its level line. Click to edit.
struct VideoMusicLane: View, Equatable {
    let music: VideoMusicTrack
    let waveform: VideoWaveform?
    let duration: Double
    let voice: [ClosedRange<Double>]
    let geometry: VideoTimelineGeometry
    let model: VideoEditorModel

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.music == b.music && a.waveform?.peaks.count == b.waveform?.peaks.count && a.duration == b.duration && a.voice == b.voice && a.geometry == b.geometry
    }

    var body: some View {
        let pieces = VideoMusicLayout.pieces(music: music, timelineDuration: duration)
        let keyframes = VideoMusicMix.envelope(music: music, duration: duration, voice: voice, seams: VideoMusicLayout.seams(pieces))
        let end = pieces.last.map { $0.start + $0.length } ?? 0
        Canvas { context, size in
            let frame = CGRect(x: geometry.x(0) + 1, y: 0, width: max(CGFloat(end) * geometry.pointsPerSecond - 2, 8), height: size.height)
            let shape = Path(roundedRect: frame, cornerRadius: 6, style: .continuous)
            context.fill(shape, with: .color(VideoEditorTheme.music.opacity(0.22)))
            context.stroke(shape, with: .color(VideoEditorTheme.music.opacity(0.5)), lineWidth: 1)
            var inner = context
            inner.clip(to: shape)
            if let waveform {
                var bars = Path()
                var x = frame.minX + 2
                while x < frame.maxX - 2 {
                    let t = geometry.time(x)
                    let t2 = geometry.time(x + 3)
                    if let a = VideoMusicLayout.fileTime(at: t, pieces: pieces), let b = VideoMusicLayout.fileTime(at: t2, pieces: pieces) {
                        let peak = CGFloat(waveform.peak(from: min(a, b), to: max(a, b) + 0.01))
                        let h = max(peak * (size.height - 6), 1)
                        bars.addRect(CGRect(x: x, y: (size.height - h) / 2, width: 2, height: h))
                    }
                    x += 3
                }
                inner.fill(bars, with: .color(VideoEditorTheme.music.opacity(0.55)))
            }
            // The level line (full volume at the top): fades and dips show
            // their shape whatever the volume.
            if keyframes.count > 1 {
                var line = Path()
                let top = max(music.volume, 0.01)
                for (index, keyframe) in keyframes.enumerated() {
                    let point = CGPoint(x: geometry.x(keyframe.time), y: size.height - 4 - CGFloat(min(keyframe.volume / top, 1)) * (size.height - 8))
                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                inner.stroke(line, with: .color(.white.opacity(0.85)), lineWidth: 1.2)
            }
            if frame.width > 60 {
                inner.draw(
                    Text("\(Image(systemName: "music.note")) \(music.name)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92)),
                    at: CGPoint(x: frame.minX + 8, y: size.height / 2),
                    anchor: .leading
                )
            }
        }
        .frame(width: geometry.width, height: VideoTimelineMetrics.musicLaneHeight)
        .contentShape(Rectangle())
        .onTapGesture { location in
            model.seek(to: geometry.time(location.x))
            model.selection = .none
            model.inspectorTab = .audio
        }
        .help("Music — click to change its volume, fades, and ducking")
    }
}

extension VideoTimelineMetrics {
    static let musicLaneHeight: CGFloat = 26
}
