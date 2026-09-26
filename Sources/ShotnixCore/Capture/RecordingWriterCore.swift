import AVFoundation
import CoreMedia
import QuartzCore

/// Maps host-clock times — ScreenCaptureKit, the microphone and the camera
/// all stamp their samples with it — to recording time: 0 at the first
/// video frame, with paused stretches cut out.
struct RecordingTimeline: Equatable {
    private(set) var origin: Double?
    private(set) var pauses: [ClosedRange<Double>] = []
    private(set) var pauseStart: Double?

    var hasStarted: Bool { origin != nil }
    var isPaused: Bool { pauseStart != nil }

    mutating func start(at host: Double) {
        if origin == nil { origin = host }
    }

    /// Moves t=0 (the pointer recorder starts before the first frame and
    /// re-anchors once it arrives).
    mutating func reanchor(to host: Double) {
        origin = host
    }

    mutating func pause(at host: Double) {
        if pauseStart == nil { pauseStart = host }
    }

    mutating func resume(at host: Double) {
        guard let start = pauseStart else { return }
        pauseStart = nil
        if host > start { pauses.append(start...host) }
    }

    func isPaused(at host: Double) -> Bool {
        if let pauseStart, host >= pauseStart { return true }
        return pauses.contains { host >= $0.lowerBound && host < $0.upperBound }
    }

    /// Paused seconds between the first frame and `host`.
    func pausedDuration(before host: Double) -> Double {
        guard let origin else { return 0 }
        return pauses.reduce(0) { total, pause in
            total + max(0, min(pause.upperBound, host) - max(pause.lowerBound, origin))
        }
    }

    /// Where a sample taken at `host` lands in the recording: nil while
    /// paused (or before the first frame is known), negative before t=0.
    func time(at host: Double) -> Double? {
        guard let origin, !isPaused(at: host) else { return nil }
        return host - origin - pausedDuration(before: host)
    }

    /// Recorded seconds so far — frozen while paused.
    func duration(at host: Double) -> Double {
        guard let origin else { return 0 }
        let end = pauseStart.map { min($0, host) } ?? host
        return max(0, end - origin - pausedDuration(before: end))
    }
}

/// Where one audio buffer goes on a gap-free track. AVAssetWriter plays
/// audio buffers back to back and ignores gaps in their timestamps, so a
/// microphone that drops out, a pause, or audio captured before the first
/// frame would slide everything after it out of sync with the picture.
struct RecordingAudioPlacement: Equatable {
    /// Seconds of silence to write before the buffer.
    var silence: Double
    /// Seconds to cut from the buffer's start (it overlaps what's written).
    var trim: Double

    /// Drift under this is left alone (lip sync tolerates far more);
    /// anything bigger is filled or trimmed.
    static let tolerance = 0.03

    /// nil: the buffer lies entirely before what's written (or before t=0).
    static func place(start: Double, duration: Double, written: Double) -> RecordingAudioPlacement? {
        guard start + duration > written + 0.0005 else { return nil }
        // The first buffer lands exactly on t=0.
        let tolerance = written > 0 ? Self.tolerance : 0.0005
        let gap = start - written
        if gap > tolerance { return RecordingAudioPlacement(silence: gap, trim: 0) }
        if gap < -tolerance { return RecordingAudioPlacement(silence: 0, trim: -gap) }
        return RecordingAudioPlacement(silence: 0, trim: 0)
    }
}

/// PCM sample buffers for the audio aligner: silence, and buffers with
/// their start cut off. Works for interleaved and planar layouts alike.
enum RecordingAudioBuffers {
    static func silence(frames: Int, format: CMAudioFormatDescription, at time: CMTime) -> CMSampleBuffer? {
        guard frames > 0, let description = pcmDescription(format) else { return nil }
        let planar = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let planes = planar ? Int(description.mChannelsPerFrame) : 1
        let bytesPerPlane = frames * Int(description.mBytesPerFrame)
        let zeros = UnsafeMutableRawPointer.allocate(byteCount: bytesPerPlane, alignment: 16)
        zeros.initializeMemory(as: UInt8.self, repeating: 0, count: bytesPerPlane)
        defer { zeros.deallocate() }
        let list = AudioBufferList.allocate(maximumBuffers: planes)
        defer { free(list.unsafeMutablePointer) }
        for index in 0..<planes {
            list[index] = AudioBuffer(
                mNumberChannels: planar ? 1 : description.mChannelsPerFrame,
                mDataByteSize: UInt32(bytesPerPlane),
                mData: zeros
            )
        }
        return make(frames: frames, format: format, at: time, list: list.unsafePointer)
    }

    /// `buffer` without its first `frames` frames, starting at `time`.
    static func dropping(frames: Int, from buffer: CMSampleBuffer, at time: CMTime) -> CMSampleBuffer? {
        let total = CMSampleBufferGetNumSamples(buffer)
        guard frames > 0, frames < total,
              let format = CMSampleBufferGetFormatDescription(buffer),
              let description = pcmDescription(format) else { return nil }
        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        )
        guard sizeNeeded > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block
        ) == noErr else { return nil }
        return withExtendedLifetime(block) {
            let list = UnsafeMutableAudioBufferListPointer(listPointer)
            let offset = frames * Int(description.mBytesPerFrame)
            for index in 0..<list.count {
                guard let data = list[index].mData, Int(list[index].mDataByteSize) > offset else { return nil }
                list[index].mData = data + offset
                list[index].mDataByteSize -= UInt32(offset)
            }
            return make(frames: total - frames, format: format, at: time, list: UnsafePointer(listPointer))
        }
    }

    /// Float PCM at 48 kHz, for padding a track that never received audio.
    static func defaultFormat(channels: Int) -> CMAudioFormatDescription? {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        return format
    }

    static func sampleRate(of format: CMAudioFormatDescription) -> Double? {
        guard let rate = pcmDescription(format)?.mSampleRate, rate > 0 else { return nil }
        return rate
    }

    private static func pcmDescription(_ format: CMAudioFormatDescription) -> AudioStreamBasicDescription? {
        guard let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              description.mFormatID == kAudioFormatLinearPCM,
              description.mBytesPerFrame > 0 else { return nil }
        return description
    }

    private static func make(frames: Int, format: CMAudioFormatDescription, at time: CMTime, list: UnsafePointer<AudioBufferList>) -> CMSampleBuffer? {
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: frames, presentationTimeStamp: time,
            packetDescriptions: nil, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: list
        ) == noErr else { return nil }
        CMSampleBufferSetDataReady(sample)
        return sample
    }
}

/// Frames the encoder couldn't take in time. They used to vanish silently;
/// now a lasting problem (a tenth of the last few seconds) is reported once.
struct RecordingFrameDrops {
    private(set) var dropped = 0
    private(set) var appended = 0
    private(set) var hasReported = false
    private var recent: [(time: Double, dropped: Bool)] = []

    static let window = 5.0

    /// True the first time drops become worth telling the user about.
    mutating func record(dropped wasDropped: Bool, at time: Double) -> Bool {
        if wasDropped { dropped += 1 } else { appended += 1 }
        recent.append((time, wasDropped))
        if let first = recent.first, time - first.time > Self.window {
            recent.removeAll { time - $0.time > Self.window }
        }
        guard !hasReported, wasDropped else { return false }
        let recentDrops = recent.filter(\.dropped).count
        guard recentDrops >= 15, Double(recentDrops) >= Double(recent.count) * 0.1 else { return false }
        hasReported = true
        return true
    }
}

enum RecordingAudioTarget {
    case system
    case microphone
}

/// Carries the writer + inputs across the writerQueue boundary once, at
/// recording start. AVAssetWriter/-Input aren't Sendable, but after this
/// hand-off they're only ever touched on the writer queue (appends) plus the
/// engine's finish flow, which synchronizes via `writerQueue.sync` first.
struct WriterHandles: @unchecked Sendable {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let systemAudioInput: AVAssetWriterInput?
    let microphoneInput: AVAssetWriterInput?
}

/// Per-buffer writer state, confined to the recording writer queue — the same
/// serial queue SCStream and the microphone delegate already deliver on, so
/// appends run right where the samples arrive. The previous design hopped
/// every buffer (up to 60fps of full-resolution frames) to the main actor,
/// which backed frames up and starved SCK's buffer pool whenever the main
/// thread was busy (opening the menu to stop, hovering UI).
///
/// `@unchecked Sendable`: every member is documented queue-confined — the
/// main actor talks to it only via `writerQueue.async`/`sync`.
final class RecordingWriterCore: @unchecked Sendable {

    /// ~3 seconds of audio buffers (≈47 buffers/sec at 48 kHz / 1024 frames)
    /// kept per track while waiting for the first video frame.
    private static let maximumPendingAudioSamples = 150

    // All state below is touched ONLY on the writer queue.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var frameDuration = CMTime(value: 1, timescale: 30)
    private var timeline = RecordingTimeline()
    private var lastVideoTime: Double?
    private var lastCompleteSampleBuffer: CMSampleBuffer?
    private var pendingSystemAudioSamples: [CMSampleBuffer] = []
    private var pendingMicrophoneSamples: [CMSampleBuffer] = []
    private var droppedPendingAudioSampleCount = 0
    private var audioWritten: [RecordingAudioTarget: Double] = [:]
    private var audioFormats: [RecordingAudioTarget: CMAudioFormatDescription] = [:]
    private var activity = RecordingScreenActivity()
    private var frameDrops = RecordingFrameDrops()
    private var isActive = false
    private var onFirstFrame: ((Double) -> Void)?
    private var onWriterFailure: (() -> Void)?
    private var onFramesDropping: (() -> Void)?

    var screenActivity: [Double] { activity.samples }
    var droppedFrameCount: Int { frameDrops.dropped }
    var appendedFrameCount: Int { frameDrops.appended }
    /// Seconds of audio written per track, for tests and diagnostics.
    func writtenAudio(for target: RecordingAudioTarget) -> Double { audioWritten[target] ?? 0 }

    /// `onFirstFrame` gets the first frame's host time — video t=0.
    func begin(
        handles: WriterHandles,
        frameDuration: CMTime,
        onFirstFrame: @escaping (Double) -> Void,
        onWriterFailure: @escaping () -> Void,
        onFramesDropping: @escaping () -> Void = {}
    ) {
        reset()
        writer = handles.writer
        videoInput = handles.videoInput
        systemAudioInput = handles.systemAudioInput
        microphoneInput = handles.microphoneInput
        self.frameDuration = frameDuration
        self.onFirstFrame = onFirstFrame
        self.onWriterFailure = onWriterFailure
        self.onFramesDropping = onFramesDropping
        isActive = true
    }

    /// Stops accepting delegate-path buffers. Serial-queue ordering guarantees
    /// nothing appends after a caller has seen this take effect via `sync`.
    func deactivate() {
        isActive = false
    }

    func reset() {
        writer = nil
        videoInput = nil
        systemAudioInput = nil
        microphoneInput = nil
        timeline = RecordingTimeline()
        lastVideoTime = nil
        lastCompleteSampleBuffer = nil
        pendingSystemAudioSamples.removeAll()
        pendingMicrophoneSamples.removeAll()
        droppedPendingAudioSampleCount = 0
        audioWritten.removeAll()
        audioFormats.removeAll()
        activity = RecordingScreenActivity()
        frameDrops = RecordingFrameDrops()
        isActive = false
        onFirstFrame = nil
        onWriterFailure = nil
        onFramesDropping = nil
    }

    func pause(at host: Double) {
        timeline.pause(at: host)
    }

    func resume(at host: Double) {
        timeline.resume(at: host)
    }

    /// `dirtyRects` are in output pixels; `pixelsPerPoint` turns them into
    /// screen points for the activity threshold.
    func appendVideo(_ sampleBuffer: CMSampleBuffer, dirtyRects: [CGRect]? = nil, pixelsPerPoint: CGFloat = 1) {
        guard isActive, let writer, let input = videoInput else { return }

        let host = sampleBuffer.presentationTimeStamp.seconds
        if !timeline.hasStarted {
            // Paused before the first frame arrived: t=0 waits for resume.
            guard !timeline.isPaused else { return }
            timeline.start(at: host)
            // Video t=0 is this frame, not stream start — the engine re-anchors
            // cursor/click metadata to it on the main actor.
            writer.startSession(atSourceTime: .zero)
            onFirstFrame?(host)
            flushPendingAudioSamples()
        }

        guard let time = timeline.time(at: host), time >= 0 else { return }
        if let lastVideoTime, time <= lastVideoTime { return }
        guard input.isReadyForMoreMediaData else {
            if frameDrops.record(dropped: true, at: time) { onFramesDropping?() }
            return
        }
        let presentationTime = CMTime(seconds: time, preferredTimescale: 60_000)
        guard let retimed = Self.copy(sampleBuffer: sampleBuffer, presentationTime: presentationTime, duration: frameDuration) else { return }

        if input.append(retimed) {
            lastVideoTime = time
            lastCompleteSampleBuffer = sampleBuffer
            _ = frameDrops.record(dropped: false, at: time)
            keepAudioUp(with: time)
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                activity.observe(
                    time: time,
                    dirtyRects: dirtyRects,
                    frameSize: CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)),
                    pixelsPerPoint: pixelsPerPoint,
                    grid: { RecordingScreenActivity.grid(of: pixelBuffer) }
                )
            }
        } else if let error = writer.error {
            print("[Shotnix] Asset writer append failed: \(error)")
            if writer.status == .failed {
                onWriterFailure?()
            }
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer, to target: RecordingAudioTarget) {
        guard isActive else { return }
        guard timeline.hasStarted else {
            switch target {
            case .system:
                pendingSystemAudioSamples.append(sampleBuffer)
                if pendingSystemAudioSamples.count > Self.maximumPendingAudioSamples {
                    pendingSystemAudioSamples.removeFirst()
                    droppedPendingAudioSampleCount += 1
                }
            case .microphone:
                pendingMicrophoneSamples.append(sampleBuffer)
                if pendingMicrophoneSamples.count > Self.maximumPendingAudioSamples {
                    pendingMicrophoneSamples.removeFirst()
                    droppedPendingAudioSampleCount += 1
                }
            }
            return
        }
        appendReadyAudioSample(sampleBuffer, to: target)
    }

    /// The freeze-frame appended at stop so the video runs to the moment the
    /// user hit stop (or paused, if the recording ended paused). Explicit call
    /// from the finish flow — works after `deactivate()`, which only gates the
    /// delegate paths. Returns the recording's end, in recording seconds.
    @discardableResult
    func appendFinalStaticFrame(at host: Double) -> Double {
        let end = timeline.duration(at: host)
        guard let input = videoInput,
              input.isReadyForMoreMediaData,
              let lastVideoTime,
              let lastSampleBuffer = lastCompleteSampleBuffer,
              end > lastVideoTime + frameDuration.seconds,
              let retimed = Self.copy(sampleBuffer: lastSampleBuffer, presentationTime: CMTime(seconds: end, preferredTimescale: 60_000), duration: frameDuration)
        else { return end }
        _ = input.append(retimed)
        return end
    }

    /// A source that goes quiet — a microphone unplugged with nothing to
    /// switch to, no system sound being sent — is padded with silence as the
    /// video moves on, so its track never falls far behind and there's no
    /// minutes-long gap to fill in one go when it comes back. Half a second
    /// of slack leaves room for buffers still on their way.
    private func keepAudioUp(with videoTime: Double) {
        for target in [RecordingAudioTarget.microphone, .system] {
            guard input(for: target) != nil, let format = audioFormats[target] else { continue }
            let written = audioWritten[target] ?? 0
            guard videoTime - written > 1 else { continue }
            writeSilence(videoTime - 0.5 - written, format: format, to: target)
        }
    }

    /// Fills every audio track with silence up to `end`, so a microphone that
    /// went quiet (or never started) still spans the whole recording.
    func padAudio(to end: Double) {
        for target in [RecordingAudioTarget.microphone, .system] where input(for: target) != nil {
            let written = audioWritten[target] ?? 0
            guard end - written > RecordingAudioPlacement.tolerance,
                  let format = audioFormats[target] ?? RecordingAudioBuffers.defaultFormat(channels: target == .system ? 2 : 1) else { continue }
            writeSilence(end - written, format: format, to: target)
        }
    }

    private func flushPendingAudioSamples() {
        if droppedPendingAudioSampleCount > 0 {
            print("[Shotnix] Dropped \(droppedPendingAudioSampleCount) audio sample buffers while waiting for the first video frame")
            droppedPendingAudioSampleCount = 0
        }
        // Anything captured before t=0 is trimmed away by the placement.
        pendingSystemAudioSamples.forEach { appendReadyAudioSample($0, to: .system) }
        pendingSystemAudioSamples.removeAll()
        pendingMicrophoneSamples.forEach { appendReadyAudioSample($0, to: .microphone) }
        pendingMicrophoneSamples.removeAll()
    }

    private func input(for target: RecordingAudioTarget) -> AVAssetWriterInput? {
        switch target {
        case .system: systemAudioInput
        case .microphone: microphoneInput
        }
    }

    private func appendReadyAudioSample(_ sampleBuffer: CMSampleBuffer, to target: RecordingAudioTarget) {
        guard let input = input(for: target),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let rate = RecordingAudioBuffers.sampleRate(of: format),
              // Captured while paused: not part of the recording.
              let start = timeline.time(at: sampleBuffer.presentationTimeStamp.seconds) else { return }
        audioFormats[target] = format
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let duration = Double(frames) / rate
        guard var placement = RecordingAudioPlacement.place(start: start, duration: duration, written: audioWritten[target] ?? 0),
              input.isReadyForMoreMediaData else { return }
        if placement.silence > 0 {
            writeSilence(placement.silence, format: format, to: target)
            // The encoder filled up before the gap was closed: skip this
            // buffer, the next one continues the silence.
            guard let caughtUp = RecordingAudioPlacement.place(start: start, duration: duration, written: audioWritten[target] ?? 0),
                  caughtUp.silence == 0 else { return }
            placement = caughtUp
        }
        let trimFrames = Int((placement.trim * rate).rounded())
        guard trimFrames < frames else { return }
        let position = audioWritten[target] ?? 0
        let time = CMTime(value: CMTimeValue((position * rate).rounded()), timescale: CMTimeScale(rate))
        let sample = trimFrames > 0
            ? RecordingAudioBuffers.dropping(frames: trimFrames, from: sampleBuffer, at: time)
            : Self.copy(sampleBuffer: sampleBuffer, presentationTime: time, duration: CMTime(value: 1, timescale: CMTimeScale(rate)))
        guard let sample, input.isReadyForMoreMediaData, input.append(sample) else { return }
        audioWritten[target] = position + Double(frames - trimFrames) / rate
    }

    private func writeSilence(_ seconds: Double, format: CMAudioFormatDescription, to target: RecordingAudioTarget) {
        guard let input = input(for: target), let rate = RecordingAudioBuffers.sampleRate(of: format) else { return }
        var remaining = Int((seconds * rate).rounded())
        while remaining > 0, input.isReadyForMoreMediaData {
            // A second at a time keeps a long dropout from allocating minutes of zeros.
            let frames = min(remaining, Int(rate))
            let position = audioWritten[target] ?? 0
            let time = CMTime(value: CMTimeValue((position * rate).rounded()), timescale: CMTimeScale(rate))
            guard let silence = RecordingAudioBuffers.silence(frames: frames, format: format, at: time),
                  input.append(silence) else { return }
            audioWritten[target] = position + Double(frames) / rate
            remaining -= frames
        }
    }

    static func copy(sampleBuffer: CMSampleBuffer, presentationTime: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: duration.isValid ? duration : .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var copied: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copied
        )
        guard status == noErr else { return nil }
        return copied
    }
}
