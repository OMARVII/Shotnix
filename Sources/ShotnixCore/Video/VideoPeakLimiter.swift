import AVFoundation
import MediaToolbox

/// Sound turned up past what was recorded (a level above 100%, Even out
/// loudness) would crackle where it goes past full scale. A limiter turns
/// just those moments down, smoothly, and leaves everything else as it is.
enum VideoPeakLimit {
    /// −1 dBFS: room for the encoder's own overshoot.
    static let ceiling: Float = 0.891
    /// The export looks this far ahead, so it starts turning a peak down
    /// before it arrives (a smooth dip instead of a clipped edge).
    static let lookahead = 0.002
    /// How fast the level comes back after a peak.
    static let release = 0.08
}

/// The export's limiter, on interleaved float samples with every channel
/// turned down together. Each sample comes out `latency` frames later; at
/// or under the ceiling it comes out exactly as it went in.
struct VideoLookaheadLimiter {
    let channels: Int
    let ceiling: Float
    /// Frames between a sample going in and coming out.
    let latency: Int

    private let window: Int
    private let releaseCoefficient: Float
    /// The last `window` frames, interleaved (where the output comes from).
    private var delay: [Float]
    /// The gains the last `window` frames need, smallest first (a sliding
    /// minimum: frame number and gain).
    private var minimumFrames: [Int]
    private var minimumGains: [Float]
    private var minimumHead = 0
    private var minimumCount = 0
    /// The needed gain, let back up slowly after a peak.
    private var envelope: Float = 1
    /// The envelope's last `window` values and their sum: their average is
    /// the gain applied, which ramps down over the look-ahead.
    private var recent: [Float]
    private var recentSum: Double
    private var frame = 0

    init(channels: Int, sampleRate: Double, ceiling: Float = VideoPeakLimit.ceiling, lookahead: Double = VideoPeakLimit.lookahead, release: Double = VideoPeakLimit.release) {
        self.channels = max(channels, 1)
        self.ceiling = ceiling
        window = max(Int((lookahead * sampleRate).rounded()), 1)
        latency = window - 1
        releaseCoefficient = Float(exp(-1 / max(release * sampleRate, 1)))
        delay = [Float](repeating: 0, count: window * self.channels)
        minimumFrames = [Int](repeating: 0, count: window)
        minimumGains = [Float](repeating: 1, count: window)
        recent = [Float](repeating: 1, count: window)
        recentSum = Double(window)
    }

    /// Limits `samples` in place (interleaved; a whole number of frames).
    mutating func process(_ samples: UnsafeMutableBufferPointer<Float>) {
        let frames = samples.count / channels
        for index in 0..<frames {
            let base = index * channels
            var peak: Float = 0
            for channel in 0..<channels { peak = max(peak, abs(samples[base + channel])) }
            let needed = peak > ceiling ? ceiling / peak : 1

            // Sliding minimum over the look-ahead window: drop frames that
            // left it, then ones this frame outranks, then add it.
            while minimumCount > 0, minimumFrames[minimumHead] <= frame - window {
                minimumHead = (minimumHead + 1) % window
                minimumCount -= 1
            }
            while minimumCount > 0 {
                let last = (minimumHead + minimumCount - 1) % window
                guard minimumGains[last] >= needed else { break }
                minimumCount -= 1
            }
            let slot = (minimumHead + minimumCount) % window
            minimumFrames[slot] = frame
            minimumGains[slot] = needed
            minimumCount += 1
            let lowest = minimumGains[minimumHead]

            // Down at once (the window already saw the peak coming), back up slowly.
            envelope = lowest < envelope ? lowest : lowest + (envelope - lowest) * releaseCoefficient
            let ring = frame % window
            recentSum += Double(envelope) - Double(recent[ring])
            recent[ring] = envelope
            let gain = recentSum >= Double(window) - 1e-9 ? 1 : Float(recentSum / Double(window))

            // The frame `latency` back leaves the delay as this one enters.
            let delayBase = ring * channels
            for channel in 0..<channels {
                let incoming = samples[base + channel]
                let outgoing = delay[((frame + 1) % window) * channels + channel]
                delay[delayBase + channel] = incoming
                // Clamped too, for rounding in the running sum.
                samples[base + channel] = window == 1 ? incoming * gain : min(max(outgoing * gain, -ceiling), ceiling)
            }
            frame += 1
        }
    }
}

/// The mixed sound an export writes: Even out loudness's gain, then the
/// limiter. Its look-ahead is taken back out, so the sound stays exactly
/// in step with the picture and keeps every sample.
final class VideoLimitedAudio {
    private let source: () -> CMSampleBuffer?
    private let gain: Float
    private var limiter: VideoLookaheadLimiter?
    private var format: CMAudioFormatDescription?
    private var sampleRate = 48_000.0
    private var channels = 2
    private var start: CMTime?
    private var written = 0
    /// Frames still to drop at the start: the limiter's latency.
    private var dropping = 0
    private var ended = false

    init(gain: Double, source: @escaping () -> CMSampleBuffer?) {
        self.gain = Float(gain)
        self.source = source
    }

    /// The next buffer to write, or nil at the end.
    func next() -> CMSampleBuffer? {
        while !ended {
            guard let raw = source() else {
                ended = true
                return flush()
            }
            guard let samples = floats(in: raw) else { return raw }
            if let produced = limit(samples), produced.count >= channels, let buffer = makeBuffer(produced) {
                return buffer
            }
        }
        return nil
    }

    /// Float samples of an interleaved buffer (starting the limiter on the
    /// first one), or nil for any other kind of sound, which is passed on.
    private func floats(in sample: CMSampleBuffer) -> [Float]? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              stream.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              stream.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              stream.mBitsPerChannel == 32,
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        if limiter == nil {
            format = description
            sampleRate = stream.mSampleRate > 0 ? stream.mSampleRate : 48_000
            channels = max(Int(stream.mChannelsPerFrame), 1)
            let limiter = VideoLookaheadLimiter(channels: channels, sampleRate: sampleRate)
            dropping = limiter.latency
            self.limiter = limiter
            start = CMSampleBufferGetPresentationTimeStamp(sample)
        }
        let length = CMBlockBufferGetDataLength(block)
        var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        let copied = samples.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: base) == noErr
        }
        return copied ? samples : nil
    }

    /// Gain and limit, minus the frames the look-ahead pushed out.
    private func limit(_ input: [Float]) -> [Float]? {
        guard limiter != nil else { return nil }
        var samples = input
        if gain != 1 {
            for index in samples.indices { samples[index] *= gain }
        }
        samples.withUnsafeMutableBufferPointer { limiter!.process($0) }
        let frames = samples.count / channels
        let dropped = min(dropping, frames)
        dropping -= dropped
        return dropped == 0 ? samples : Array(samples[(dropped * channels)...])
    }

    /// What's still in the limiter once the sound ends.
    private func flush() -> CMSampleBuffer? {
        guard let limiter, limiter.latency > 0 else { return nil }
        guard let produced = limit([Float](repeating: 0, count: limiter.latency * channels)), produced.count >= channels else { return nil }
        return makeBuffer(produced)
    }

    private func makeBuffer(_ samples: [Float]) -> CMSampleBuffer? {
        guard let format, let start else { return nil }
        let frames = samples.count / channels
        let length = frames * channels * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let replaced = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard replaced == noErr else { return nil }
        let timescale = CMTimeScale(sampleRate.rounded())
        let time = CMTimeAdd(start, CMTime(value: CMTimeValue(written), timescale: timescale))
        written += frames
        var result: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: frames,
            presentationTimeStamp: time,
            packetDescriptions: nil,
            sampleBufferOut: &result
        )
        return status == noErr ? result : nil
    }
}

/// The editor's limiter for a track turned up past 100%. It sits on the
/// track before the mix applies the level line, so it's handed that line
/// and turns down whatever the level would push past the ceiling. No
/// look-ahead (playback can't wait): a peak is met at once, then let go
/// smoothly. The export uses the look-ahead limiter on the whole mix.
enum VideoPreviewLimiter {
    /// A tap for `parameters` playing at `levels` (timeline seconds).
    static func tap(levels: [VideoMusicMix.Keyframe], ceiling: Float = VideoPeakLimit.ceiling) -> MTAudioProcessingTap? {
        guard levels.contains(where: { $0.volume > 1.0005 }) else { return nil }
        let state = VideoPreviewLimiterState(levels: levels, ceiling: ceiling)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(state).toOpaque(),
            init: previewLimiterInit,
            finalize: previewLimiterFinalize,
            prepare: previewLimiterPrepare,
            unprepare: previewLimiterUnprepare,
            process: previewLimiterProcess
        )
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr else {
            Unmanaged<VideoPreviewLimiterState>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        return tap
    }
}

/// One tap's level line and running gain (touched only on the audio thread
/// once playing).
final class VideoPreviewLimiterState {
    let times: [Double]
    let levels: [Float]
    let highest: Float
    let ceiling: Float
    var releaseCoefficient: Float = 1
    var sampleRate = 48_000.0
    var isFloat = true
    var gain: Float = 1
    /// Where the last stretch of sound ended (timeline seconds).
    var reached = Double.nan
    private var cursor = 0

    init(levels: [VideoMusicMix.Keyframe], ceiling: Float) {
        // In time order already (clip after clip); a clip's end and the
        // next one's start may share a moment.
        times = levels.map(\.time)
        self.levels = levels.map { Float($0.volume) }
        highest = self.levels.max() ?? 1
        self.ceiling = ceiling
    }

    func prepare(sampleRate: Double, isFloat: Bool) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        releaseCoefficient = Float(exp(-1 / max(VideoPeakLimit.release * self.sampleRate, 1)))
        self.isFloat = isFloat
        gain = 1
        reached = .nan
        cursor = 0
    }

    /// The level line at `time` (straight between its points).
    func level(at time: Double) -> Float {
        guard let first = times.first, time.isFinite else { return highest }
        if time <= first { return levels[0] }
        if cursor >= times.count || times[cursor] > time { cursor = 0 }
        while cursor + 1 < times.count, times[cursor + 1] < time { cursor += 1 }
        guard cursor + 1 < times.count else { return levels[levels.count - 1] }
        let a = times[cursor], b = times[cursor + 1]
        guard b - a > 0.000001 else { return levels[cursor + 1] }
        return levels[cursor] + (levels[cursor + 1] - levels[cursor]) * Float((time - a) / (b - a))
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, range: CMTimeRange) {
        guard isFloat, frames > 0 else { return }
        var start = range.start.isNumeric ? range.start.seconds : reached
        let span = range.duration.isNumeric && range.duration.seconds > 0 ? range.duration.seconds : Double(frames) / sampleRate
        if start.isFinite, reached.isFinite, abs(start - reached) > 0.25 {
            gain = 1 // a seek: start over
        }
        if !start.isFinite { start = .nan }
        reached = start + span
        let step = span / Double(frames)
        // No allocations here: this runs on the audio thread.
        for index in 0..<frames {
            var peak: Float = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let stride = max(Int(buffer.mNumberChannels), 1)
                let samples = data.assumingMemoryBound(to: Float.self)
                for channel in 0..<stride { peak = max(peak, abs(samples[index * stride + channel])) }
            }
            let level = start.isFinite ? level(at: start + step * Double(index)) : highest
            let heard = peak * level
            let needed = heard > ceiling ? ceiling / heard : 1
            gain = needed < gain ? needed : needed + (gain - needed) * releaseCoefficient
            guard gain < 0.99999 else { continue }
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let stride = max(Int(buffer.mNumberChannels), 1)
                let samples = data.assumingMemoryBound(to: Float.self)
                for channel in 0..<stride { samples[index * stride + channel] *= gain }
            }
        }
    }
}

private let previewLimiterInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let previewLimiterFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<VideoPreviewLimiterState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let previewLimiterPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let state = Unmanaged<VideoPreviewLimiterState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let description = format.pointee
    state.prepare(sampleRate: description.mSampleRate, isFloat: description.mFormatFlags & kAudioFormatFlagIsFloat != 0 && description.mBitsPerChannel == 32)
}

private let previewLimiterUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let previewLimiterProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferList, framesOut, flagsOut in
    var range = CMTimeRange()
    guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut) == noErr else { return }
    let state = Unmanaged<VideoPreviewLimiterState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    state.process(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(framesOut.pointee), range: range)
}
