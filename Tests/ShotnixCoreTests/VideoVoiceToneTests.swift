import Accelerate
import AVFoundation
import XCTest
@testable import ShotnixCore

/// Enhance voice's tone: a low cut and a presence lift set per video.
/// Each tone is its own cached file, made from the voice isolated once, in
/// sync with the picture; the standard tone keeps the file it always had.
@MainActor
final class VideoVoiceToneTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-tone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory {
            VideoDemoDraftStore.delete(for: directory.appendingPathComponent("rec.mp4"))
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private typealias T = VideoEditorTestModel

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Settings and names

    func testTonesKeepToTheirStepsAndTheStandardOneKeepsItsFile() throws {
        XCTAssertEqual(VideoVoiceTone(lowCut: 83, presence: 1.7).stepped, VideoVoiceTone(lowCut: 85, presence: 1.5))
        XCTAssertEqual(VideoVoiceTone(lowCut: 10, presence: 20).stepped, VideoVoiceTone(lowCut: 40, presence: 6), "kept in range")
        XCTAssertTrue(VideoVoiceTone(lowCut: 81, presence: 1.6).isStandard)
        XCTAssertEqual(VideoVoiceTone(lowCut: 120, presence: 3).cacheTag, "lc120p30")
        XCTAssertEqual(VideoVoiceTone(lowCut: 80, presence: -2).cacheTag, "lc80p-20")

        let recording = directory.appendingPathComponent("lesson.mov")
        try Data("video".utf8).write(to: recording)
        // The name every cleaned-up voice had before tones existed.
        let stamp = Int(((try FileManager.default.attributesOfItem(atPath: recording.path))[.modificationDate] as! Date).timeIntervalSince1970)
        let key = Data("\(recording.standardizedFileURL.path)|1|\(stamp)|v1".utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
        let standard = VideoVoiceEnhancer.cacheURL(for: recording, trackIndex: 1)
        XCTAssertEqual(standard.lastPathComponent, String(key.suffix(80)) + ".m4a", "voices made before tones existed still play")
        XCTAssertEqual(VideoVoiceEnhancer.cacheURL(for: recording, trackIndex: 1, tone: VideoVoiceTone(lowCut: 79, presence: 1.4)), standard)
        let warm = VideoVoiceEnhancer.cacheURL(for: recording, trackIndex: 1, tone: VideoVoiceTone(lowCut: 120, presence: 3))
        XCTAssertEqual(warm.deletingLastPathComponent(), standard.deletingLastPathComponent())
        XCTAssertEqual(warm.lastPathComponent, String(key.suffix(80)) + "-lc120p30.m4a")
        XCTAssertEqual(VideoVoiceEnhancer.isolatedURL(for: recording, trackIndex: 1).lastPathComponent, String(key.suffix(80)) + "-isolated.caf")
    }

    func testOldDraftsPlayInTheStandardTone() throws {
        let old = try JSONDecoder().decode(VideoAudioSettings.self, from: Data(#"{"volume":1,"enhanceVoice":true}"#.utf8))
        XCTAssertEqual(old.voiceTone, .standard)
        XCTAssertEqual(old.enhancedVoice, .standard)
        var audio = old
        audio.voiceLowCut = 150
        audio.voicePresence = -2
        let again = try JSONDecoder().decode(VideoAudioSettings.self, from: JSONEncoder().encode(audio))
        XCTAssertEqual(again.voiceTone, VideoVoiceTone(lowCut: 150, presence: -2))
        audio.enhanceVoice = false
        XCTAssertNil(audio.enhancedVoice, "off: the voice as recorded")
        XCTAssertEqual(VideoEditorModel.formatHertz(150), "150 Hz")
        XCTAssertEqual(VideoEditorModel.formatDecibels(1.5), "+1.5 dB")
        XCTAssertEqual(VideoEditorModel.formatDecibels(-3), "−3 dB")
        XCTAssertEqual(VideoEditorModel.formatDecibels(0), "0 dB")
    }

    // MARK: The sound

    func testAToneShapesTheVoiceAndStaysInSync() async throws {
        try XCTSkipUnless(VideoVoiceEnhancer.isAvailable, "Voice isolation isn't available on this Mac")
        let (asset, track) = try await speech()
        let standard = directory.appendingPathComponent("standard.m4a")
        try await VideoVoiceEnhancer.enhance(asset: asset, track: track, to: standard) { _ in }
        let isolated = directory.appendingPathComponent("isolated.caf")
        let bright = directory.appendingPathComponent("bright.m4a")
        try await VideoVoiceEnhancer.enhance(asset: asset, track: track, to: bright, tone: VideoVoiceTone(lowCut: 80, presence: 6), isolated: isolated) { _ in }
        XCTAssertTrue(exists(isolated), "the isolated voice is kept for the next tone")
        let thin = directory.appendingPathComponent("thin.m4a")
        try await VideoVoiceEnhancer.enhance(asset: asset, track: track, to: thin, tone: VideoVoiceTone(lowCut: 200, presence: 1.5), isolated: isolated) { _ in }

        // Each band against the middle of the voice (the compressor moves
        // the overall level, not the balance).
        let ranges: [ClosedRange<Double>] = [70...140, 300...800, 2_600...3_400]
        let s = try bands(standard, ranges), b = try bands(bright, ranges), t = try bands(thin, ranges)
        let presenceLift = (b[2] - b[1]) - (s[2] - s[1])
        let lowDrop = (t[0] - t[1]) - (s[0] - s[1])
        print(String(format: "TONE: presence +6 dB lifts 3 kHz by %.1f dB; low cut 200 Hz takes %.1f dB off 70–140 Hz", presenceLift, lowDrop))
        XCTAssertGreaterThan(presenceLift, 2)
        XCTAssertLessThan(lowDrop, -6)

        // In sync with the picture, and as long as the standard voice.
        let start = try onset(standard)
        XCTAssertGreaterThan(start, 0.5)
        XCTAssertEqual(try onset(bright), start, accuracy: 0.021)
        XCTAssertEqual(try onset(thin), start, accuracy: 0.021)
        let length = try AVAudioFile(forReading: standard).length
        XCTAssertEqual(Double(try AVAudioFile(forReading: bright).length), Double(length), accuracy: 2_048)
    }

    func testAnotherToneStartsFromTheIsolatedVoice() async throws {
        try XCTSkipUnless(VideoVoiceEnhancer.isAvailable, "Voice isolation isn't available on this Mac")
        let (asset, track) = try await speech()
        let isolated = directory.appendingPathComponent("isolated.caf")
        let first = directory.appendingPathComponent("first.m4a")
        try await VideoVoiceEnhancer.enhance(asset: asset, track: track, to: first, tone: VideoVoiceTone(lowCut: 120, presence: 3), isolated: isolated) { _ in }
        XCTAssertGreaterThan(try rms(first), 0.01)

        // Swap the isolated voice for silence: a tone made after it must
        // come out silent, so it was made from that file, not by isolating
        // the recording again.
        let length = try AVAudioFile(forReading: isolated).length
        try FileManager.default.removeItem(at: isolated)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!
        silence.frameLength = AVAudioFrameCount(length)
        do {
            let file = try AVAudioFile(forWriting: isolated, settings: [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 16], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: silence)
        }
        let second = directory.appendingPathComponent("second.m4a")
        try await VideoVoiceEnhancer.enhance(asset: asset, track: track, to: second, tone: VideoVoiceTone(lowCut: 100, presence: 4), isolated: isolated) { _ in }
        XCTAssertLessThan(try rms(second), 0.001)
    }

    // MARK: In the editor

    func testChangingTheToneRemakesTheVoiceAndTidiesUp() async throws {
        try XCTSkipUnless(VideoVoiceEnhancer.isAvailable, "Voice isolation isn't available on this Mac")
        var options = T.Options(seconds: 3)
        options.audio = true
        options.audioTracks = [.microphone]
        let model = try await T.make(in: directory, options)
        let index = try XCTUnwrap(model.voiceTrackIndex)
        let recording = model.project.sourceURL
        func voice(_ tone: VideoVoiceTone) -> URL { VideoVoiceEnhancer.cacheURL(for: recording, trackIndex: index, tone: tone) }
        func playing() -> String? { model.playback.audioSources?[index].identity }
        func wait(_ condition: () -> Bool) async {
            for _ in 0..<300 where !condition() { await T.settle(0.05) }
        }
        for tone in [VideoVoiceTone.standard, VideoVoiceTone(lowCut: 80, presence: 3)] { try? FileManager.default.removeItem(at: voice(tone)) }
        try? FileManager.default.removeItem(at: VideoVoiceEnhancer.isolatedURL(for: recording, trackIndex: index))

        model.setStyle { $0.audio.enhanceVoice = true }
        _ = await model.voiceTask?.value
        XCTAssertTrue(exists(voice(.standard)))
        XCTAssertEqual(playing(), voice(.standard).path)

        // A slider: more presence. The preview keeps the standard voice
        // until the new one is made, then plays it.
        let warm = VideoVoiceTone(lowCut: 80, presence: 3)
        model.setStyle(coalesce: "voice-presence") { $0.audio.voicePresence = 3 }
        model.endGesture()
        XCTAssertEqual(playing(), voice(.standard).path)
        await wait { playing() == voice(warm).path && model.voiceTask == nil }
        XCTAssertEqual(playing(), voice(warm).path)
        XCTAssertTrue(exists(VideoVoiceEnhancer.isolatedURL(for: recording, trackIndex: index)))
        XCTAssertNil(model.voiceJob)

        // Another tone: the one before goes, the standard one stays.
        let thin = VideoVoiceTone(lowCut: 150, presence: 3)
        model.setStyle(coalesce: "voice-low-cut") { $0.audio.voiceLowCut = 150 }
        model.endGesture()
        await wait { playing() == voice(thin).path && model.voiceTask == nil }
        XCTAssertEqual(playing(), voice(thin).path)
        XCTAssertFalse(exists(voice(warm)), "only the tone in use is kept (and the standard one)")
        XCTAssertTrue(exists(voice(.standard)))

        // Undo goes back to the tone before (made again, quickly).
        model.undo()
        XCTAssertEqual(model.project.audio.voiceTone, warm)
        await wait { playing() == voice(warm).path && model.voiceTask == nil }
        XCTAssertEqual(playing(), voice(warm).path)

        // Back to the standard tone: nothing to make.
        model.setStyle { $0.audio.voicePresence = VideoVoiceTone.standard.presence }
        await wait { playing() == voice(.standard).path }
        XCTAssertEqual(playing(), voice(.standard).path)
        model.stop()
    }

    // MARK: Helpers

    /// Speech after a moment of silence, with steady hiss throughout: a
    /// man's voice, so there's something under 150 Hz to cut.
    private func speech() async throws -> (AVURLAsset, AVAssetTrack) {
        let spoken = directory.appendingPathComponent("speech.caf")
        var made = false
        for voice in ["Daniel", "Samantha"] where !made {
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-v", voice, "-o", spoken.path, "--data-format=LEF32@48000", "[[slnc 1000]] Welcome to the demo. Let me show you how this works, step by step."]
            try say.run()
            say.waitUntilExit()
            made = say.terminationStatus == 0 && exists(spoken)
        }
        let file = try AVAudioFile(forReading: spoken)
        let frames = AVAudioFrameCount(file.length)
        let clean = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: clean)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let noisy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        noisy.frameLength = frames
        var generator = SystemRandomNumberGenerator()
        for index in 0..<Int(frames) {
            noisy.floatChannelData![0][index] = clean.floatChannelData![0][index] * 0.8 + Float.random(in: -0.02...0.02, using: &generator)
        }
        let url = directory.appendingPathComponent("noisy.caf")
        do {
            let out = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try out.write(from: noisy)
        }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        return (asset, track)
    }

    private func samples(_ url: URL) throws -> (values: [Float], rate: Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
    }

    private func rms(_ url: URL) throws -> Double {
        let values = try samples(url).values
        return Double(vDSP.rootMeanSquare(values))
    }

    /// Where the first word starts (10 ms windows).
    private func onset(_ url: URL) throws -> Double {
        let (values, rate) = try samples(url)
        let window = Int(rate * 0.01)
        var index = 0
        while index + window < values.count {
            if vDSP.rootMeanSquare(values[index..<(index + window)]) > 0.08 { return Double(index) / rate }
            index += window
        }
        return -1
    }

    /// Average power in each band, in dB, over the whole file.
    private func bands(_ url: URL, _ ranges: [ClosedRange<Double>]) throws -> [Double] {
        let (values, rate) = try samples(url)
        let size = 4_096
        let dft = try vDSP.DiscreteFourierTransform(previous: nil, count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        let zeros = [Float](repeating: 0, count: size)
        var power = [Double](repeating: 0, count: size / 2)
        var start = 0
        while start + size <= values.count {
            let chunk = vDSP.multiply(Array(values[start..<(start + size)]), window)
            let (real, imaginary) = dft.transform(real: chunk, imaginary: zeros)
            for bin in 0..<(size / 2) { power[bin] += Double(real[bin] * real[bin] + imaginary[bin] * imaginary[bin]) }
            start += size / 2
        }
        return ranges.map { range in
            let low = Int(range.lowerBound / rate * Double(size)), high = Int(range.upperBound / rate * Double(size))
            return 10 * log10(max(power[low...high].reduce(0, +), 1e-20))
        }
    }
}
