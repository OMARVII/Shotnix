import AVFoundation
import CoreImage
import CoreVideo

/// The camera movie recorded alongside the screen.
struct VideoCameraSource {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let duration: Double
    let size: CGSize
    /// Camera time = screen time − offset.
    let offset: Double

    static func load(_ recording: VideoWebcamRecording) async -> VideoCameraSource? {
        guard FileManager.default.fileExists(atPath: recording.path) else { return nil }
        let asset = AVURLAsset(url: recording.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0,
              let size = try? await track.load(.naturalSize) else { return nil }
        return VideoCameraSource(asset: asset, track: track, duration: duration, size: size, offset: recording.offset)
    }
}

/// Camera frames handed over by the compositor, keyed by composition time.
/// Frames are copied (and capped at 720p) so the decoder's own buffers are
/// never held.
final class VideoCameraFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(time: Double, image: CIImage)] = []
    private let capacity: Int
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private let context = CIContext(options: [.cacheIntermediates: false, .name: "shotnix.camera-store"])

    init(capacity: Int = 24) {
        self.capacity = capacity
    }

    private let copyLock = NSLock()

    func put(_ buffer: CVPixelBuffer?, at time: Double) {
        guard let buffer else { return }
        copyLock.lock()
        let copy = copyFrame(buffer)
        copyLock.unlock()
        guard let copy else { return }
        lock.lock()
        defer { lock.unlock() }
        // A seek backwards starts a new run.
        if let last = frames.last, time < last.time - 1 { frames.removeAll() }
        frames.removeAll { abs($0.time - time) < 0.0001 }
        frames.append((time, copy))
        if frames.count > capacity { frames.removeFirst(frames.count - capacity) }
    }

    /// The frame composed nearest to `time` (within `tolerance`).
    func frame(at time: Double, tolerance: Double = 0.08) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let best = frames.min(by: { abs($0.time - time) < abs($1.time - time) }),
              abs(best.time - time) <= tolerance else { return nil }
        return best.image
    }

    func removeAll() {
        lock.lock()
        frames.removeAll()
        lock.unlock()
    }

    private func copyFrame(_ buffer: CVPixelBuffer) -> CIImage? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, 720 / Double(height))
        let size = CGSize(width: (Double(width) * scale).rounded(), height: (Double(height) * scale).rounded())
        if pool == nil || poolSize != size {
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: Int(size.width),
                kCVPixelBufferHeightKey: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary, &created)
            pool = created
            poolSize = size
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output else { return nil }
        var image = CIImage(cvPixelBuffer: buffer)
        if scale < 0.999 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        context.render(image, to: output)
        return CIImage(cvPixelBuffer: output)
    }
}

/// One instruction covering the whole edit: which track is the screen,
/// which is the camera, and where camera frames go.
final class VideoCameraInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID
    let store: VideoCameraFrameStore

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID, store: VideoCameraFrameStore) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.store = store
        requiredSourceTrackIDs = [NSNumber(value: screenTrackID), NSNumber(value: cameraTrackID)]
    }
}

/// Passes the screen frame through untouched and files the camera frame
/// for the same moment in the store — both players and the exporter get
/// perfectly matched pairs without running two decoders in lockstep.
final class VideoCameraCompositor: NSObject, AVVideoCompositing {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? VideoCameraInstruction else {
            request.finish(with: NSError(domain: "Shotnix", code: 1))
            return
        }
        let time = request.compositionTime.seconds
        instruction.store.put(request.sourceFrame(byTrackID: instruction.cameraTrackID), at: time)
        if let screen = request.sourceFrame(byTrackID: instruction.screenTrackID) {
            request.finish(withComposedVideoFrame: screen)
        } else if let blank = request.renderContext.newPixelBuffer() {
            request.finish(withComposedVideoFrame: blank)
        } else {
            request.finish(with: NSError(domain: "Shotnix", code: 2))
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}

enum VideoCameraComposition {
    /// Inserts the camera with the same cuts and speed changes as the
    /// screen. Returns nil when no camera footage overlaps the edit.
    static func addCameraTrack(
        _ camera: VideoCameraSource,
        to composition: AVMutableComposition,
        placements: [(start: CMTime, duration: CMTime, segment: VideoDemoTimelineSegment)]
    ) -> AVMutableCompositionTrack? {
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let available = CMTimeRange(start: .zero, duration: VideoCompositionBuilder.time(camera.duration))
        var inserted = false
        for placement in placements {
            let clip = placement.segment.clip
            let speed = clip.normalizedSpeed
            let wantedStart = clip.sourceStart - camera.offset
            let wanted = CMTimeRange(start: VideoCompositionBuilder.time(wantedStart), duration: VideoCompositionBuilder.time(clip.sourceDuration))
            let range = wanted.intersection(available)
            guard range.duration.seconds > 0.02 else { continue }
            let insertAt = placement.start + VideoCompositionBuilder.time((range.start.seconds - wantedStart) / speed)
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
        guard inserted else {
            composition.removeTrack(track)
            return nil
        }
        return track
    }

    /// Video composition that runs the pass-through compositor.
    static func videoComposition(for edit: VideoEditComposition, frameRate: Double, store: VideoCameraFrameStore) -> AVMutableVideoComposition? {
        guard let cameraTrack = edit.cameraTrack else { return nil }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = VideoCameraCompositor.self
        videoComposition.renderSize = CGSize(width: max(edit.sourceSize.width, 2), height: max(edit.sourceSize.height, 2))
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(Int(frameRate.rounded()), 1)))
        videoComposition.instructions = [VideoCameraInstruction(
            timeRange: CMTimeRange(start: .zero, duration: edit.duration),
            screenTrackID: edit.videoTrack.trackID,
            cameraTrackID: cameraTrack.trackID,
            store: store
        )]
        return videoComposition
    }
}
