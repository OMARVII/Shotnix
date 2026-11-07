import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import ShotnixCore

/// #35: levels past 100% (up to 300%), heard in the preview and in the
/// export, never crackling.
@MainActor
final class VideoVolumeBoostTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-boost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory {
            for name in ["rec.mp4", "rec.mov"] { VideoDemoDraftStore.delete(for: directory.appendingPathComponent(name)) }
            try? FileManager.default.removeItem(at: directory)
        }
        L10n.use(nil)
    }

    private typealias T = VideoEditorTestModel
    private let ceiling = VideoPeakLimit.ceiling

    // MARK: Helpers

    /// Interleaved stereo float samples of a sine.
    private func sine(frequency: Double = 440, amplitude: Double, seconds: Double) -> [Float] {
        let frames = Int(seconds * 48_000)
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = Float(sin(2 * .pi * frequency * Double(frame) / 48_000) * amplitude)
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        return samples
    }

    /// Runs samples through the export's limiter in uneven chunks.
    private func limited(_ input: [Float], chunks: [Int] = [1_000, 37, 4_096, 513]) -> (samples: [Float], latency: Int) {
        var limiter = VideoLookaheadLimiter(channels: 2, sampleRate: 48_000)
        var output = input
        var offset = 0
        var chunk = 0
        output.withUnsafeMutableBufferPointer { buffer in
            while offset < buffer.count {
                let length = min(chunks[chunk % chunks.count] * 2, buffer.count - offset)
                limiter.process(UnsafeMutableBufferPointer(rebasing: buffer[offset..<(offset + length)]))
                offset += length
                chunk += 1
            }
        }
        return (output, limiter.latency)
    }

    private func peak(_ samples: ArraySlice<Float>) -> Float { samples.reduce(0) { max($0, abs($1)) } }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        (samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(samples.count, 1))).squareRoot()
    }

    /// A float, interleaved, stereo buffer at `start` frames.
    private func buffer(_ samples: [Float], start: Int) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        let length = samples.count * 4
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block), noErr)
        _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: length) }
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: try XCTUnwrap(format), sampleCount: samples.count / 2, presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: 48_000), packetDescriptions: nil, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private func floats(of sample: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
        _ = samples.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
        return samples
    }

    /// Interleaved stereo 48 kHz float sound of `tracks`, mixed by `mix`.
    private func read(_ asset: AVAsset, tracks: [AVAssetTrack], mix: AVAudioMix?) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        output.audioMix = mix
        output.audioTimePitchAlgorithm = .spectral
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() { samples += floats(of: sample) }
        return samples
    }

    private func read(_ url: URL) async throws -> [Float] {
        try await VideoTestSupport.readSound(url)
    }

    private func writeTone(amplitude: Double, frequency: Double, seconds: Double) throws -> URL {
        try VideoTestSupport.writeTone(in: directory, amplitude: amplitude, frequency: frequency, seconds: seconds)
    }

    private func twoTrackProject(_ url: URL, seconds: Double, clips: [VideoDemoTimelineClip]) -> (VideoDemoProject, VideoDemoRecordingMetadata) {
        let metadata = VideoDemoRecordingMetadata(videoURLPath: url.path, createdAt: Date(), duration: seconds, sourceWidth: 320, sourceHeight: 200, fps: 30, nativeCursorVisible: true, cursorSamples: [], clickEvents: [], audioTracks: [.microphone, .system])
        var project = VideoDemoProject.make(sourceURL: url, duration: seconds, sourceSize: CGSize(width: 320, height: 200))
        project.apply(metadata: metadata)
        // A steady tone on the mic would count as talking throughout.
        project.audio.duckSystem = false
        project.timelineClips = clips
        return (project, metadata)
    }

    private var exportSettings: VideoExportSettings {
        var settings = VideoExportSettings()
        settings.resolution = .p720
        settings.fps = 30
        settings.endCard = false
        return settings
    }

    /// Peak and RMS of one stretch of interleaved stereo sound.
    private func stretch(_ samples: [Float], from start: Double, to end: Double) -> (peak: Float, rms: Double) {
        let a = min(Int(start * 48_000) * 2, samples.count), b = min(Int(end * 48_000) * 2, samples.count)
        return (peak(samples[a..<b]), rms(samples[a..<b]))
    }

    // MARK: The limiter

    func testLimiterLeavesSoundUnderTheCeilingExactlyAsItWas() {
        let input = sine(amplitude: 0.85, seconds: 0.5)
        let (output, latency) = limited(input)
        XCTAssertEqual(latency, 95, "2 ms ahead at 48 kHz")
        var changed = 0
        for index in (latency * 2)..<output.count where output[index] != input[index - latency * 2] { changed += 1 }
        XCTAssertEqual(changed, 0, "under the ceiling, every sample comes out as it went in (only later)")
    }

    func testLimiterHoldsALoudSineUnderTheCeilingWithoutFlatteningIt() {
        // Three times as loud as full scale would allow without a limiter.
        let input = sine(amplitude: 2.0, seconds: 1)
        let (output, _) = limited(input)
        let settled = output[(9_600 * 2)...]
        let top = peak(settled)
        XCTAssertLessThanOrEqual(top, ceiling + 0.0001)
        XCTAssertGreaterThan(top, ceiling - 0.03, "turned down to the ceiling, not further")
        // A clean sine peaks at √2 × its RMS; a clipped (flat-topped) one far less.
        XCTAssertGreaterThan(Double(top) / rms(settled), 1.38, "still a sine, not a clipped square")
    }

    func testLimiterTurnsASpikeDownBeforeItArrives() {
        // A steady level, so the gain shows at every frame, with one spike.
        var input = [Float](repeating: 0.1, count: 24_000 * 2)
        let spike = 12_000
        input[spike * 2] = 3
        input[spike * 2 + 1] = 3
        let (output, latency) = limited(input)
        XCTAssertLessThanOrEqual(peak(output[...]), ceiling + 0.0001)
        XCTAssertEqual(output[(spike + latency) * 2], ceiling, accuracy: 0.001, "the spike lands on the ceiling")
        var steepest: Float = 0
        for frame in (spike - 300)..<(spike + 300) {
            let gain = output[(frame + latency) * 2] / input[frame * 2]
            let next = output[(frame + 1 + latency) * 2] / input[(frame + 1) * 2]
            steepest = max(steepest, abs(next - gain))
        }
        XCTAssertLessThan(steepest, 0.01, "the level glides down over the look-ahead, no step")
        XCTAssertEqual(output[(spike - 200 + latency) * 2], 0.1, accuracy: 0.0001, "untouched until the look-ahead sees it")
    }

    func testExportSoundKeepsItsTimingAndEverySample() throws {
        // Silence with two clicks, in buffers of odd sizes.
        var signal = [Float](repeating: 0, count: 3_884 * 2)
        for at in [1_500, 3_000] { signal[at * 2] = 0.5; signal[at * 2 + 1] = 0.5 }
        func run(gain: Double) throws -> (samples: [Float], times: [Int]) {
            var buffers: [CMSampleBuffer] = []
            var start = 0
            for size in [512, 1_024, 300, 2_048] {
                buffers.append(try buffer(Array(signal[(start * 2)..<((start + size) * 2)]), start: start))
                start += size
            }
            var queue = buffers
            let sound = VideoLimitedAudio(gain: gain) { queue.isEmpty ? nil : queue.removeFirst() }
            var samples: [Float] = []
            var times: [Int] = []
            while let sample = sound.next() {
                times.append(Int(CMSampleBufferGetPresentationTimeStamp(sample).convertScale(48_000, method: .default).value))
                XCTAssertEqual(times.last, samples.count / 2, "each buffer starts where the last ended")
                samples += floats(of: sample)
            }
            return (samples, times)
        }
        let plain = try run(gain: 1)
        XCTAssertEqual(plain.samples.count, signal.count, "every sample is kept")
        XCTAssertEqual(plain.times.first, 0)
        XCTAssertEqual(plain.samples, signal, "nothing moves: the look-ahead is taken back out")
        let louder = try run(gain: 1.5)
        XCTAssertEqual(louder.samples[3_000 * 2], 0.75, accuracy: 0.0001)
        let tooLoud = try run(gain: 3)
        XCTAssertEqual(tooLoud.samples[1_500 * 2], ceiling, accuracy: 0.001, "held at the ceiling, in the same place")
    }

    // MARK: Levels

    func testLevelsGoToThreeTimesAndSave() throws {
        let clip = VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 4, voiceVolume: 2.5, systemVolume: 0.4)
        let saved = try JSONDecoder().decode(VideoDemoTimelineClip.self, from: JSONEncoder().encode(clip))
        XCTAssertEqual(saved.voiceVolume, 2.5)
        XCTAssertTrue(saved.isLouder)
        XCTAssertTrue(saved.isQuieter, "the computer sound is still turned down")
        XCTAssertEqual(saved.volume(for: .microphone), 2.5, accuracy: 0.0001)

        let wild = try JSONDecoder().decode(VideoDemoTimelineClip.self, from: Data(#"{"id":"39B84C79-6A09-4B45-BB49-BAA9969B19AB","muted":false,"sourceEnd":4,"sourceStart":0,"speed":1,"fadeIn":0,"fadeOut":0,"voiceVolume":7}"#.utf8))
        XCTAssertEqual(wild.volume(for: .microphone), 3, accuracy: 0.0001, "no more than 300%")

        var audio = VideoAudioSettings()
        audio.voiceVolume = 2
        XCTAssertEqual(audio.effectiveVolume(for: .microphone), 2, accuracy: 0.0001)
        XCTAssertEqual(VideoAudioSettings.combinedLevel(audio.effectiveVolume(for: .microphone), 3), 4, accuracy: 0.0001, "the video's and the clip's levels together stop at +12 dB")
        XCTAssertFalse(VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 1, muted: true, voiceVolume: 2).isLouder, "muted, not louder")
    }

    func testTheMixPlaysLevelsPastFullAndOnlyThePreviewLimitsThem() async throws {
        let model = try await T.make(in: directory, T.Options(audio: true))
        let id = try XCTUnwrap(model.project.timelineClips.first?.id)
        let rebuilds = model.playback.itemRebuilds
        let item = try XCTUnwrap(model.playback.player.currentItem)
        XCTAssertNil(item.audioMix?.inputParameters.first?.audioTapProcessor, "as recorded: nothing extra on the track")

        model.setClipVolume(id, \.volume, 2.5)
        model.endGesture()
        XCTAssertEqual(model.playback.itemRebuilds, rebuilds, "a level only swaps the mix")
        let previewMix = try XCTUnwrap(item.audioMix)
        XCTAssertNotNil(previewMix.inputParameters.first?.audioTapProcessor, "the preview limits the louder track")
        var start: Float = -1, end: Float = -1
        var range = CMTimeRange()
        _ = previewMix.inputParameters[0].getVolumeRamp(for: CMTime(seconds: 2, preferredTimescale: 600), startVolume: &start, endVolume: &end, timeRange: &range)
        XCTAssertEqual(start, 2.5, accuracy: 0.001, "the level line itself goes past 1")

        // The export's own mix has no tap: it limits the whole mix as it writes.
        let edit = try XCTUnwrap(model.playback.edit)
        let exportMix = try XCTUnwrap(VideoCompositionBuilder.audioMix(for: edit, segments: model.segments, audio: model.project.audio))
        XCTAssertNil(exportMix.inputParameters.first?.audioTapProcessor)

        model.setClipVolume(id, \.volume, 1)
        model.endGesture()
        XCTAssertNil(model.playback.player.currentItem?.audioMix?.inputParameters.first?.audioTapProcessor, "back to 100%: no limiter")
    }

    /// The preview's limiter, through the real tap: the louder clip is held
    /// under the ceiling, the clip before it plays exactly as recorded, and
    /// a faster clip (where the tap's clock is rough) is still held.
    func testThePreviewLimiterFollowsTheLevelLine() async throws {
        let tone = try writeTone(amplitude: 0.5, frequency: 440, seconds: 3)
        let asset = AVURLAsset(url: tone)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let source = try XCTUnwrap(audioTracks.first)
        for fast in [false, true] {
            let composition = AVMutableComposition()
            let video = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
            let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            let second = CMTime(value: 600, timescale: 600)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMultiply(second, multiplier: 2)), of: source, at: .zero)
            let louderLength = fast ? CMTime(value: 300, timescale: 600) : second
            if fast { track.scaleTimeRange(CMTimeRange(start: second, duration: second), toDuration: louderLength) }
            let clips = [
                VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 1),
                VideoDemoTimelineClip(sourceStart: 1, sourceEnd: 2, speed: fast ? 2 : 1, volume: 3),
            ]
            let segments = [VideoDemoTimelineSegment(clip: clips[0], timelineStart: 0), VideoDemoTimelineSegment(clip: clips[1], timelineStart: 1)]
            let placements = [
                VideoCompositionBuilder.Placement(start: .zero, duration: second, segment: segments[0]),
                VideoCompositionBuilder.Placement(start: second, duration: louderLength, segment: segments[1]),
            ]
            let total = CMTimeAdd(second, louderLength)
            let edit = VideoEditComposition(
                composition: composition, videoTrack: video, audioTracks: [track], audioKinds: [.mixed],
                audioMix: nil, placements: placements, duration: total,
                sourceSize: CGSize(width: 640, height: 400), orientation: .identity
            )
            let mix = try XCTUnwrap(VideoCompositionBuilder.audioMix(for: edit, segments: segments, audio: VideoAudioSettings(), limitsPeaks: true))
            XCTAssertNotNil(mix.inputParameters.first?.audioTapProcessor)
            let samples = try read(composition, tracks: [track], mix: mix)
            let asRecorded = stretch(samples, from: 0.1, to: 0.9)
            let louder = stretch(samples, from: 1.1, to: total.seconds - 0.1)
            print("PREVIEW LIMITER (fast: \(fast)): before \(asRecorded.peak), louder \(louder.peak) rms \(louder.rms)")
            XCTAssertEqual(asRecorded.peak, 0.5, accuracy: 0.01, "the clip at 100% plays as recorded")
            XCTAssertLessThanOrEqual(louder.peak, fast ? 0.95 : ceiling + 0.002, "three times as loud, held under the ceiling")
            XCTAssertGreaterThan(louder.rms, asRecorded.rms * 1.4, "and still clearly louder")
        }
        withExtendedLifetime(asset) {}
    }

    // MARK: Export

    func testABoostedPartExportsLouderAndNeverClips() async throws {
        let url = directory.appendingPathComponent("rec.mov")
        let voice = try writeTone(amplitude: 0.15, frequency: 440, seconds: 6)
        let silence = try writeTone(amplitude: 0, frequency: 1_000, seconds: 6)
        try await VideoTestSupport.writeRecording(to: url, seconds: 6, tones: [voice, silence])
        var (project, metadata) = twoTrackProject(url, seconds: 6, clips: [
            VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 2),
            VideoDemoTimelineClip(sourceStart: 2, sourceEnd: 4, voiceVolume: 3),
            // 0.15 × 3 × 2.5 (the whole video's voice) would be past full scale.
            VideoDemoTimelineClip(sourceStart: 4, sourceEnd: 6, voiceVolume: 3),
        ])
        project.audio.normalizeLoudness = false
        let output = directory.appendingPathComponent("boosted.mp4")
        try await VideoDemoExporter.export(project: project, recording: metadata, destinationURL: output, settings: exportSettings)
        var samples = try await read(output)
        let asRecorded = stretch(samples, from: 0.3, to: 1.7)
        let louder = stretch(samples, from: 2.3, to: 3.7)
        print("BOOSTED EXPORT: as recorded \(asRecorded.rms), at 300% \(louder.rms)")
        XCTAssertEqual(louder.rms / asRecorded.rms, 3, accuracy: 0.15, "300% plays three times as loud")

        // The video's 250% times the clip's 300% stops at 400% (+12 dB).
        project.audio.voiceVolume = 2.5
        project.timelineClips = [VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 6, voiceVolume: 3)]
        let both = directory.appendingPathComponent("both.mp4")
        try await VideoDemoExporter.export(project: project, recording: metadata, destinationURL: both, settings: exportSettings)
        samples = try await read(both)
        let capped = stretch(samples, from: 0.5, to: 5.5)
        print("CAPPED EXPORT: rms \(capped.rms), peak \(capped.peak)")
        XCTAssertEqual(capped.rms / asRecorded.rms, 4, accuracy: 0.2, "levels together stop at four times")
        XCTAssertGreaterThan(Double(capped.peak) / capped.rms, 1.38, "a clean sine")
    }

    func testSeparateSoundFilesOfABoostedPartDontClip() async throws {
        let url = directory.appendingPathComponent("rec.mov")
        let voice = try writeTone(amplitude: 0.5, frequency: 440, seconds: 3)
        let computer = try writeTone(amplitude: 0.2, frequency: 1_000, seconds: 3)
        try await VideoTestSupport.writeRecording(to: url, seconds: 3, tones: [voice, computer])
        var (project, metadata) = twoTrackProject(url, seconds: 3, clips: [VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 3, voiceVolume: 3)])
        project.audio.normalizeLoudness = false
        var settings = exportSettings
        settings.separateSound = true
        let output = directory.appendingPathComponent("parts.mp4")
        try await VideoDemoExporter.export(project: project, recording: metadata, destinationURL: output, settings: settings)
        for file in [output, VideoDemoExporter.separateSoundURL(.microphone, beside: output)] {
            let samples = try await read(file)
            let held = stretch(samples, from: 0.3, to: 2.7)
            print("PARTS \(file.lastPathComponent): peak \(held.peak), crest \(Double(held.peak) / held.rms)")
            XCTAssertLessThanOrEqual(held.peak, 1.0, file.lastPathComponent)
            XCTAssertGreaterThan(Double(held.peak) / held.rms, 1.3, "\(file.lastPathComponent) isn't clipped")
        }
    }

    // MARK: The slider

    func testLevelSliderPutsFullTwoThirdsAlongAndCatchesThere() {
        typealias Row = VideoLevelRow
        XCTAssertEqual(Row.position(for: 1), 2.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(Row.position(for: 0.5), 1.0 / 3, accuracy: 0.0001, "turning down is as fine as before 300% existed")
        XCTAssertEqual(Row.position(for: 3), 1, accuracy: 0.0001)
        XCTAssertEqual(Row.level(at: 1), 3)
        XCTAssertEqual(Row.level(at: 0), 0)
        XCTAssertEqual(Row.level(at: 2.0 / 3 + 0.01), 1, "catches at 100%")
        XCTAssertEqual(Row.level(at: 2.0 / 3 - 0.01), 1)
        for level in [0.25, 0.5, 0.73, 1.5, 2, 2.4, 3] {
            XCTAssertEqual(Row.level(at: Row.position(for: level)), level, accuracy: 0.0001, "\(level) survives the slider")
        }
        XCTAssertEqual(Row.level(at: 0.9), 2.4, accuracy: 0.0001, "whole percents")
        L10n.use(nil)
        XCTAssertEqual(Row.decibels(2), "+6 dB")
        XCTAssertEqual(Row.decibels(0.5), "−6 dB")
        XCTAssertEqual(Row.decibels(1.5), "+3.5 dB")
        XCTAssertNil(Row.decibels(1))
        XCTAssertNil(Row.decibels(0), "off has no dB")
        L10n.use("de")
        XCTAssertEqual(Row.decibels(1.5), "+3,5 dB")
        L10n.use("ru")
        XCTAssertEqual(Row.decibels(1.5), "+3,5 дБ")
    }

    private func sliders(in view: NSView) -> [NSSlider] {
        (view as? NSSlider).map { [$0] } ?? view.subviews.flatMap { sliders(in: $0) }
    }

    /// The level slider as a drag drives it: the real NSSlider's value
    /// steps along and it sends its action each step (AppKit's own tracking
    /// loop needs a mouse button really held, so it can't run hidden).
    func testDraggingTheLevelPastFullBoostsAndUndoesInOneStep() async throws {
        let model = try await T.make(in: directory, T.Options(audio: true))
        let id = try XCTUnwrap(model.project.timelineClips.first?.id)
        model.selectClip(id)
        let host = NSHostingView(rootView: VideoInspectorView(model: model).frame(width: 318, height: 900).environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 318, height: 900)
        let window = NSWindow(contentRect: NSRect(x: -9_000, y: -9_000, width: 318, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        await T.settle(0.4)
        func slider() throws -> NSSlider {
            try XCTUnwrap(sliders(in: host).first { $0.maxValue == 1 && $0.minValue == 0 && $0.isContinuous }, "the clip's Volume slider")
        }
        XCTAssertEqual(try slider().doubleValue, 2.0 / 3, accuracy: 0.001, "100% sits two-thirds along")

        // One action per move: outside AppKit's tracking, SwiftUI reports
        // each action as a whole edit (a real drag is one, from mouse-down
        // to mouse-up), so each move here is one undo step.
        func drag(to end: Double) async throws {
            let control = try slider()
            control.doubleValue = end
            control.sendAction(control.action, to: control.target)
            await T.settle(0.2)
        }
        try await drag(to: 1)
        XCTAssertEqual(model.project.timelineClips[0].volume, 3, accuracy: 0.0001, "dragged to the end: 300%")
        XCTAssertTrue(model.segments[0].clip.isLouder)
        XCTAssertEqual(try slider().doubleValue, 1, accuracy: 0.001)

        try await drag(to: 2.0 / 3 + 0.01)
        XCTAssertEqual(model.project.timelineClips[0].volume, 1, "caught at 100% on the way back")
        try await drag(to: 0.5)
        XCTAssertEqual(model.project.timelineClips[0].volume, 0.75, accuracy: 0.0001, "below 100%, as fine as before")

        model.undo()
        XCTAssertEqual(model.project.timelineClips[0].volume, 1, "⌘Z takes back the last move")
        model.undo()
        XCTAssertEqual(model.project.timelineClips[0].volume, 3, accuracy: 0.0001)
        model.undo()
        XCTAssertEqual(model.project.timelineClips[0].volume, 1, "and the first")
        XCTAssertFalse(model.canUndo)
    }

    /// The panels with a level past 100%, in every language, for a look.
    func testBoostedLevelsRenderInEveryLanguage() async throws {
        let url = directory.appendingPathComponent("rec.mov")
        let voice = try writeTone(amplitude: 0.2, frequency: 440, seconds: 6)
        let computer = try writeTone(amplitude: 0.1, frequency: 1_000, seconds: 6)
        try await VideoTestSupport.writeRecording(to: url, seconds: 6, tones: [voice, computer])
        let (_, metadata) = twoTrackProject(url, seconds: 6, clips: [])
        XCTAssertTrue(VideoDemoSidecarStore.save(metadata, for: url))
        VideoDemoDraftStore.delete(for: url)
        defer { VideoDemoDraftStore.delete(for: url) }
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        XCTAssertTrue(model.hasSeparateVoiceAndSystem)
        let range = VideoDemoTimelineRange(start: 2, end: 4)
        model.selection = .range(range)
        model.setRangeVolume(range, \.voiceVolume, 2.4)
        model.setRangeVolume(range, \.systemVolume, 0.5)
        model.endGesture()
        model.setStyle(coalesce: "voice") { $0.audio.voiceVolume = 1.5 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-boost", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for language in [nil, "de", "fr", "zh-Hans", "ru", "uk", "ja"] as [String?] {
            L10n.use(language)
            for state in ["part", "audio"] {
                if state == "part" {
                    model.selection = .range(range)
                } else {
                    model.selection = .none
                    model.inspectorTab = .audio
                }
                let host = NSHostingView(rootView: VideoInspectorView(model: model).frame(width: 318, height: 900).environment(\.colorScheme, .dark))
                host.frame = NSRect(x: 0, y: 0, width: 318, height: 900)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                await T.settle(0.3)
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let file = folder.appendingPathComponent("\(state)-\(language ?? "en").png")
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: file)
                print("SNAPSHOT: \(file.path)")
                window.contentView = nil
            }
        }
    }
}
