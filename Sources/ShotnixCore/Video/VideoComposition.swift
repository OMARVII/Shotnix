import AVFoundation
import CoreMedia

/// The recording with the timeline's cuts and speed changes applied, as an
/// AVFoundation composition: the preview player plays it directly (so cuts
/// are seamless — no seeking across gaps) and the exporter reads the same
/// one, frame for frame.
struct VideoEditComposition {
    let composition: AVMutableComposition
    let videoTrack: AVMutableCompositionTrack
    /// The camera, cut and retimed exactly like the screen (nil without one).
    var cameraTrack: AVMutableCompositionTrack? = nil
    let audioTracks: [AVMutableCompositionTrack]
    /// What each of `audioTracks` carries (same order).
    var audioKinds: [VideoAudioKind] = []
    var audioMix: AVMutableAudioMix?
    /// Where each segment landed in the composition — the mix follows it.
    var placements: [VideoCompositionBuilder.Placement] = []
    let duration: CMTime
    /// The recording's upright pixel size.
    let sourceSize: CGSize
    /// Transform that makes the recording upright with its origin at zero.
    let orientation: CGAffineTransform
    /// Music under the video (its own volume; clip mutes don't touch it).
    var musicTrack: AVMutableCompositionTrack? = nil
    /// Where the music's loops meet (timeline seconds).
    var musicSeams: [Double] = []
    /// How long the music runs: the edit, plus the export's end card.
    var musicDuration: Double = 0
    /// A click sound on every recorded click.
    var clickTrack: AVMutableCompositionTrack? = nil
    /// With several recordings: the transform that fits each stretch of
    /// the video track into `sourceSize` (starts, in order).
    var pieceTransforms: [(start: CMTime, transform: CGAffineTransform)] = []

    /// Every sound track, for reading the final mix.
    var mixedAudioTracks: [AVMutableCompositionTrack] {
        audioTracks + [musicTrack, clickTrack].compactMap { $0 }
    }

    /// What a video composition must cover: the whole asset, including
    /// music that plays on past the picture (a reader refuses less).
    var coveredDuration: CMTime {
        CMTimeMaximum(duration, composition.duration)
    }
}

struct VideoSourceTracks {
    let asset: AVURLAsset
    let video: AVAssetTrack
    let audio: [AVAssetTrack]
    /// Where each audio track actually has media (often a little shorter
    /// than the video).
    let audioRanges: [CMTimeRange]
    /// Channels per audio track (a mono track next to a stereo one is the mic).
    let audioChannelCounts: [Int]
    let duration: Double
    let size: CGSize
    let orientation: CGAffineTransform
    let frameRate: Double

    static func load(url: URL) async throws -> VideoSourceTracks {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoDemoExportError.missingVideoTrack
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var audioRanges: [CMTimeRange] = []
        var channelCounts: [Int] = []
        for track in audio {
            audioRanges.append((try? await track.load(.timeRange)) ?? CMTimeRange(start: .zero, duration: .positiveInfinity))
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            let channels = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 2
            channelCounts.append(Int(channels))
        }
        let duration = try await asset.load(.duration).seconds
        let naturalSize = try await video.load(.naturalSize)
        let preferred = try await video.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let orientation = preferred.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let nominal = Double(try await video.load(.nominalFrameRate))
        return VideoSourceTracks(
            asset: asset,
            video: video,
            audio: audio,
            audioRanges: audioRanges,
            audioChannelCounts: channelCounts,
            duration: duration.isFinite ? max(duration, 0) : 0,
            size: CGSize(width: abs(rect.width), height: abs(rect.height)),
            orientation: orientation,
            frameRate: nominal > 1 ? nominal : 30
        )
    }
}

/// Everything an edit can carry besides the recording's own cuts: the
/// outro's held frame, other recordings, music, and click sounds.
struct VideoEditExtras {
    /// Seconds after the last clip (the outro card) — the last frame holds.
    var tail: Double = 0
    /// Seconds the music plays on past the edit (the export's end card).
    var musicTail: Double = 0
    /// Other recordings on the source axis (nil: just the one).
    var layout: VideoSourceLayout?
    var music: VideoMusicInput?
    var clicks: VideoClickSoundInput?

    static let none = VideoEditExtras()

    /// What the player item is built from.
    struct StructureKey: Equatable {
        let tail: Double
        let musicTail: Double
        let layout: [String]
        let music: VideoMusicInput.StructureKey?
        let clicks: VideoClickSoundInput.StructureKey?
    }

    /// What only the mix depends on.
    struct MixKey: Equatable {
        let music: VideoMusicInput.MixKey?
        let clickVolume: Double?
    }

    var structureKey: StructureKey {
        StructureKey(tail: (tail * 1000).rounded() / 1000, musicTail: musicTail, layout: layout?.identity ?? [], music: music?.structureKey, clicks: clicks?.structureKey)
    }

    var mixKey: MixKey { MixKey(music: music?.mixKey, clickVolume: clicks?.volume) }
}

enum VideoCompositionBuilder {
    private static let timescale: CMTimeScale = 60_000

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    struct Placement {
        let start: CMTime
        let duration: CMTime
        let segment: VideoDemoTimelineSegment
    }

    /// One stretch of a clip inside one recording.
    private struct Piece {
        let tracks: VideoSourceTracks
        let audio: [VideoAudioSource]
        let camera: VideoCameraSource?
        /// The recording's own seconds.
        let localStart: Double
        let length: Double
        /// Seconds into the clip (source time) where it begins.
        let offsetInClip: Double
        let source: VideoProjectSource?
    }

    private static func pieces(of clip: VideoDemoTimelineClip, primary: VideoSourceTracks, primaryAudio: [VideoAudioSource], camera: VideoCameraSource?, layout: VideoSourceLayout?) -> [Piece] {
        guard let layout else {
            return [Piece(tracks: primary, audio: primaryAudio, camera: camera, localStart: clip.sourceStart, length: clip.sourceDuration, offsetInClip: 0, source: nil)]
        }
        return layout.pieces(from: clip.sourceStart, to: clip.sourceEnd).map { entry, piece in
            Piece(
                tracks: entry.tracks,
                audio: entry.audio,
                camera: entry.camera,
                localStart: piece.localStart,
                length: piece.length,
                offsetInClip: piece.axisStart - clip.sourceStart,
                source: entry.source
            )
        }
    }

    /// Fits a recording's frames into the edit's frame (letterboxed).
    static func fitTransform(for tracks: VideoSourceTracks, into size: CGSize) -> CGAffineTransform {
        let upright = tracks.size
        guard upright.width > 0, upright.height > 0, size.width > 0, size.height > 0 else { return tracks.orientation }
        let scale = min(size.width / upright.width, size.height / upright.height)
        let x = (size.width - upright.width * scale) / 2
        let y = (size.height - upright.height * scale) / 2
        return tracks.orientation
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: x, y: y))
    }

    /// `audioSources` default to the recording's own tracks (all "mixed");
    /// pass resolved kinds / enhanced replacements to control the mix.
    /// `includeAudio: false` leaves the recording's sound out (a muted
    /// export); music and click sounds in `extras` still go in.
    static func build(
        source: VideoSourceTracks,
        segments: [VideoDemoTimelineSegment],
        audio: VideoAudioSettings,
        camera: VideoCameraSource? = nil,
        audioSources: [VideoAudioSource]? = nil,
        includeAudio: Bool = true,
        extras: VideoEditExtras = .none
    ) throws -> VideoEditComposition {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoDemoExportError.cannotCreateCompositionTrack
        }
        videoTrack.preferredTransform = source.orientation
        let sources = audioSources ?? VideoAudioSource.sources(from: source, kinds: Array(repeating: .mixed, count: source.audio.count))
        let layout = extras.layout?.replacingPrimary(tracks: source, audio: sources, camera: camera)
        let clips = segments.filter { $0.clip.sourceDuration > 0.001 }
        var pieceTransforms: [(start: CMTime, transform: CGAffineTransform)] = []

        // Insert back to back from the track's actual end, so rounding can
        // never open a gap (a black frame) between clips.
        var placements: [Placement] = []
        // An empty track's timeRange is INVALID, so the insertion point is
        // tracked explicitly from zero.
        var cursor = CMTime.zero

        /// Holds one frame of `piece` for `seconds` (the intro and outro
        /// cards play over it).
        func hold(_ piece: Piece, atEnd: Bool, seconds: Double) {
            let frame = 1 / max(piece.tracks.frameRate, 1)
            let recordingEnd = max(piece.tracks.duration - frame, 0)
            let at = atEnd ? max(piece.localStart + piece.length - frame, piece.localStart) : piece.localStart
            let range = CMTimeRange(start: time(min(at, recordingEnd)), duration: time(frame))
            let start = cursor
            do {
                try videoTrack.insertTimeRange(range, of: piece.tracks.video, at: start)
                videoTrack.scaleTimeRange(CMTimeRange(start: start, duration: range.duration), toDuration: time(seconds))
            } catch {
                videoTrack.insertEmptyTimeRange(CMTimeRange(start: start, duration: time(seconds)))
            }
            if layout != nil { pieceTransforms.append((start, fitTransform(for: piece.tracks, into: source.size))) }
            let end = videoTrack.timeRange.end
            cursor = end.isNumeric && end > start ? end : start + time(seconds)
        }

        let leadIn = clips.first?.timelineStart ?? 0
        if leadIn > 0.001, let first = clips.first,
           let piece = pieces(of: first.clip, primary: source, primaryAudio: sources, camera: camera, layout: layout).first {
            hold(piece, atEnd: false, seconds: leadIn)
        }

        /// Black for a stretch of a recording that can't be found, so the
        /// edit keeps its timing.
        func gap(_ seconds: Double) {
            guard seconds > 0.001 else { return }
            let start = cursor
            videoTrack.insertEmptyTimeRange(CMTimeRange(start: start, duration: time(seconds)))
            let end = videoTrack.timeRange.end
            cursor = end.isNumeric && end > start ? end : start + time(seconds)
        }

        for segment in clips {
            let start = cursor
            let speed = segment.clip.normalizedSpeed
            var covered = segment.clip.sourceStart
            for piece in pieces(of: segment.clip, primary: source, primaryAudio: sources, camera: camera, layout: layout) {
                gap((segment.clip.sourceStart + piece.offsetInClip - covered) / speed)
                covered = segment.clip.sourceStart + piece.offsetInClip + piece.length
                let pieceStart = cursor
                let sourceRange = CMTimeRange(start: time(piece.localStart), duration: time(piece.length))
                try videoTrack.insertTimeRange(sourceRange, of: piece.tracks.video, at: pieceStart)
                let outputDuration = time(piece.length / speed)
                if abs(speed - 1) > 0.0001 {
                    videoTrack.scaleTimeRange(CMTimeRange(start: pieceStart, duration: sourceRange.duration), toDuration: outputDuration)
                }
                if layout != nil { pieceTransforms.append((pieceStart, fitTransform(for: piece.tracks, into: source.size))) }
                let end = videoTrack.timeRange.end
                cursor = end.isNumeric && end > pieceStart ? end : pieceStart + outputDuration
            }
            gap((segment.clip.sourceEnd - covered) / speed)
            placements.append(Placement(start: start, duration: cursor - start, segment: segment))
        }
        guard !placements.isEmpty else { throw VideoDemoExportError.invalidTrim }

        if extras.tail > 0.001, let last = clips.last,
           let piece = pieces(of: last.clip, primary: source, primaryAudio: sources, camera: camera, layout: layout).last {
            hold(piece, atEnd: true, seconds: extras.tail)
        }

        // Sound goes in whole — volume, mutes, and fades live in the mix, so
        // changing them never rebuilds the player.
        var audioTracks: [AVMutableCompositionTrack] = []
        var audioKinds: [VideoAudioKind] = []
        if includeAudio {
            // One lane per sound track of the primary recording; an added
            // recording's tracks join a lane of the same kind (their pieces
            // never overlap in time), or start one.
            var lanes: [(kind: VideoAudioKind, sources: [String: VideoAudioSource])] = sources.map { ($0.kind, ["primary": $0]) }
            if let layout {
                for entry in layout.entries where !entry.source.isPrimary {
                    var used: [VideoAudioKind: Int] = [:]
                    for audioSource in entry.audio {
                        let nth = used[audioSource.kind, default: 0]
                        used[audioSource.kind] = nth + 1
                        let matching = lanes.indices.filter { lanes[$0].kind == audioSource.kind }
                        if matching.indices.contains(nth) {
                            lanes[matching[nth]].sources[entry.source.id.uuidString] = audioSource
                        } else {
                            lanes.append((audioSource.kind, [entry.source.id.uuidString: audioSource]))
                        }
                    }
                }
            }
            for lane in lanes {
                guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                var inserted = false
                for placement in placements {
                    let clip = placement.segment.clip
                    let speed = clip.normalizedSpeed
                    for piece in pieces(of: clip, primary: source, primaryAudio: sources, camera: camera, layout: layout) {
                        let key = piece.source.map { $0.isPrimary ? "primary" : $0.id.uuidString } ?? "primary"
                        guard let audioSource = lane.sources[key] else { continue }
                        // Recording time → this track's own time.
                        let wanted = CMTimeRange(start: time(piece.localStart - audioSource.offset), duration: time(piece.length))
                        // Only the part the track actually covers — asking
                        // for more fails the whole insert.
                        let sourceRange = wanted.intersection(audioSource.available)
                        guard sourceRange.duration.seconds > 0.001 else { continue }
                        let insertAt = placement.start + time((piece.offsetInClip + (sourceRange.start - wanted.start).seconds) / speed)
                        do {
                            try track.insertTimeRange(sourceRange, of: audioSource.track, at: insertAt)
                        } catch {
                            continue
                        }
                        if abs(speed - 1) > 0.0001 {
                            track.scaleTimeRange(CMTimeRange(start: insertAt, duration: sourceRange.duration), toDuration: time(sourceRange.duration.seconds / speed))
                        }
                        inserted = true
                    }
                }
                if inserted {
                    audioTracks.append(track)
                    audioKinds.append(lane.kind)
                } else {
                    composition.removeTrack(track)
                }
            }
        }

        // The pass-through compositor ignores track transforms: one rotated
        // recording goes without the camera, while with several each
        // stretch is turned upright by the compositor itself.
        let cameraTrack: AVMutableCompositionTrack?
        if let layout {
            cameraTrack = VideoCameraComposition.addCameraTrack(layout: layout, to: composition, placements: placements)
        } else {
            cameraTrack = camera.flatMap { camera in
                source.orientation.isIdentity ? VideoCameraComposition.addCameraTrack(camera, to: composition, placements: placements) : nil
            }
        }

        let total = cursor.seconds
        let musicLength = total + max(extras.musicTail, 0)
        let music = extras.music?.insert(into: composition, duration: musicLength)
        let clicks = extras.clicks?.insert(into: composition, duration: total)

        var edit = VideoEditComposition(
            composition: composition,
            videoTrack: videoTrack,
            cameraTrack: cameraTrack,
            audioTracks: audioTracks,
            audioKinds: audioKinds,
            audioMix: nil,
            placements: placements,
            duration: cursor,
            sourceSize: source.size,
            orientation: source.orientation,
            musicTrack: music?.track,
            musicSeams: music?.seams ?? [],
            musicDuration: music == nil ? 0 : musicLength,
            clickTrack: clicks,
            pieceTransforms: pieceTransforms
        )
        edit.audioMix = audioMix(for: edit, segments: segments, audio: audio, extras: extras)
        return edit
    }

    /// Volumes, per-clip mutes, and fades for the edit's sound (and the
    /// music's level line). Built on its own so a volume change swaps only
    /// this on the playing item.
    static func audioMix(for edit: VideoEditComposition, segments: [VideoDemoTimelineSegment], audio: VideoAudioSettings, extras: VideoEditExtras = .none) -> AVMutableAudioMix? {
        guard !edit.mixedAudioTracks.isEmpty else { return nil }
        // Segments still line up with placements one to one when only
        // sound settings changed; fall back to the placed ones otherwise.
        let current = segments.filter { $0.clip.sourceDuration > 0.001 }
        let aligned = current.count == edit.placements.count
        var parameters: [AVMutableAudioMixInputParameters] = []
        for (index, track) in edit.audioTracks.enumerated() {
            let kind = edit.audioKinds.indices.contains(index) ? edit.audioKinds[index] : .mixed
            let volume = audio.effectiveVolume(for: kind)
            let params = AVMutableAudioMixInputParameters(track: track)
            for (placementIndex, placement) in edit.placements.enumerated() {
                let clip = aligned ? current[placementIndex].clip : placement.segment.clip
                applyVolume(clip.muted ? 0 : volume, fades: clip, start: placement.start, duration: placement.duration, to: params)
            }
            parameters.append(params)
        }
        if let track = edit.musicTrack, let music = extras.music {
            let params = AVMutableAudioMixInputParameters(track: track)
            // Fades out where the music ends (after the end card, if any).
            let length = edit.musicDuration > 0 ? edit.musicDuration : edit.duration.seconds
            let keyframes = VideoMusicMix.envelope(music: music.settings, duration: length, voice: music.voice, seams: edit.musicSeams)
            VideoMusicMix.apply(keyframes, to: params)
            parameters.append(params)
        }
        if let track = edit.clickTrack, let clicks = extras.clicks {
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(Float(min(max(clicks.volume, 0), 1)), at: .zero)
            parameters.append(params)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    private static func applyVolume(
        _ volume: Float,
        fades clip: VideoDemoTimelineClip,
        start: CMTime,
        duration: CMTime,
        to parameters: AVMutableAudioMixInputParameters
    ) {
        let total = duration.seconds
        parameters.setVolume(volume, at: start)
        let fadeIn = min(max(clip.fadeIn, 0), total / 2)
        if fadeIn > 0.001 {
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: CMTimeRange(start: start, duration: time(fadeIn)))
        }
        let fadeOut = min(max(clip.fadeOut, 0), total / 2)
        if fadeOut > 0.001 {
            let end = start + duration
            parameters.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0, timeRange: CMTimeRange(start: end - time(fadeOut), duration: time(fadeOut)))
        }
    }

    /// Video composition that hands the (cut, retimed) recording to a
    /// reader at `frameRate`, upright and unscaled — with several
    /// recordings, each one fitted into the first one's frame.
    static func readerVideoComposition(for edit: VideoEditComposition, frameRate: Double) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: max(edit.sourceSize.width, 2), height: max(edit.sourceSize.height, 2))
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(Int(frameRate.rounded()), 1)))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: edit.coveredDuration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: edit.videoTrack)
        if edit.pieceTransforms.isEmpty {
            layer.setTransform(edit.orientation, at: .zero)
        } else {
            for piece in edit.pieceTransforms {
                layer.setTransform(piece.transform, at: piece.start)
            }
        }
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]
        return videoComposition
    }
}

enum VideoDemoExportError: LocalizedError {
    case missingVideoTrack
    case invalidTrim
    case cannotCreateCompositionTrack
    case cannotCreateExportSession
    case exportFailed(String)
    /// A reader, writer, or file error (mapped to plain words for people).
    case system(Error)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .system(let error):
            return error.localizedDescription
        case .missingVideoTrack:
            return "The selected file has no video track."
        case .invalidTrim:
            return "The timeline is empty."
        case .cannotCreateCompositionTrack:
            return "Could not prepare the video composition."
        case .cannotCreateExportSession:
            return "Could not start the export."
        case .exportFailed(let message):
            return message
        case .cancelled:
            return "Export cancelled."
        }
    }
}
