import AVFoundation
import XCTest
@testable import ShotnixCore

@MainActor
final class VideoAudioTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory {
            for name in ["rec.mp4", "noisy.mov"] { VideoDemoDraftStore.delete(for: directory.appendingPathComponent(name)) }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Helpers

    /// Interleaved stereo float samples of a sine.
    private func sine(frequency: Double, amplitude: Double, seconds: Double, rate: Double = 48_000) -> [Float] {
        let frames = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = Float(sin(2 * .pi * frequency * Double(frame) / rate) * amplitude)
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        return samples
    }

    /// Loudness of a file's (mixed) sound.
    private func measure(_ url: URL) async throws -> (lufs: Double?, peak: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return (nil, 0) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        let meter = VideoLoudnessMeter(channels: 2, sampleRate: 48_000)
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            let count = length / 4
            pointer.withMemoryRebound(to: Float.self, capacity: count) { meter.add(interleaved: UnsafeBufferPointer(start: $0, count: count)) }
        }
        return (meter.integratedLoudness, meter.peak)
    }

    private func makeModel(seconds: Double = 4) async throws -> VideoEditorModel {
        let url = directory.appendingPathComponent("rec.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 640, height: 400), seconds: seconds, fps: 30, audioSeconds: seconds)
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        XCTAssertTrue(model.isReady)
        return model
    }

    // MARK: Tests

    func testLoudnessMeterMatchesTheReference() {
        // EBU Tech 3341 case 1: stereo 1 kHz sine at −23 dBFS reads −23 LUFS.
        let meter = VideoLoudnessMeter(channels: 2, sampleRate: 48_000)
        let samples = sine(frequency: 1000, amplitude: pow(10, -23 / 20), seconds: 10)
        samples.withUnsafeBufferPointer { meter.add(interleaved: $0) }
        XCTAssertEqual(meter.integratedLoudness ?? 0, -23, accuracy: 0.2)
        // Gain to −16 is +7 dB, and the peak (−23 dBFS) leaves room.
        XCTAssertEqual(20 * log10(meter.gain()), 7, accuracy: 0.25)

        // A loud, peaky signal: the peak ceiling limits the boost.
        let peaky = VideoLoudnessMeter(channels: 2, sampleRate: 48_000)
        var quiet = sine(frequency: 1000, amplitude: 0.02, seconds: 5)
        for index in stride(from: 0, to: quiet.count, by: 48_000) { quiet[index] = 0.9 }
        quiet.withUnsafeBufferPointer { peaky.add(interleaved: $0) }
        let boosted = peaky.peak * peaky.gain()
        XCTAssertLessThanOrEqual(20 * log10(boosted), -0.99, "never pushes peaks past −1 dBFS")
        XCTAssertNil(VideoLoudnessMeter(channels: 2, sampleRate: 48_000).integratedLoudness, "silence has no loudness")
    }

    func testTrackKinds() {
        XCTAssertEqual(VideoAudioKind.resolve(recorded: [.microphone, .system], channelCounts: [1, 2]), [.microphone, .system])
        XCTAssertEqual(VideoAudioKind.resolve(recorded: nil, channelCounts: [1, 2]), [.microphone, .system])
        XCTAssertEqual(VideoAudioKind.resolve(recorded: nil, channelCounts: [2, 1]), [.system, .microphone])
        XCTAssertEqual(VideoAudioKind.resolve(recorded: nil, channelCounts: [2]), [.mixed])
        XCTAssertEqual(VideoAudioKind.resolve(recorded: [.microphone], channelCounts: [1, 2]), [.microphone, .system], "stale metadata falls back to channels")
        XCTAssertEqual(VideoAudioKind.voiceTrackIndex(in: [.system, .microphone]), 1)
        XCTAssertEqual(VideoAudioKind.voiceTrackIndex(in: [.mixed]), 0)
        XCTAssertNil(VideoAudioKind.voiceTrackIndex(in: [.system]))

        var audio = VideoAudioSettings()
        audio.voiceVolume = 0.5
        audio.systemVolume = 0.25
        audio.volume = 0.8
        XCTAssertEqual(audio.effectiveVolume(for: .microphone), 0.4, accuracy: 0.001)
        XCTAssertEqual(audio.effectiveVolume(for: .system), 0.2, accuracy: 0.001)
        XCTAssertEqual(audio.effectiveVolume(for: .mixed), 0.8, accuracy: 0.001)
        audio.muted = true
        XCTAssertTrue(audio.isSilent(kinds: [.microphone, .system]))

        // Old drafts without the new keys still decode.
        let old = try? JSONDecoder().decode(VideoAudioSettings.self, from: Data(#"{"volume":0.5,"muted":false}"#.utf8))
        XCTAssertEqual(old?.volume, 0.5)
        XCTAssertEqual(old?.normalizeLoudness, true)
        XCTAssertEqual(old?.enhanceVoice, false)
    }

    func testVolumeAndMuteNeverRebuildThePlayer() async throws {
        let model = try await makeModel()
        let rebuilds = model.playback.itemRebuilds
        let item = model.playback.player.currentItem
        model.setStyle(coalesce: "volume") { $0.audio.volume = 0.3 }
        model.setStyle { $0.audio.muted = true }
        model.setStyle { $0.audio.muted = false }
        if let id = model.project.timelineClips.first?.id {
            model.setClipMuted(id, true)
            model.setClipFade(id, fadeIn: 0.5)
        }
        model.setStyle(coalesce: "padding") { $0.padding = 0.12 }
        XCTAssertEqual(model.playback.itemRebuilds, rebuilds, "sound changes swap the mix only")
        XCTAssertTrue(model.playback.player.currentItem === item)
        XCTAssertNotNil(item?.audioMix)

        // Cutting IS structural.
        model.seek(to: 2)
        model.splitAtPlayhead()
        XCTAssertEqual(model.playback.itemRebuilds, rebuilds + 1)
    }

    func testMixCarriesPerTrackVolumes() throws {
        // Build a mix directly for a two-kind edit and read the volumes back.
        let composition = AVMutableComposition()
        let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let mic = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let system = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let segment = VideoDemoTimelineSegment(clip: VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 4), timelineStart: 0)
        let edit = VideoEditComposition(
            composition: composition, videoTrack: video, audioTracks: [mic, system], audioKinds: [.microphone, .system],
            audioMix: nil, placements: [VideoCompositionBuilder.Placement(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 600), segment: segment)],
            duration: CMTime(seconds: 4, preferredTimescale: 600), sourceSize: CGSize(width: 640, height: 400), orientation: .identity
        )
        var audio = VideoAudioSettings()
        audio.voiceVolume = 1
        audio.systemVolume = 0.3
        let mix = try XCTUnwrap(VideoCompositionBuilder.audioMix(for: edit, segments: [segment], audio: audio))
        func volume(_ index: Int) -> Float {
            var start: Float = -1, end: Float = -1
            var range = CMTimeRange()
            _ = mix.inputParameters[index].getVolumeRamp(for: CMTime(seconds: 1, preferredTimescale: 600), startVolume: &start, endVolume: &end, timeRange: &range)
            return start
        }
        XCTAssertEqual(volume(0), 1, accuracy: 0.001)
        XCTAssertEqual(volume(1), 0.3, accuracy: 0.001)
    }

    func testExportLoudnessAndMutedExport() async throws {
        let model = try await makeModel()
        var settings = VideoExportSettings()
        settings.resolution = .p720
        settings.fps = 30
        settings.endCard = false

        // The test tone is quiet; export evens it out to about −16 LUFS.
        let even = directory.appendingPathComponent("even.mp4")
        try await VideoDemoExporter.export(project: model.project, recording: model.recording, destinationURL: even, settings: settings)
        let measured = try await measure(even)
        print("LOUDNESS: \(measured.lufs ?? -99) LUFS, peak \(20 * log10(max(measured.peak, 1e-9))) dBFS")
        XCTAssertEqual(measured.lufs ?? 0, -16, accuracy: 1.0)
        XCTAssertLessThanOrEqual(measured.peak, 1.0)

        // Muted: no sound track at all.
        var muted = model.project
        muted.audio.muted = true
        let silent = directory.appendingPathComponent("silent.mp4")
        try await VideoDemoExporter.export(project: muted, recording: model.recording, destinationURL: silent, settings: settings)
        let tracks = try await AVURLAsset(url: silent).loadTracks(withMediaType: .audio)
        XCTAssertTrue(tracks.isEmpty)
    }

    func testVoiceEnhancementRemovesNoise() async throws {
        try XCTSkipUnless(VideoVoiceEnhancer.isAvailable, "Voice isolation not available on this Mac")
        // Speech after a second of silence, with steady hiss throughout.
        let speech = directory.appendingPathComponent("speech.caf")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", speech.path, "--data-format=LEF32@48000", "[[slnc 1500]] Welcome to the demo. Let me show you how this works."]
        try say.run()
        say.waitUntilExit()
        let speechFile = try AVAudioFile(forReading: speech)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(speechFile.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: speechFile.processingFormat, frameCapacity: frames)!
        try speechFile.read(into: buffer)
        let noisy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        noisy.frameLength = frames
        var generator = SystemRandomNumberGenerator()
        for index in 0..<Int(frames) {
            let noise = Float.random(in: -0.03...0.03, using: &generator)
            noisy.floatChannelData![0][index] = buffer.floatChannelData![0][index] * 0.8 + noise
        }
        let noisyURL = directory.appendingPathComponent("noisy.caf")
        let noisyFile = try AVAudioFile(forWriting: noisyURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try noisyFile.write(from: noisy)

        let asset = AVURLAsset(url: noisyURL)
        let track = try await asset.loadTracks(withMediaType: .audio).first!
        let output = directory.appendingPathComponent("voice.m4a")
        let started = CFAbsoluteTimeGetCurrent()
        try await VideoVoiceEnhancer.enhance(asset: asset, track: track, to: output) { _ in }
        print(String(format: "VOICE: enhanced %.1fs of audio in %.2fs", Double(frames) / 48_000, CFAbsoluteTimeGetCurrent() - started))

        func rms(_ url: URL, from: Double, to: Double) throws -> Double {
            let file = try AVAudioFile(forReading: url)
            let rate = file.processingFormat.sampleRate
            file.framePosition = AVAudioFramePosition(from * rate)
            let count = AVAudioFrameCount((to - from) * rate)
            let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
            try file.read(into: chunk, frameCount: count)
            var sum = 0.0
            for i in 0..<Int(chunk.frameLength) { let v = Double(chunk.floatChannelData![0][i]); sum += v * v }
            return (sum / Double(max(chunk.frameLength, 1))).squareRoot()
        }
        let noiseBefore = try rms(noisyURL, from: 0.3, to: 1.2)
        let noiseAfter = try rms(output, from: 0.3, to: 1.2)
        let speechAfter = try rms(output, from: 2.0, to: 3.5)
        print(String(format: "VOICE: noise %.1f dB → %.1f dB, speech %.1f dB", 20 * log10(noiseBefore), 20 * log10(max(noiseAfter, 1e-9)), 20 * log10(max(speechAfter, 1e-9))))
        // The voice must stay in sync with the picture: find where the
        // first word starts in each file (10 ms windows).
        func onset(_ url: URL) throws -> Double {
            let file = try AVAudioFile(forReading: url)
            let rate = file.processingFormat.sampleRate
            let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: chunk)
            let window = Int(rate * 0.01)
            var index = 0
            while index + window < Int(chunk.frameLength) {
                var sum = 0.0
                for i in index..<(index + window) { let v = Double(chunk.floatChannelData![0][i]); sum += v * v }
                if (sum / Double(window)).squareRoot() > 0.08 { return Double(index) / rate }
                index += window
            }
            return -1
        }
        let original = try onset(speech)
        let enhanced = try onset(output)
        print(String(format: "VOICE: first word at %.3fs original, %.3fs enhanced", original, enhanced))
        XCTAssertEqual(enhanced, original, accuracy: 0.025, "no audible delay (lip sync)")
        XCTAssertLessThan(20 * log10(max(noiseAfter, 1e-9)), 20 * log10(noiseBefore) - 12, "hiss drops by more than 12 dB")
        XCTAssertGreaterThan(speechAfter, noiseAfter * 8, "speech stays well above the floor")
    }
}
