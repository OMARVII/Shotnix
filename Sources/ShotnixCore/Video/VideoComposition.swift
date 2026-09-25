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
    let audioMix: AVMutableAudioMix?
    let duration: CMTime
    /// The recording's upright pixel size.
    let sourceSize: CGSize
    /// Transform that makes the recording upright with its origin at zero.
    let orientation: CGAffineTransform
}

struct VideoSourceTracks {
    let asset: AVURLAsset
    let video: AVAssetTrack
    let audio: [AVAssetTrack]
    /// Where each audio track actually has media (often a little shorter
    /// than the video).
    let audioRanges: [CMTimeRange]
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
        for track in audio {
            audioRanges.append((try? await track.load(.timeRange)) ?? CMTimeRange(start: .zero, duration: .positiveInfinity))
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
            duration: duration.isFinite ? max(duration, 0) : 0,
            size: CGSize(width: abs(rect.width), height: abs(rect.height)),
            orientation: orientation,
            frameRate: nominal > 1 ? nominal : 30
        )
    }
}

enum VideoCompositionBuilder {
    private static let timescale: CMTimeScale = 60_000

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    static func build(
        source: VideoSourceTracks,
        segments: [VideoDemoTimelineSegment],
        audio: VideoAudioSettings,
        camera: VideoCameraSource? = nil
    ) throws -> VideoEditComposition {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw VideoDemoExportError.cannotCreateCompositionTrack
        }
        videoTrack.preferredTransform = source.orientation

        // Insert back to back from the track's actual end, so rounding can
        // never open a gap (a black frame) between clips.
        var placements: [(start: CMTime, duration: CMTime, segment: VideoDemoTimelineSegment)] = []
        // An empty track's timeRange is INVALID, so the insertion point is
        // tracked explicitly from zero.
        var cursor = CMTime.zero
        for segment in segments where segment.clip.sourceDuration > 0.001 {
            let start = cursor
            let sourceRange = CMTimeRange(start: time(segment.clip.sourceStart), duration: time(segment.clip.sourceDuration))
            try videoTrack.insertTimeRange(sourceRange, of: source.video, at: start)
            let outputDuration = time(segment.duration)
            if abs(segment.clip.normalizedSpeed - 1) > 0.0001 {
                videoTrack.scaleTimeRange(CMTimeRange(start: start, duration: sourceRange.duration), toDuration: outputDuration)
            }
            let end = videoTrack.timeRange.end
            cursor = end.isNumeric && end > start ? end : start + outputDuration
            placements.append((start, cursor - start, segment))
        }
        guard !placements.isEmpty else { throw VideoDemoExportError.invalidTrim }

        var audioTracks: [AVMutableCompositionTrack] = []
        var parameters: [AVMutableAudioMixInputParameters] = []
        let volume = audio.effectiveVolume
        if volume > 0 {
            for (audioIndex, sourceAudio) in source.audio.enumerated() {
                guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let params = AVMutableAudioMixInputParameters(track: track)
                let available = source.audioRanges.indices.contains(audioIndex) ? source.audioRanges[audioIndex] : CMTimeRange(start: .zero, duration: .positiveInfinity)
                var inserted = false
                for placement in placements {
                    let segment = placement.segment
                    guard !segment.clip.muted else { continue }
                    let wanted = CMTimeRange(start: time(segment.clip.sourceStart), duration: time(segment.clip.sourceDuration))
                    // Only the part of the clip the audio track actually
                    // covers — asking for more fails the whole insert.
                    let sourceRange = wanted.intersection(available)
                    guard sourceRange.duration.seconds > 0.001 else { continue }
                    let speed = segment.clip.normalizedSpeed
                    let offset = time((sourceRange.start - wanted.start).seconds / speed)
                    let insertAt = placement.start + offset
                    do {
                        try track.insertTimeRange(sourceRange, of: sourceAudio, at: insertAt)
                    } catch {
                        continue
                    }
                    if abs(speed - 1) > 0.0001 {
                        track.scaleTimeRange(CMTimeRange(start: insertAt, duration: sourceRange.duration), toDuration: time(sourceRange.duration.seconds / speed))
                    }
                    inserted = true
                    applyVolume(volume, fades: segment.clip, start: placement.start, duration: placement.duration, to: params)
                }
                if inserted {
                    audioTracks.append(track)
                    parameters.append(params)
                } else {
                    composition.removeTrack(track)
                }
            }
        }

        let mix: AVMutableAudioMix?
        if parameters.isEmpty {
            mix = nil
        } else {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = parameters
            mix = audioMix
        }

        // The pass-through compositor ignores track transforms, so only
        // upright recordings (every screen recording) get the camera.
        let cameraTrack = camera.flatMap { camera in
            source.orientation.isIdentity ? VideoCameraComposition.addCameraTrack(camera, to: composition, placements: placements) : nil
        }

        return VideoEditComposition(
            composition: composition,
            videoTrack: videoTrack,
            cameraTrack: cameraTrack,
            audioTracks: audioTracks,
            audioMix: mix,
            duration: cursor,
            sourceSize: source.size,
            orientation: source.orientation
        )
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
    /// reader at `frameRate`, upright and unscaled.
    static func readerVideoComposition(for edit: VideoEditComposition, frameRate: Double) -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: max(edit.sourceSize.width, 2), height: max(edit.sourceSize.height, 2))
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(Int(frameRate.rounded()), 1)))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: edit.duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: edit.videoTrack)
        layer.setTransform(edit.orientation, at: .zero)
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
    case cancelled

    var errorDescription: String? {
        switch self {
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
