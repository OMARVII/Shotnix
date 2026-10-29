import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import ShotnixCore

/// The computer sound dips while you talk: finding the talking (and not
/// the speakers in the mic), the dips through cuts and hand changes, the
/// mix and the export, and dragging a dip on the real timeline.
@MainActor
final class VideoComputerSoundTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!
    private var window: NSWindow?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-duck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        if let directory {
            VideoDemoDraftStore.delete(for: directory.appendingPathComponent("talk.mov"))
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Finding the talking

    /// Music with a beat on the computer, `rate` values a second.
    private func beat(_ count: Int) -> [Float] {
        (0..<count).map { index in
            let phase = Double(index % 25) / 25
            return Float(0.15 + 0.85 * exp(-5 * phase))
        }
    }

    func testSpeakersInTheMicArentTalking() {
        let rate = Int(VideoVoiceActivity.rate)
        // A video plays out loud for the first 3 s, then the Mac is quiet;
        // the mic hears the speakers, and you talk from 4 to 6 s.
        let system = (0..<rate * 10).map { index -> Float in
            index < rate * 3 ? Float(0.8 + 0.1 * sin(Double(index) * 0.3)) : 0.05
        }
        let voice = system.indices.map { index -> Float in
            let bleed = system[index] * 0.3
            return index >= rate * 4 && index < rate * 6 ? bleed + 0.25 : bleed
        }
        let byLoudness = VideoVoiceActivity.speech(levels: voice)
        XCTAssertEqual(byLoudness.first?.lowerBound ?? 9, 0, accuracy: 0.1, "loudness alone takes the video for talking")
        let speech = VideoVoiceActivity.speech(levels: voice, system: system)
        XCTAssertEqual(speech.count, 1, "\(speech)")
        XCTAssertEqual(speech.first?.lowerBound ?? 0, 4, accuracy: 0.15)
        XCTAssertEqual(speech.first?.upperBound ?? 0, 6, accuracy: 0.15)
    }

    func testWithHeadphonesTheVoiceIsLeftAlone() {
        let rate = Int(VideoVoiceActivity.rate)
        let system = beat(rate * 10)
        let voice = system.indices.map { index -> Float in
            let room = Float(0.002 + 0.001 * sin(Double(index) * 0.37))
            return index >= rate * 2 && index < rate * 3 ? 0.3 : room
        }
        XCTAssertEqual(VideoVoiceActivity.withoutBleed(voice, system: system), voice)
        let speech = VideoVoiceActivity.speech(levels: voice, system: system)
        XCTAssertEqual(speech.count, 1)
        XCTAssertEqual(speech.first?.lowerBound ?? 0, 2, accuracy: 0.05)
    }

    // MARK: Dips

    private func project(clips: [VideoDemoTimelineClip]) -> VideoDemoProject {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/talk.mov"), duration: 10)
        project.timelineClips = clips
        return project
    }

    func testDipsFollowTheTalkingThroughCutsAndHandChanges() {
        // 3–5 s cut away.
        var project = project(clips: [VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 3), VideoDemoTimelineClip(sourceStart: 5, sourceEnd: 10)])
        let segments = project.timelineSegments(totalDuration: 10)
        // A pause under 1.5 s stays dipped; 7–8 s is on its own.
        let speech = ["": [1.0...2.5, 2.8...4.0, 7.0...8.0]]
        let kinds: [VideoAudioKind] = [.microphone, .system]
        var dips = VideoComputerSoundDucking.dips(project: project, primaryKinds: kinds, speech: speech, segments: segments)
        XCTAssertEqual(dips.map(\.range), [1.0...3.0, 5.0...6.0], "on the timeline, the cut part gone")
        XCTAssertEqual(dips.map(\.level), [0.3, 0.3])
        XCTAssertEqual(dips.first?.talk, 1.0...4.0, "kept against the recording")

        // One set by hand, one left alone.
        project.audio.systemDuckSpots = [VideoDuckSpot(start: 1, end: 4, level: 0.6), VideoDuckSpot(start: 7, end: 8, level: 1)]
        dips = VideoComputerSoundDucking.dips(project: project, primaryKinds: kinds, speech: speech, segments: segments)
        XCTAssertEqual(dips.map(\.level), [0.6, 1])
        XCTAssertEqual(dips.map(\.custom), [true, true])
        XCTAssertFalse(dips[1].lowered)
        XCTAssertEqual(VideoComputerSoundDucking.duck(at: 5.5, dips: dips), 1, "left alone")
        XCTAssertEqual(VideoComputerSoundDucking.duck(at: 2, dips: dips), 0.6, accuracy: 0.0001)
        XCTAssertEqual(VideoComputerSoundDucking.duck(at: 1 - VideoMusicMix.duckAttack / 2, dips: dips), 0.8, accuracy: 0.0001, "eases down just before")
        XCTAssertEqual(VideoComputerSoundDucking.duck(at: 3 + VideoMusicMix.duckRelease, dips: dips), 1, accuracy: 0.0001, "back after")

        // A muted part, or one whose voice is turned all the way down,
        // has nothing to dip under.
        project.timelineClips[1].muted = true
        XCTAssertEqual(VideoComputerSoundDucking.dips(project: project, primaryKinds: kinds, speech: speech, segments: project.timelineSegments(totalDuration: 10)).count, 1)
        project.timelineClips[1].muted = false
        project.timelineClips[0].voiceVolume = 0
        XCTAssertEqual(VideoComputerSoundDucking.dips(project: project, primaryKinds: kinds, speech: speech, segments: project.timelineSegments(totalDuration: 10)).map(\.range), [5.0...6.0])

        project.audio.duckSystem = false
        XCTAssertTrue(VideoComputerSoundDucking.dips(project: project, primaryKinds: kinds, speech: speech, segments: segments).isEmpty)
    }

    func testNewVideosDuckAndOldDraftsPlayAsBefore() throws {
        XCTAssertTrue(VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/new.mov"), duration: 5).audio.duckSystem)
        let old = try JSONDecoder().decode(VideoAudioSettings.self, from: Data(#"{"volume":1,"systemVolume":0.8}"#.utf8))
        XCTAssertFalse(old.duckSystem)
        XCTAssertEqual(old.systemDuckLevel, 0.3)
        XCTAssertTrue(old.systemDuckSpots.isEmpty)

        var audio = VideoAudioSettings()
        audio.duckSystem = true
        audio.systemDuckLevel = 0.2
        audio.systemDuckSpots = [VideoDuckSpot(start: 1, end: 2, level: 1)]
        let saved = try JSONDecoder().decode(VideoAudioSettings.self, from: JSONEncoder().encode(audio))
        XCTAssertEqual(saved, audio)
    }

    // MARK: Mix

    func testMixDipsOnlyTheComputerSound() throws {
        let composition = AVMutableComposition()
        let video = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let mic = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let system = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let clips = [VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 5), VideoDemoTimelineClip(sourceStart: 5, sourceEnd: 10, fadeOut: 1, systemVolume: 0.5)]
        let segments = [VideoDemoTimelineSegment(clip: clips[0], timelineStart: 0), VideoDemoTimelineSegment(clip: clips[1], timelineStart: 5)]
        let placements = segments.map {
            VideoCompositionBuilder.Placement(start: CMTime(seconds: $0.timelineStart, preferredTimescale: 600), duration: CMTime(seconds: 5, preferredTimescale: 600), segment: $0)
        }
        let edit = VideoEditComposition(
            composition: composition, videoTrack: video, audioTracks: [mic, system], audioKinds: [.microphone, .system],
            audioMix: nil, placements: placements,
            duration: CMTime(seconds: 10, preferredTimescale: 600), sourceSize: CGSize(width: 640, height: 400), orientation: .identity
        )
        var extras = VideoEditExtras()
        extras.computerSoundDips = [
            VideoSoundDip(range: 2...3, level: 0.3, talk: 2...3, custom: false),
            VideoSoundDip(range: 6...7, level: 0.3, talk: 6...7, custom: false),
        ]
        let mix = try XCTUnwrap(VideoCompositionBuilder.audioMix(for: edit, segments: segments, audio: VideoAudioSettings(), extras: extras))
        func volume(_ track: Int, at seconds: Double) -> Double {
            var start: Float = -1, end: Float = -1
            var range = CMTimeRange()
            _ = mix.inputParameters[track].getVolumeRamp(for: CMTime(seconds: seconds, preferredTimescale: 600), startVolume: &start, endVolume: &end, timeRange: &range)
            let into = range.duration.seconds > 0 ? (seconds - range.start.seconds) / range.duration.seconds : 0
            return Double(start) + Double(end - start) * into
        }
        XCTAssertEqual(volume(1, at: 1), 1, accuracy: 0.001)
        XCTAssertEqual(volume(1, at: 2.5), 0.3, accuracy: 0.001, "under your voice")
        XCTAssertEqual(volume(1, at: 2 - VideoMusicMix.duckAttack / 2), 0.65, accuracy: 0.01, "eases down")
        XCTAssertEqual(volume(1, at: 4), 1, accuracy: 0.001, "back up")
        XCTAssertEqual(volume(0, at: 2.5), 1, accuracy: 0.001, "the voice stays")
        XCTAssertEqual(volume(1, at: 6.5), 0.15, accuracy: 0.001, "a part's own level and the dip multiply")
        XCTAssertEqual(volume(1, at: 9.5), 0.25, accuracy: 0.01, "and its fade still runs")
    }

    // MARK: A real recording

    /// `seconds` of a recording: you talk from `talkStart`, the computer
    /// plays a steady 6 kHz tone, and the speakers reach the mic.
    private func writeTalkingRecording(seconds: Double, talkStart: Double) async throws -> (URL, VideoDemoRecordingMetadata) {
        let rate = 48_000.0
        let speech = directory.appendingPathComponent("speech.caf")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", speech.path, "--data-format=LEF32@48000", "[[slnc \(Int(talkStart * 1000))]] Here is the report, and this is how it works."]
        try say.run()
        say.waitUntilExit()
        let speechFile = try AVAudioFile(forReading: speech)
        let speechBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: speechFile.processingFormat, frameCapacity: AVAudioFrameCount(speechFile.length)))
        try speechFile.read(into: speechBuffer)
        let frames = Int(seconds * rate)
        let system = (0..<frames).map { Float(sin(2 * .pi * 6_000 * Double($0) / rate) * 0.2) }
        let mic = (0..<frames).map { index -> Float in
            let voice = index < Int(speechBuffer.frameLength) ? speechBuffer.floatChannelData![0][index] : 0
            return voice + (index >= 240 ? system[index - 240] * 0.05 : 0)
        }
        func write(_ samples: [Float], to url: URL) throws {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for index in samples.indices { buffer.floatChannelData![0][index] = samples[index] }
            try file.write(from: buffer)
        }
        let micURL = directory.appendingPathComponent("mic.caf")
        let systemURL = directory.appendingPathComponent("system.caf")
        try write(mic, to: micURL)
        try write(system, to: systemURL)

        let picture = directory.appendingPathComponent("picture.mp4")
        try await VideoTestSupport.writeFakeRecording(to: picture, size: CGSize(width: 640, height: 400), seconds: seconds, fps: 30)
        let composition = AVMutableComposition()
        let pictureAsset = AVURLAsset(url: picture)
        let pictureTracks = try await pictureAsset.loadTracks(withMediaType: .video)
        let pictureTrack = try XCTUnwrap(pictureTracks.first)
        let whole = try await pictureTrack.load(.timeRange)
        let videoTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try videoTrack.insertTimeRange(whole, of: pictureTrack, at: .zero)
        var assets: [AVURLAsset] = []
        for source in [micURL, systemURL] {
            let asset = AVURLAsset(url: source)
            assets.append(asset)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let track = try XCTUnwrap(tracks.first)
            let range = try await track.load(.timeRange)
            let lane = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try lane.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(range.duration, whole.duration)), of: track, at: .zero)
        }
        let url = directory.appendingPathComponent("talk.mov")
        let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        session.outputURL = url
        session.outputFileType = .mov
        await session.export()
        XCTAssertEqual(session.status, .completed, session.error?.localizedDescription ?? "")
        let metadata = VideoDemoRecordingMetadata(videoURLPath: url.path, createdAt: Date(), duration: seconds, sourceWidth: 640, sourceHeight: 400, fps: 30, nativeCursorVisible: true, cursorSamples: [], clickEvents: [], audioTracks: [.microphone, .system])
        XCTAssertTrue(VideoDemoSidecarStore.save(metadata, for: url))
        VideoDemoDraftStore.delete(for: url)
        return (url, metadata)
    }

    /// How strong the 6 kHz tone is in a stretch of an exported file.
    private func tone(in url: URL, from: Double, to: Double) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var re = 0.0, im = 0.0, count = 0, frame = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { floats in
                for index in 0..<(length / 4) {
                    let seconds = Double(frame) / 48_000
                    if seconds >= from, seconds < to {
                        let angle = 2 * .pi * 6_000 * seconds
                        re += Double(floats[index]) * cos(angle)
                        im += Double(floats[index]) * sin(angle)
                        count += 1
                    }
                    frame += 1
                }
            }
        }
        return 2 * (re * re + im * im).squareRoot() / Double(max(count, 1))
    }

    func testExportLowersTheComputerSoundWhileYouTalk() async throws {
        let (url, metadata) = try await writeTalkingRecording(seconds: 6, talkStart: 1.5)
        let speech = await VideoVoiceActivity.speech(url: url, trackIndex: 0, systemTrackIndex: 1)
        let first = try XCTUnwrap(speech.first)
        XCTAssertEqual(first.lowerBound, 1.5, accuracy: 0.2, "\(speech)")
        XCTAssertLessThan(speech.last?.upperBound ?? 6, 5.2, "the speakers in the mic after you stop aren't talking: \(speech)")

        var project = VideoDemoProject.make(sourceURL: url, duration: 6, sourceSize: CGSize(width: 640, height: 400))
        project.apply(metadata: metadata)
        project.audio.normalizeLoudness = false
        var settings = VideoExportSettings()
        settings.resolution = .p720
        settings.fps = 30
        settings.endCard = false
        let ducked = directory.appendingPathComponent("ducked.mp4")
        try await VideoDemoExporter.export(project: project, recording: metadata, destinationURL: ducked, settings: settings)
        let before = try await tone(in: ducked, from: 0.2, to: 1.0)
        let during = try await tone(in: ducked, from: first.lowerBound + 0.4, to: first.lowerBound + 1.4)
        print("DUCK: tone before \(before), while talking \(during)")
        XCTAssertGreaterThan(before, 0.1)
        XCTAssertEqual(during / before, 0.3, accuracy: 0.06, "the computer sound at 30% while you talk")

        project.audio.duckSystem = false
        let plain = directory.appendingPathComponent("plain.mp4")
        try await VideoDemoExporter.export(project: project, recording: metadata, destinationURL: plain, settings: settings)
        let steady = try await tone(in: plain, from: first.lowerBound + 0.4, to: first.lowerBound + 1.4)
        let steadyBefore = try await tone(in: plain, from: 0.2, to: 1.0)
        XCTAssertEqual(steady / steadyBefore, 1, accuracy: 0.06, "off: left as recorded")
    }

    // MARK: The timeline

    private final class Host: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func testDraggingADipOnTheTimelineChangesJustThatPlace() async throws {
        let (url, _) = try await writeTalkingRecording(seconds: 10, talkStart: 2)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        XCTAssertTrue(model.project.audio.duckSystem)
        for _ in 0..<100 where model.computerSoundDips.isEmpty || model.listeningForVoice {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let dip = try XCTUnwrap(model.computerSoundDips.first)
        XCTAssertTrue(model.showsComputerSoundLane)
        XCTAssertEqual(model.computerSoundDipCounts.places, 1)

        // 100 pt a second (x = 18 + 100·t); the lane sits under the clips.
        let size = CGSize(width: 1036, height: 360)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = Host(rootView: AnyView(VideoTimelineView(model: model).frame(width: size.width, height: size.height)))
        window.orderFrontRegardless()
        self.window = window
        try await Task.sleep(nanoseconds: 300_000_000)
        typealias M = VideoTimelineMetrics
        let laneY = 45 + M.rulerHeight + M.gap + M.zoomTrackHeight + M.gap + M.clipTrackHeight + M.gap + M.computerSoundLaneHeight / 2
        let x = 18 + CGFloat((dip.range.lowerBound + dip.range.upperBound) / 2) * 100
        func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: size.height - point.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        // Up a quarter of the line's height: 30% → 55%.
        let rise = (M.computerSoundLaneHeight - 8) / 4
        send(.leftMouseDown, CGPoint(x: x, y: laneY))
        try await Task.sleep(nanoseconds: 50_000_000)
        for step in 1...8 {
            send(.leftMouseDragged, CGPoint(x: x, y: laneY - rise * CGFloat(step) / 8))
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        send(.leftMouseUp, CGPoint(x: x, y: laneY - rise))
        try await Task.sleep(nanoseconds: 200_000_000)

        let spot = try XCTUnwrap(model.project.audio.systemDuckSpots.first, "the drag set that place by hand")
        XCTAssertEqual(spot.level, 0.55, accuracy: 0.03)
        XCTAssertEqual(model.project.audio.systemDuckLevel, 0.3, "the rest keep the level in Audio")
        XCTAssertEqual(model.computerSoundDips.first?.level ?? 0, 0.55, accuracy: 0.03)
        XCTAssertEqual(model.computerSoundDipCounts.custom, 1)
        XCTAssertEqual(model.undoLabel, "Sound Change")

        // One undo puts the whole drag back.
        model.undo()
        XCTAssertTrue(model.project.audio.systemDuckSpots.isEmpty)

        model.setComputerSoundDip(dip.talk, level: 1)
        XCTAssertEqual(VideoComputerSoundDucking.duck(at: (dip.range.lowerBound + dip.range.upperBound) / 2, dips: model.computerSoundDips), 1, "left alone")
        model.useComputerSoundDipEverywhere(0.2)
        XCTAssertEqual(model.project.audio.systemDuckLevel, 0.2)
        XCTAssertEqual(model.project.audio.systemDuckSpots.count, 1, "a place left alone stays that way")
        model.resetComputerSoundDips()
        XCTAssertTrue(model.project.audio.systemDuckSpots.isEmpty)
        VideoDemoDraftStore.delete(for: url)
    }
}
