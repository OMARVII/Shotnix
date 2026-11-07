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
    /// A cleaned-up voice's own file, kept open: a track can't be read once
    /// its asset is gone.
    var file: AVAsset? = nil

    /// The recording's tracks, with the voice replaced by its enhanced
    /// version (in `enhancedVoice`'s tone; nil: Enhance voice is off) when
    /// that's already processed.
    static func resolved(from source: VideoSourceTracks, kinds: [VideoAudioKind], enhancedVoice: VideoVoiceTone?) async -> [VideoAudioSource] {
        var sources = self.sources(from: source, kinds: kinds)
        guard let tone = enhancedVoice,
              let index = VideoAudioKind.voiceTrackIndex(in: kinds),
              sources.indices.contains(index) else { return sources }
        let url = VideoVoiceEnhancer.cacheURL(for: source.asset.url, trackIndex: index, tone: tone)
        guard FileManager.default.fileExists(atPath: url.path) else { return sources }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let range = try? await track.load(.timeRange) else { return sources }
        let offset = source.audioRanges.indices.contains(index) ? source.audioRanges[index].start.seconds : 0
        sources[index] = VideoAudioSource(track: track, available: range, kind: sources[index].kind, offset: offset, identity: url.path, file: asset)
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

/// How Enhance voice shapes the voice once the noise is gone: a low cut
/// under rumble and boom, and a lift (or dip) around 3 kHz that brings the
/// voice forward. Stepped (5 Hz, 0.5 dB) so a setting is easy to repeat on
/// the next recording; each tone is cached on its own.
struct VideoVoiceTone: Hashable, Sendable {
    static let lowCutRange: ClosedRange<Double> = 40...200
    static let presenceRange: ClosedRange<Double> = -6...6
    /// What Enhance voice has always done.
    static let standard = VideoVoiceTone(lowCut: 80, presence: 1.5)

    /// Hz.
    var lowCut: Double
    /// dB at 3 kHz.
    var presence: Double

    /// In range and on the steps.
    var stepped: VideoVoiceTone {
        VideoVoiceTone(
            lowCut: (min(max(lowCut, Self.lowCutRange.lowerBound), Self.lowCutRange.upperBound) / 5).rounded() * 5,
            presence: (min(max(presence, Self.presenceRange.lowerBound), Self.presenceRange.upperBound) * 2).rounded() / 2
        )
    }

    var isStandard: Bool { stepped == Self.standard }

    /// Names its cached file: "lc120p30" is 120 Hz and +3 dB.
    var cacheTag: String {
        let tone = stepped
        return "lc\(Int(tone.lowCut))p\(Int((tone.presence * 10).rounded()))"
    }
}

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
            case .unavailable: return L("Voice enhancement isn't available on this Mac. Turn off Enhance voice to keep the original sound.")
            case .failed(let message): return message
            }
        }
    }

    /// Where the enhanced version of `track` in `recording` is cached: the
    /// standard tone under the name it always had, other tones beside it.
    static func cacheURL(for recording: URL, trackIndex: Int, tone: VideoVoiceTone = .standard) -> URL {
        let name = cacheName(for: recording, trackIndex: trackIndex)
        return folder.appendingPathComponent(tone.isStandard ? name + ".m4a" : "\(name)-\(tone.cacheTag).m4a")
    }

    /// A cleaned-up version of this voice that's already made, to listen to
    /// (transcription): in `tone`, else in the standard one.
    static func readyURL(for recording: URL, trackIndex: Int, preferring tone: VideoVoiceTone) -> URL? {
        [tone, .standard].map { cacheURL(for: recording, trackIndex: trackIndex, tone: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The voice with only the noise taken out (lossless). Other tones start
    /// from it, so changing the tone doesn't run voice isolation again.
    static func isolatedURL(for recording: URL, trackIndex: Int) -> URL {
        folder.appendingPathComponent(cacheName(for: recording, trackIndex: trackIndex) + "-isolated.caf")
    }

    /// What the names of every cached file of this voice start with.
    static func cacheName(for recording: URL, trackIndex: Int) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: recording.path)
        let stamp = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = Data("\(recording.standardizedFileURL.path)|\(trackIndex)|\(Int(stamp))|v\(version)".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return String(key.suffix(80))
    }

    private static var folder: URL {
        VideoStorageLocation.root
            .appendingPathComponent("Shotnix", isDirectory: true)
            .appendingPathComponent("VideoAudio", isDirectory: true)
    }

    /// Removes this voice's other tones (every change makes a file), but
    /// never the standard one or the isolated voice.
    static func removeTones(of recording: URL, trackIndex: Int, keeping: Set<VideoVoiceTone>) {
        let prefix = cacheName(for: recording, trackIndex: trackIndex) + "-lc"
        let kept = Set(keeping.map { cacheURL(for: recording, trackIndex: trackIndex, tone: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) && !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
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
    /// the track's first sample). Given `isolated`, a tone other than the
    /// standard one starts from the isolated voice there (made first when
    /// it's missing). Returns where the track starts, in recording time.
    @discardableResult
    static func enhance(
        asset: AVAsset,
        track: AVAssetTrack,
        to destination: URL,
        tone: VideoVoiceTone = .standard,
        isolated: URL? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Double {
        guard isAvailable else { throw Failure.unavailable }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let work = fileManager.temporaryDirectory.appendingPathComponent("shotnix-voice-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false) else {
            throw Failure.unavailable
        }

        let outputURL = work.appendingPathComponent("voice.m4a")
        let start: Double
        if let isolated, !tone.isStandard {
            // Isolation (the slow part) once; each tone after that is quick.
            var done = 0.0
            if !fileManager.fileExists(atPath: isolated.path) {
                let raw = try await readRaw(asset: asset, track: track, format: format, into: work) { progress($0 * 0.15) }
                let isolatedURL = work.appendingPathComponent("isolated.caf")
                try render(raw.file, through: [isolation()], to: losslessFile(at: isolatedURL), tail: 0.1, format: format) { progress(0.15 + 0.75 * $0) }
                try? fileManager.removeItem(at: isolated)
                try fileManager.moveItem(at: isolatedURL, to: isolated)
                done = 0.9
            }
            let input = try AVAudioFile(forReading: isolated, commonFormat: .pcmFormatFloat32, interleaved: false)
            try render(input, through: [equalizer(tone), compressor()], to: voiceFile(at: outputURL), tail: 0, format: format) { progress(done + (1 - done) * $0) }
            start = (try? await track.load(.timeRange))?.start.seconds ?? 0
        } else {
            // 1. The raw voice; 2. isolation → rumble filter → compressor.
            let raw = try await readRaw(asset: asset, track: track, format: format, into: work) { progress($0 * 0.15) }
            try render(raw.file, through: [isolation(), equalizer(tone), compressor()], to: voiceFile(at: outputURL), tail: 0.1, format: format) { progress(0.15 + 0.85 * $0) }
            start = raw.start
        }

        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: outputURL, to: destination)
        progress(1)
        return start
    }

    /// The raw voice as 48 kHz mono float PCM (in `folder`), and the time of
    /// its first sample in the recording.
    private static func readRaw(
        asset: AVAsset,
        track: AVAssetTrack,
        format: AVAudioFormat,
        into folder: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (file: AVAudioFile, start: Double) {
        let rawURL = folder.appendingPathComponent("raw.caf")
        var firstTime: Double?
        do {
            let raw = try AVAudioFile(forWriting: rawURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let duration = max(try await asset.load(.duration).seconds, 0.1)
            try await VideoAudioReader.read(asset: asset, tracks: [track], format: format) { buffer, start in
                if firstTime == nil { firstTime = start.seconds }
                try raw.write(from: buffer)
                progress(min(start.seconds / duration, 1))
            }
            guard raw.length > 0 else { throw Failure.failed(L("The voice track is empty, so there's nothing to clean up. Turn off Enhance voice to keep the original sound.")) }
        }
        return (try AVAudioFile(forReading: rawURL, commonFormat: .pcmFormatFloat32, interleaved: false), firstTime ?? 0)
    }

    /// Plays `input` through `units` offline into `output`. The units' delay
    /// (the isolation model looks ahead ~0.1 s) is dropped from the start so
    /// the voice stays in sync with the picture, and `tail` seconds past the
    /// end are kept so the last word isn't cut.
    private static func render(
        _ input: AVAudioFile,
        through units: [AVAudioUnit],
        to output: AVAudioFile,
        tail: Double,
        format: AVAudioFormat,
        progress: (Double) -> Void
    ) throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        var previous: AVAudioNode = player
        for unit in units {
            engine.attach(unit)
            engine.connect(previous, to: unit, format: format)
            previous = unit
        }
        engine.connect(previous, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        try engine.start()
        let latency = units.reduce(0) { $0 + $1.auAudioUnit.latency }
        var framesToSkip = AVAudioFramePosition((latency * format.sampleRate).rounded())
        player.scheduleFile(input, at: nil, completionHandler: nil)
        player.play()

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw Failure.unavailable
        }
        let total = input.length + framesToSkip + AVAudioFramePosition(format.sampleRate * tail)
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
                throw Failure.failed(L("Voice enhancement stopped partway. Turn Enhance voice off and on again to retry."))
            @unknown default:
                throw Failure.failed(L("Voice enhancement stopped partway. Turn Enhance voice off and on again to retry."))
            }
            progress(Double(engine.manualRenderingSampleTime) / Double(max(total, 1)))
        }
        player.stop()
        engine.stop()
    }

    /// Apple's voice isolation, fully on.
    private static func isolation() -> AVAudioUnitEffect {
        let isolation = AVAudioUnitEffect(audioComponentDescription: isolationDescription)
        let unit = isolation.audioUnit
        AudioUnitSetParameter(unit, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0)
        if #available(macOS 15.0, *) {
            AudioUnitSetParameter(unit, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0, AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice), 0)
        }
        return isolation
    }

    /// The low cut and the presence band.
    private static func equalizer(_ tone: VideoVoiceTone) -> AVAudioUnitEQ {
        let tone = tone.stepped
        let equalizer = AVAudioUnitEQ(numberOfBands: 2)
        let rumble = equalizer.bands[0]
        rumble.filterType = .highPass
        rumble.frequency = Float(tone.lowCut)
        rumble.bypass = false
        let presence = equalizer.bands[1]
        presence.filterType = .parametric
        presence.frequency = 3_000
        presence.bandwidth = 1.2
        presence.gain = Float(tone.presence)
        presence.bypass = false
        return equalizer
    }

    /// Gentle compression, so quiet and loud words sit closer together.
    private static func compressor() -> AVAudioUnitEffect {
        let compressor = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        ))
        let unit = compressor.audioUnit
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -24, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 8, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.004, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.15, 0)
        AudioUnitSetParameter(unit, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 4, 0)
        return compressor
    }

    /// The finished voice: mono AAC.
    private static func voiceFile(at url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// The isolated voice: Apple Lossless, so the tone made from it is as
    /// clean as one made in a single pass.
    private static func losslessFile(at url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
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

    /// Gain (linear) that brings the mix to `target` LUFS, clamped to
    /// ±20 dB. The export's limiter holds peaks at `ceiling` dBFS, so one
    /// loud moment (a click, a cough) no longer stops a quiet recording
    /// short of the target: the gain may take the loudest peak up to
    /// `limiting` dB past the ceiling, and stops there so the limiter is
    /// never left squashing much.
    func gain(target: Double = -16, ceiling: Double = -1, limiting: Double = 12) -> Double {
        guard let loudness = integratedLoudness else { return 1 }
        var decibels = min(max(target - loudness, -20), 20)
        if peak > 0 {
            let peakRoom = ceiling - 20 * log10(peak) + limiting
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
