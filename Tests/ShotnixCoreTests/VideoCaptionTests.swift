import AVFoundation
import XCTest
@testable import ShotnixCore

final class VideoCaptionTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private func words(_ spec: [(String, Double, Double)]) -> [VideoCaptionWord] {
        spec.map { VideoCaptionWord(text: $0.0, start: $0.1, end: $0.2) }
    }

    func testLinesBreakOnPausesSentencesAndLength() {
        let input = words([
            ("Open", 0.0, 0.3), ("the", 0.3, 0.4), ("settings.", 0.4, 0.9),
            ("Then", 1.0, 1.2), ("pick", 1.2, 1.4), ("a", 1.4, 1.5), ("theme", 1.5, 1.9),
            // Long pause → new line.
            ("Done", 3.5, 3.9),
        ])
        let lines = VideoCaptionBuilder.lines(from: input)
        XCTAssertEqual(lines.map(\.text), ["Open the settings.", "Then pick a theme", "Done"])
        XCTAssertEqual(lines[0].start, 0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(lines[0].end, lines[1].start + 0.0001, "lines never overlap")
        XCTAssertEqual(lines[2].words.count, 1)

        // Seven words max per line.
        let many = (0..<16).map { VideoCaptionWord(text: "w\($0)", start: Double($0) * 0.2, end: Double($0) * 0.2 + 0.15) }
        let split = VideoCaptionBuilder.lines(from: many)
        XCTAssertTrue(split.allSatisfy { $0.words.count <= 7 })
        XCTAssertEqual(split.reduce(0) { $0 + $1.words.count }, 16)
    }

    func testPiecesBecomeWords() {
        let result = VideoCaptionBuilder.words(fromPieces: [
            ("Hello", 0, 0.4), (",", 0.4, 0.4), (" world", 0.5, 0.9), ("two words", 1.0, 2.0),
        ])
        XCTAssertEqual(result.map(\.text), ["Hello,", "world", "two", "words"])
        XCTAssertEqual(result[2].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(result[3].end, 2.0, accuracy: 0.001)
    }

    func testSRTFollowsTheEditedTimeline() {
        let lines = [
            VideoCaptionLine(start: 1, end: 2, text: "Kept"),
            VideoCaptionLine(start: 3, end: 3.5, text: "Cut away"),
            VideoCaptionLine(start: 5, end: 6.5, text: "After the cut"),
        ]
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/srt.mp4"), duration: 10, sourceSize: CGSize(width: 1920, height: 1080))
        project.timelineClips = [
            VideoDemoTimelineClip(sourceStart: 0, sourceEnd: 2.5),
            VideoDemoTimelineClip(sourceStart: 4, sourceEnd: 10),
        ]
        let srt = VideoCaptionBuilder.srt(lines: lines, segments: project.timelineSegments(totalDuration: 10))
        XCTAssertEqual(srt, """
        1
        00:00:01,000 --> 00:00:02,000
        Kept

        2
        00:00:03,500 --> 00:00:05,000
        After the cut


        """)
    }

    /// Real on-device transcription of synthesized speech. Opt-in: it may
    /// download the language model the first time.
    func testTranscribesSpeech() async throws {
        guard ProcessInfo.processInfo.environment["SHOTNIX_SPEECH_TEST"] == "1" else {
            throw XCTSkip("Set SHOTNIX_SPEECH_TEST=1 to run the on-device speech test")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-speech-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", audio.path, "[[slnc 1200]] Open the settings panel. Then turn on dark mode and save your changes."]
        try say.run()
        say.waitUntilExit()

        let stages = StageLog()
        let words = try await VideoCaptionTranscriber.transcribe(url: audio, languageIdentifier: "en-US") { stage in
            stages.append(stage)
        }
        let text = words.map(\.text).joined(separator: " ").lowercased()
        print("TRANSCRIPT: \(text)")
        print("WORDS: \(words.map { String(format: "%@ %.2f-%.2f", $0.text, $0.start, $0.end) })")
        XCTAssertTrue(text.contains("settings"))
        XCTAssertTrue(text.contains("dark mode"))
        XCTAssertTrue(words.allSatisfy { $0.end >= $0.start })
        XCTAssertTrue(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start + 0.001 }, "chronological")
        let lines = VideoCaptionBuilder.lines(from: words)
        print("LINES: \(lines.map(\.text))")
        XCTAssertGreaterThanOrEqual(lines.count, 2)
    }
}

extension VideoCaptionTests {
    /// The editor flow: Generate Captions on a narrated recording.
    @MainActor
    func testEditorGeneratesCaptionsFromNarration() async throws {
        guard ProcessInfo.processInfo.environment["SHOTNIX_SPEECH_TEST"] == "1" else {
            throw XCTSkip("Set SHOTNIX_SPEECH_TEST=1 to run the on-device speech test")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-narrated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let speech = directory.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", speech.path, "[[slnc 1200]] Click the export button. Pick a size and share the link with your team."]
        try say.run()
        say.waitUntilExit()

        let silent = directory.appendingPathComponent("silent.mp4")
        try await VideoTestSupport.writeFakeRecording(to: silent, size: CGSize(width: 640, height: 400), seconds: 6, fps: 30)
        // Mux the narration under the screen video.
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: silent)
        let audioAsset = AVURLAsset(url: speech)
        let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first!
        let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first!
        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try v.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
        let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try a.insertTimeRange(CMTimeRange(start: .zero, duration: min(audioDuration, videoDuration)), of: audioTrack, at: .zero)
        let narrated = directory.appendingPathComponent("narrated.mov")
        let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        try await session.export(to: narrated, as: .mov)

        VideoDemoDraftStore.delete(for: narrated)
        let model = VideoEditorModel(videoURL: narrated)
        await model.load()
        XCTAssertTrue(model.hasAudio)
        model.captionLanguage = "en-US"
        model.generateCaptions()
        for _ in 0..<200 where model.captionJob != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(model.captionJob?.error)
        let text = model.project.captions.map(\.text).joined(separator: " ").lowercased()
        print("EDITOR CAPTIONS: \(model.project.captions.map { String(format: "%.2f-%.2f %@", $0.start, $0.end, $0.text) })")
        XCTAssertTrue(text.contains("export"))
        XCTAssertTrue(text.contains("link"))
        // The narration starts after 1.2 s of silence.
        XCTAssertEqual(model.project.captions.first?.start ?? 0, 1.2, accuracy: 0.3)
        XCTAssertNotNil(model.plan.caption(at: (model.project.captions.first?.start ?? 0) + 0.3))
        // Undo removes them in one step.
        model.undo()
        XCTAssertTrue(model.project.captions.isEmpty)
        VideoDemoDraftStore.delete(for: narrated)
    }
}

private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [VideoCaptionTranscriber.Stage] = []
    func append(_ stage: VideoCaptionTranscriber.Stage) {
        lock.withLock { stages.append(stage) }
    }
}
