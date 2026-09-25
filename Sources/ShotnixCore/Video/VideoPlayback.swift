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
    struct EditSignature: Equatable {
        let clips: [VideoDemoTimelineClip]
        let audio: VideoAudioSettings
    }

    let player = AVPlayer()
    private(set) var source: VideoSourceTracks?
    /// The camera recorded with the screen, if any.
    private(set) var camera: VideoCameraSource?
    let cameraStore = VideoCameraFrameStore()
    private(set) var edit: VideoEditComposition?
    private var signature: EditSignature?
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
        signature = nil
    }

    /// The camera frame composed for timeline `time`.
    func cameraFrame(at time: Double) -> CIImage? {
        camera == nil ? nil : cameraStore.frame(at: time)
    }

    /// Rebuilds the player item when the cut list or audio changed; keeps
    /// the playhead on the same moment of the recording.
    func apply(segments: [VideoDemoTimelineSegment], audio: VideoAudioSettings, keepSourceTime: Double?) {
        guard let source else { return }
        let next = EditSignature(clips: segments.map(\.clip), audio: audio)
        guard next != signature else { return }
        let onlyAudioChanged = signature?.clips == next.clips && edit != nil
        signature = next

        guard let built = try? VideoCompositionBuilder.build(source: source, segments: segments, audio: audio, camera: camera) else { return }
        edit = built
        timelineDuration = built.duration.seconds

        if onlyAudioChanged, let item = player.currentItem, item.asset === built.composition {
            item.audioMix = built.audioMix
            return
        }

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

        let target = keepSourceTime.flatMap { VideoDemoProject.timelineTimeIfIncluded(sourceTime: $0, segments: segments) } ?? 0
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
