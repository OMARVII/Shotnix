import AVFoundation
import AudioToolbox
import CoreMedia

// MARK: - Track kinds

/// What an audio track in a recording carries.
enum VideoAudioKind: String, Codable, Equatable {
    /// Your voice.
    case microphone
    /// Sound playing on the Mac.
    case system
    /// Unknown or mixed (videos not recorded by Shotnix).
    case mixed

    /// Kinds for a file's audio tracks, in track order. Recordings say what
    /// they wrote; for older ones a mono track next to a stereo one is the
    /// microphone.
    static func resolve(recorded: [VideoAudioKind]?, channelCounts: [Int]) -> [VideoAudioKind] {
        if let recorded, recorded.count == channelCounts.count { return recorded }
        if channelCounts == [1, 2] { return [.microphone, .system] }
        if channelCounts == [2, 1] { return [.system, .microphone] }
        return Array(repeating: .mixed, count: channelCounts.count)
    }

    /// The track that carries the voice: the microphone, or the only track
    /// of a video with a single unknown track.
    static func voiceTrackIndex(in kinds: [VideoAudioKind]) -> Int? {
        if let index = kinds.firstIndex(of: .microphone) { return index }
        return kinds == [.mixed] ? 0 : nil
    }
}

/// One audio track to build into the edit, possibly replaced by its
/// enhanced (voice-isolated) version.
struct VideoAudioSource {
    let track: AVAssetTrack
    /// Where the track has media, in ITS OWN time.
    let available: CMTimeRange
    let kind: VideoAudioKind
    /// Recording time = track time + offset (enhanced files start at 0).
    var offset: Double = 0
    /// Stable identity for "did the sources change?".
    let identity: String

    /// The recording's tracks, with the voice replaced by its enhanced
    /// version when that's wanted and already processed.
    static func resolved(from source: VideoSourceTracks, kinds: [VideoAudioKind], enhanceVoice: Bool) async -> [VideoAudioSource] {
        var sources = self.sources(from: source, kinds: kinds)
        guard enhanceVoice,
              let index = VideoAudioKind.voiceTrackIndex(in: kinds),
              sources.indices.contains(index) else { return sources }
        let url = VideoVoiceEnhancer.cacheURL(for: source.asset.url, trackIndex: index)
        guard FileManager.default.fileExists(atPath: url.path) else { return sources }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let range = try? await track.load(.timeRange) else { return sources }
        let offset = source.audioRanges.indices.contains(index) ? source.audioRanges[index].start.seconds : 0
        sources[index] = VideoAudioSource(track: track, available: range, kind: sources[index].kind, offset: offset, identity: url.path)
        return sources
    }

    static func sources(from source: VideoSourceTracks, kinds: [VideoAudioKind]) -> [VideoAudioSource] {
        source.audio.enumerated().map { index, track in
            VideoAudioSource(
                track: track,
                available: source.audioRanges.indices.contains(index) ? source.audioRanges[index] : CMTimeRange(start: .zero, duration: .positiveInfinity),
                kind: kinds.indices.contains(index) ? kinds[index] : .mixed,
                identity: "\(source.asset.url.path)#\(index)"
            )
        }
    }
}

// MARK: - Voice enhancement

/// Cleans up a voice track on this Mac: Apple's voice isolation (removes
/// room noise, fans, keyboard clatter), a rumble filter, and gentle
/// compression so quiet and loud words sit closer together.
enum VideoVoiceEnhancer {
    static let version = 1

    enum Failure: LocalizedError {
        case unavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Voice enhancement isn't available on this Mac."
            case .failed(let message): return message
            }
        }
    }

    /// Where the enhanced version of `track` in `recording` is cached.
    static func cacheURL(for recording: URL, trackIndex: Int) -> URL {
        let attributes = try? FileManager.default.attributesOfItem(atPath: recording.path)
        let stamp = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = Data("\(recording.standardizedFileURL.path)|\(trackIndex)|\(Int(stamp))|v\(version)".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return VideoStorageLocation.root
            .appendingPathComponent("Shotnix", isDirectory: true)
            .appendingPathComponent("VideoAudio", isDirectory: true)
            .appendingPathComponent(String(key.suffix(80)) + ".m4a")
    }

    static var isAvailable: Bool {
        var description = isolationDescription
        return AudioComponentFindNext(nil, &description) != nil
    }

    private static var isolationDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    /// Writes the enhanced track to `destination` (mono AAC, starting at
    /// the track's first sample). Returns that start, in recording time.
    @discardableResult
    static func enhance(
        asset: AVAsset,
        track: AVAssetTrack,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Double {
        guard isAvailable else { throw Failure.unavailable }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let work = fileManager.temporaryDirectory.appendingPathComponent("shotnix-voice-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        // 1. The raw voice as 48 kHz mono float PCM.
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false) else {
            throw Failure.unavailable
        }
        let rawURL = work.appendingPathComponent("raw.caf")
        let raw = try AVAudioFile(forWriting: rawURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var firstTime: Double?
        let duration = max(try await asset.load(.duration).seconds, 0.1)
        try await VideoAudioReader.read(asset: asset, tracks: [track], format: format) { buffer, start in
            if firstTime == nil { firstTime = start.seconds }
            try raw.write(from: buffer)
            progress(min(start.seconds / duration, 1) * 0.15)
        }
        let rawLength = raw.length
        guard rawLength > 0 else { throw Failure.failed("The voice track is empty.") }
        let input = try AVAudioFile(forReading: rawURL, commonFormat: .pcmFormatFloat32, interleaved: false)

        // 2. Isolation → rumble filter → compressor, rendered offline.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let isolation = AVAudioUnitEffect(audioComponentDescription: isolationDescription)
        let equalizer = AVAudioUnitEQ(numberOfBands: 2)
        let compressor = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        ))
        engine.attach(player)
        engine.attach(isolation)
        engine.attach(equalizer)
        engine.attach(compressor)

        let isolationUnit = isolation.audioUnit
        AudioUnitSetParameter(isolationUnit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0)
        if #available(macOS 15.0, *) {
            AudioUnitSetParameter(isolationUnit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0, AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice), 0)
        }

        let rumble = equalizer.bands[0]
        rumble.filterType = .highPass
        rumble.frequency = 80
        rumble.bypass = false
        let presence = equalizer.bands[1]
        presence.filterType = .parametric
        presence.frequency = 3_000
        presence.bandwidth = 1.2
        presence.gain = 1.5
        presence.bypass = false

        let compressorUnit = compressor.audioUnit
        AudioUnitSetParameter(compressorUnit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -24, 0)
        AudioUnitSetParameter(compressorUnit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 8, 0)
        AudioUnitSetParameter(compressorUnit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.004, 0)
        AudioUnitSetParameter(compressorUnit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.15, 0)
        AudioUnitSetParameter(compressorUnit, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 4, 0)

        engine.connect(player, to: isolation, format: format)
        engine.connect(isolation, to: equalizer, format: format)
        engine.connect(equalizer, to: compressor, format: format)
        engine.connect(compressor, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        try engine.start()
        // The isolation model looks ahead (~0.1 s): drop that much from the
        // start of the output so the voice stays in sync with the picture.
        let latency = isolation.auAudioUnit.latency + equalizer.auAudioUnit.latency + compressor.auAudioUnit.latency
        var framesToSkip = AVAudioFramePosition((latency * format.sampleRate).rounded())
        player.scheduleFile(input, at: nil, completionHandler: nil)
        player.play()

        let outputURL = work.appendingPathComponent("voice.m4a")
        let output = try AVAudioFile(forWriting: outputURL, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw Failure.unavailable
        }
        // Render the latency plus a short tail so the last word isn't cut.
        let total = rawLength + framesToSkip + AVAudioFramePosition(format.sampleRate * 0.1)
        while engine.manualRenderingSampleTime < total {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(Int64(buffer.frameCapacity), total - engine.manualRenderingSampleTime))
            let status = try engine.renderOffline(frames, to: buffer)
            switch status {
            case .success:
                let rendered = AVAudioFramePosition(buffer.frameLength)
                if framesToSkip >= rendered {
                    framesToSkip -= rendered
                } else if framesToSkip > 0 {
                    let keep = AVAudioFrameCount(rendered - framesToSkip)
                    guard let tail = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: keep),
                          let from = buffer.floatChannelData, let to = tail.floatChannelData else { throw Failure.unavailable }
                    tail.frameLength = keep
                    for channel in 0..<Int(buffer.format.channelCount) {
                        to[channel].update(from: from[channel] + Int(framesToSkip), count: Int(keep))
                    }
                    framesToSkip = 0
                    try output.write(from: tail)
                } else {
                    try output.write(from: buffer)
                }
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw Failure.failed("Voice enhancement failed while processing.")
            @unknown default:
                throw Failure.failed("Voice enhancement failed while processing.")
            }
            progress(0.15 + 0.85 * Double(engine.manualRenderingSampleTime) / Double(max(total, 1)))
        }
        player.stop()
        engine.stop()

        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: outputURL, to: destination)
        progress(1)
        return firstTime ?? 0
    }
}

// MARK: - Loudness

/// Integrated loudness (ITU-R BS.1770 / EBU R128) of interleaved 16-bit
/// PCM, plus the sample peak — enough to set one gain for the whole mix.
final class VideoLoudnessMeter {
    private let channels: Int
    private let sampleRate: Double
    private var filters: [KWeighting]
    private var blockSums: [Double] = []
    private var current: [Double]
    private var currentCount = 0
    private let hop: Int
    private var hopSums: [[Double]] = []
    private(set) var peak: Double = 0

    init(channels: Int, sampleRate: Double) {
        self.channels = max(channels, 1)
        self.sampleRate = sampleRate
        filters = (0..<max(channels, 1)).map { _ in KWeighting(sampleRate: sampleRate) }
        current = Array(repeating: 0, count: max(channels, 1))
        hop = max(Int(sampleRate * 0.1), 1)
    }

    /// Feeds interleaved samples scaled to −1…1.
    func add(interleaved samples: UnsafeBufferPointer<Float>) {
        let frames = samples.count / channels
        for frame in 0..<frames {
            for channel in 0..<channels {
                let value = Double(samples[frame * channels + channel])
                peak = max(peak, abs(value))
                let weighted = filters[channel].process(value)
                current[channel] += weighted * weighted
            }
            currentCount += 1
            if currentCount == hop {
                hopSums.append(current.map { $0 / Double(hop) })
                current = Array(repeating: 0, count: channels)
                currentCount = 0
            }
        }
    }

    /// LUFS, or nil for silence.
    var integratedLoudness: Double? {
        // 400 ms blocks = 4 hops, 75% overlap.
        guard hopSums.count >= 4 else { return nil }
        var blocks: [Double] = []
        for index in 0...(hopSums.count - 4) {
            var power = 0.0
            for channel in 0..<channels {
                var sum = 0.0
                for hopIndex in index..<(index + 4) { sum += hopSums[hopIndex][channel] }
                power += sum / 4
            }
            blocks.append(power)
        }
        func loudness(_ power: Double) -> Double { -0.691 + 10 * log10(max(power, 1e-12)) }
        let absolute = blocks.filter { loudness($0) > -70 }
        guard !absolute.isEmpty else { return nil }
        let relativeGate = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { loudness($0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }

    /// Gain (linear) that brings the mix to `target` LUFS without letting
    /// peaks pass `ceiling` dBFS; clamped to ±20 dB.
    func gain(target: Double = -16, ceiling: Double = -1) -> Double {
        guard let loudness = integratedLoudness else { return 1 }
        var decibels = min(max(target - loudness, -20), 20)
        if peak > 0 {
            let peakRoom = ceiling - 20 * log10(peak)
            decibels = min(decibels, peakRoom)
        }
        return pow(10, decibels / 20)
    }

    /// The BS.1770 "K" pre-filter: a high shelf plus a low cut.
    private struct KWeighting {
        var shelf: Biquad
        var highPass: Biquad

        init(sampleRate: Double) {
            // Coefficients derived for any rate (Brecht De Man's formulas).
            let f0 = 1681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196
            let k = tan(.pi * f0 / sampleRate)
            let vh = pow(10, gain / 20), vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            shelf = Biquad(
                b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0
            )
            let f1 = 38.13547087602444, q1 = 0.5003270373238773
            let k1 = tan(.pi * f1 / sampleRate)
            let d = 1 + k1 / q1 + k1 * k1
            highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k1 * k1 - 1) / d, a2: (1 - k1 / q1 + k1 * k1) / d)
        }

        mutating func process(_ x: Double) -> Double {
            highPass.process(shelf.process(x))
        }
    }

    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0

        init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }
}

/// Applies one gain to 16-bit interleaved PCM sample buffers (after the
/// meter chose it); peaks were accounted for, so this never clips.
enum VideoAudioGain {
    static func apply(_ gain: Double, to sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard abs(gain - 1) > 0.001,
              let block = CMSampleBufferGetDataBuffer(sample),
              let format = CMSampleBufferGetFormatDescription(sample) else { return sample }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let copied = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base) == noErr
        }
        guard copied else { return sample }
        data.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in samples.indices {
                let scaled = Double(samples[index]) * gain
                samples[index] = Int16(max(min(scaled.rounded(), Double(Int16.max)), Double(Int16.min)))
            }
        }
        var newBlock: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &newBlock) == noErr,
              let newBlock else { return sample }
        let replaced = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: newBlock, offsetIntoDestination: 0, dataLength: length)
        }
        guard replaced == noErr else { return sample }
        var result: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil,
            dataBuffer: newBlock,
            formatDescription: format,
            sampleCount: CMSampleBufferGetNumSamples(sample),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
            packetDescriptions: nil,
            sampleBufferOut: &result
        )
        return status == noErr ? result : sample
    }
}
