import AVFoundation
import CoreImage
import CoreVideo
import QuartzCore

/// Carries the playhead separately from the editor model so only views
/// that draw the playhead re-render on every tick.
@MainActor
final class VideoDemoPlaybackClock: ObservableObject {
    @Published var time: Double = 0
}

/// Plays the EDITED composition (cuts and speed changes are real edits, so
/// playback flows across them) and hands decoded frames to the preview
/// renderer. Seeks are chained — one in flight, latest request wins — so
/// scrubbing stays fluid on long recordings.
@MainActor
final class VideoPlaybackController: NSObject {
    /// What the player item is built from. Sound settings (volume, mutes,
    /// fades) are NOT part of it — those only swap the audio mix.
    struct EditStructure: Equatable {
        struct Timing: Equatable {
            let start: Double
            let end: Double
            let speed: Double
        }
        let timings: [Timing]
        let audioSources: [String]
        let hasCamera: Bool
    }

    let player = AVPlayer()
    private(set) var source: VideoSourceTracks?
    /// The camera recorded with the screen, if any.
    private(set) var camera: VideoCameraSource?
    let cameraStore = VideoCameraFrameStore()
    private(set) var edit: VideoEditComposition?
    private var structure: EditStructure?
    /// The sound sources (kinds, enhanced voice) the edit is built from.
    private(set) var audioSources: [VideoAudioSource]?
    /// Counts full player rebuilds (tests check that volume changes don't).
    private(set) var itemRebuilds = 0
    /// Sound inputs of the current mix, so unrelated edits leave it alone.
    private var mixKey: MixKey?

    private struct MixKey: Equatable {
        struct ClipSound: Equatable {
            let muted: Bool
            let fadeIn: Double
            let fadeOut: Double
        }
        let audio: VideoAudioSettings
        let clips: [ClipSound]
    }
    private var output: AVPlayerItemVideoOutput?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var seekInFlight = false
    private var pendingSeek: (time: Double, fast: Bool)?
    /// Set after seeks so the preview pulls the new frame even when the
    /// output doesn't flag it as new (paused player).
    private(set) var frameRequested = true

    private(set) var timelineDuration: Double = 0
    private(set) var isPlaying = false

    var onTick: ((Double) -> Void)?
    var onPlayingChanged: ((Bool) -> Void)?

    override init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.seconds.isFinite else { return }
                self.onTick?(time.seconds)
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            DispatchQueue.main.async {
                guard let self, self.isPlaying != playing else { return }
                self.isPlaying = playing
                self.onPlayingChanged?(playing)
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(url: URL) async throws -> VideoSourceTracks {
        let tracks = try await VideoSourceTracks.load(url: url)
        source = tracks
        return tracks
    }

    /// Adds the camera footage; the next `apply` builds it into the edit.
    func setCamera(_ camera: VideoCameraSource?) {
        self.camera = camera
        structure = nil
    }

    /// Replaces the sound sources; the next `apply` rebuilds the edit.
    func setAudioSources(_ sources: [VideoAudioSource]) {
        audioSources = sources
        structure = nil
    }

    /// The camera frame composed for timeline `time`.
    func cameraFrame(at time: Double) -> CIImage? {
        camera == nil ? nil : cameraStore.frame(at: time)
    }

    /// The camera frame and person mask composed for timeline `time`.
    func cameraPicture(at time: Double) -> VideoCameraFrame? {
        camera == nil ? nil : cameraStore.camera(at: time)
    }

    /// Re-composes the frame under the playhead (e.g. once person masks
    /// are wanted, so the paused preview updates).
    func refreshCurrentFrame() {
        seek(to: currentTime, fast: false)
    }

    /// Rebuilds the player item when the cut list or sound sources changed
    /// (keeping the playhead on the same moment of the recording); volume,
    /// mute, and fade changes just swap the mix on the playing item.
    func apply(segments: [VideoDemoTimelineSegment], audio: VideoAudioSettings, keepSourceTime: Double?) {
        guard let source else { return }
        let next = EditStructure(
            timings: segments.filter { $0.clip.sourceDuration > 0.001 }.map {
                EditStructure.Timing(start: $0.clip.sourceStart, end: $0.clip.sourceEnd, speed: $0.clip.normalizedSpeed)
            },
            audioSources: audioSources?.map(\.identity) ?? [],
            hasCamera: camera != nil
        )
        let nextMix = MixKey(audio: audio, clips: segments.map { MixKey.ClipSound(muted: $0.clip.muted, fadeIn: $0.clip.fadeIn, fadeOut: $0.clip.fadeOut) })
        if next == structure, let edit, let item = player.currentItem {
            if nextMix != mixKey {
                mixKey = nextMix
                item.audioMix = VideoCompositionBuilder.audioMix(for: edit, segments: segments, audio: audio)
            }
            return
        }
        structure = next
        mixKey = nextMix

        guard let built = try? VideoCompositionBuilder.build(source: source, segments: segments, audio: audio, camera: camera, audioSources: audioSources) else { return }
        edit = built
        timelineDuration = built.duration.seconds
        itemRebuilds += 1

        let wasPlaying = isPlaying
        let item = AVPlayerItem(asset: built.composition)
        item.audioMix = built.audioMix
        if let videoComposition = VideoCameraComposition.videoComposition(for: built, frameRate: max(source.frameRate, 30), store: cameraStore) {
            cameraStore.removeAll()
            item.videoComposition = videoComposition
        }
        item.audioTimePitchAlgorithm = .spectral
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        output.suppressesPlayerRendering = true
        item.add(output)
        self.output = output

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.player.pause()
            }
        }
        player.replaceCurrentItem(with: item)

        // The same moment of the recording — or, if it was cut, where the
        // cut is now.
        let target = keepSourceTime.map { source in
            VideoDemoProject.timelineTimeIfIncluded(sourceTime: source, segments: segments)
                ?? segments.first(where: { $0.clip.sourceStart >= source })?.timelineStart
                ?? segments.last?.timelineEnd ?? 0
        } ?? 0
        seek(to: target, fast: false)
        if wasPlaying { player.play() }
    }

    var currentTime: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    func play() {
        guard player.currentItem != nil else { return }
        if currentTime >= timelineDuration - 0.03 {
            seek(to: 0, fast: false)
        }
        player.play()
    }

    func pause() {
        player.pause()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func setRate(_ rate: Float) {
        guard player.currentItem != nil else { return }
        player.rate = rate
    }

    /// `fast` = scrubbing: land near the target quickly; exact on release.
    func seek(to time: Double, fast: Bool) {
        let target = min(max(time, 0), max(timelineDuration, 0))
        guard !seekInFlight else {
            pendingSeek = (target, fast)
            return
        }
        seekInFlight = true
        let tolerance = fast ? CMTime(value: 1, timescale: 30) : .zero
        player.seek(to: VideoCompositionBuilder.time(target), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.seekInFlight = false
                self.frameRequested = true
                if let pending = self.pendingSeek {
                    self.pendingSeek = nil
                    self.seek(to: pending.time, fast: pending.fast)
                }
            }
        }
    }

    /// Timeline time that will be on screen at `hostTime` (smooth between
    /// decoded frames while playing).
    func itemTime(forHostTime hostTime: CFTimeInterval) -> Double? {
        guard let output else { return nil }
        let time = isPlaying ? output.itemTime(forHostTime: hostTime) : player.currentTime()
        guard time.isValid, time.seconds.isFinite else { return nil }
        return time.seconds
    }

    /// The newest decoded frame for display at `hostTime`, with its timeline
    /// time — nil when nothing new is ready.
    func frame(forHostTime hostTime: CFTimeInterval) -> (buffer: CVPixelBuffer, time: Double)? {
        guard let output else { return nil }
        var itemTime = output.itemTime(forHostTime: hostTime)
        if !isPlaying {
            itemTime = player.currentTime()
        }
        guard itemTime.isValid else { return nil }
        if output.hasNewPixelBuffer(forItemTime: itemTime) || frameRequested {
            var display = CMTime.invalid
            if let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &display) {
                frameRequested = false
                let time = display.isValid ? display.seconds : itemTime.seconds
                return (buffer, time.isFinite ? time : 0)
            }
        }
        return nil
    }
}
