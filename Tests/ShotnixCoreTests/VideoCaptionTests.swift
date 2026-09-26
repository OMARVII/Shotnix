import AVFoundation
import Speech
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

    func testNoOneWordStragglers() {
        // Eight words: the seven-word limit would leave "it." alone.
        let input = words([
            ("Then", 0.0, 0.2), ("pick", 0.25, 0.4), ("a", 0.45, 0.5), ("theme", 0.55, 0.8),
            ("and", 0.9, 1.0), ("uh", 1.1, 1.2), ("save", 1.4, 1.6), ("it.", 1.65, 1.8),
        ])
        XCTAssertEqual(VideoCaptionBuilder.lines(from: input).map(\.text), ["Then pick a theme", "and uh save it."])
        // A real pause still gets its own line, however short.
        let paused = words([
            ("Open", 0.0, 0.2), ("the", 0.25, 0.4), ("settings", 0.45, 0.8), ("panel", 0.85, 1.0),
            ("now.", 2.5, 2.8),
        ])
        XCTAssertEqual(VideoCaptionBuilder.lines(from: paused).map(\.text), ["Open the settings panel", "now."])
        // Nor does a sentence's tail ride along into the next sentence.
        let flowing = words([
            ("Thursday", 0.0, 0.3), ("was", 0.32, 0.45), ("easily", 0.5, 0.8), ("our", 0.85, 1.0),
            ("best", 1.02, 1.25), ("day", 1.27, 1.45), ("this", 1.47, 1.6), ("week.", 1.62, 1.85),
            ("Export", 2.1, 2.4), ("the", 2.42, 2.5), ("report.", 2.52, 2.9),
        ])
        XCTAssertEqual(VideoCaptionBuilder.lines(from: flowing).map(\.text), ["Thursday was easily our", "best day this week.", "Export the report."])
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
        let result = try await VideoCaptionTranscriber.transcribe(url: audio, languageIdentifier: "en-US") { stage in
            stages.append(stage)
        }
        let words = result.words
        XCTAssertEqual(result.language, "en-US")
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
    func testLanguageFallsBackWithinTheSameLanguage() {
        let supported = ["en-US", "en-GB", "de-DE", "de-AT", "fr-FR", "pt-BR", "pt-PT"].map(Locale.init(identifier:))
        func closest(_ identifier: String) -> String? {
            VideoCaptionTranscriber.closest(to: Locale(identifier: identifier), in: supported)?.identifier(.bcp47)
        }
        XCTAssertEqual(closest("en-DE"), "en-US", "English on a German Mac")
        XCTAssertEqual(closest("en-GB"), "en-GB")
        XCTAssertEqual(closest("de-CH"), "de-DE")
        XCTAssertEqual(closest("pt-AO"), "pt-BR")
        XCTAssertNil(closest("ja-JP"))
    }

    func testFillersDependOnTheLanguage() {
        let line = VideoCaptionLine(start: 0, end: 3, text: "", words: ["Clique", "em", "um", "botão", "uh"].enumerated().map { VideoCaptionWord(text: $0.element, start: Double($0.offset) * 0.5, end: Double($0.offset) * 0.5 + 0.4) })
        let portuguese = VideoTranscript.words(from: [line], language: "pt-BR")
        XCTAssertEqual(portuguese.filter(\.isFiller).map(\.text), ["uh"], "\"um\" is a word in Portuguese")
        let english = VideoTranscript.words(from: [line], language: "en-US")
        XCTAssertEqual(english.filter(\.isFiller).map(\.text), ["um", "uh"])
        let german = VideoCaptionLine(start: 0, end: 2, text: "", words: [VideoCaptionWord(text: "er", start: 0, end: 0.3), VideoCaptionWord(text: "ähm", start: 0.5, end: 0.8)])
        XCTAssertEqual(VideoTranscript.words(from: [german], language: "de-DE").filter(\.isFiller).map(\.text), ["ähm"])
    }

    func testRecognizedStretchesJoinUp() {
        typealias Pieces = LegacyRecognition.Pieces
        let first: Pieces = [("Open", 0, 0.3), ("settings.", 0.35, 0.9)]
        let second: Pieces = [("Then", 3.4, 3.6), ("save.", 3.7, 4.0)]
        // One result per utterance: they add up.
        XCTAssertEqual(LegacyRecognition.merge(LegacyRecognition.merge([], first), second).map(\.text), ["Open", "settings.", "Then", "save."])
        // A result with everything so far replaces what was collected.
        let everything: Pieces = first + second
        XCTAssertEqual(LegacyRecognition.merge(first, everything).map(\.text), ["Open", "settings.", "Then", "save."])
        // A stale partial repeat changes nothing.
        XCTAssertEqual(LegacyRecognition.merge(everything, first).count, 4)
        // One that re-covers the end replaces just the overlap.
        let revised: Pieces = [("save,", 3.7, 4.1), ("then", 5, 5.2), ("close.", 5.3, 5.8)]
        XCTAssertEqual(LegacyRecognition.merge(everything, revised).map(\.text), ["Open", "settings.", "Then", "save,", "then", "close."])
    }

    @MainActor
    func testTypedCaptionLinesStayTyped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-typed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rec.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 640, height: 400), seconds: 4, fps: 30, audioSeconds: 4)
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        model.seek(to: 1)
        model.addCaptionAtPlayhead()
        let id = try XCTUnwrap(model.selectedCaptionID)
        model.updateCaption(id, text: "Welcome to the demo")
        XCTAssertTrue(model.project.captions.first?.words.isEmpty ?? false, "no made-up word timings")
        XCTAssertFalse(model.hasTranscript, "a typed line isn't a transcript")
        XCTAssertTrue(model.transcriptWords.isEmpty, "nothing to cut the video with")
        VideoDemoDraftStore.delete(for: url)
    }

    func testChineseAndJapaneseCaptionsHaveNoSpaces() {
        let words = [("今日", 0.0), ("は", 0.3), ("天気", 0.5), ("が", 0.8), ("いい", 1.0), ("OK", 1.3)].map { VideoCaptionWord(text: $0.0, start: $0.1, end: $0.1 + 0.2) }
        XCTAssertEqual(VideoCaptionBuilder.lines(from: words).map(\.text), ["今日は天気がいい OK"])
        XCTAssertEqual(VideoCaptionBuilder.joined(["Hello", "there."]), "Hello there.")
    }

    func testSubtitlesLeaveOutCutWords() {
        let line = VideoCaptionLine(start: 0.95, end: 3, text: "Um, so open the settings", words: [
            VideoCaptionWord(text: "Um,", start: 1.0, end: 1.3),
            VideoCaptionWord(text: "so", start: 1.45, end: 1.6),
            VideoCaptionWord(text: "open", start: 1.7, end: 2.0),
            VideoCaptionWord(text: "the", start: 2.05, end: 2.2),
            VideoCaptionWord(text: "settings", start: 2.25, end: 2.8),
        ])
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/cut.mp4"), duration: 5, sourceSize: CGSize(width: 1280, height: 800))
        project.captions = [line]
        // "Um," is cut from the video.
        project.removeSourceRanges([0.98...1.4], totalDuration: 5)
        let srt = VideoCaptionBuilder.srt(lines: project.captions, segments: project.timelineSegments(totalDuration: 5))
        XCTAssertTrue(srt.contains("so open the settings"))
        XCTAssertFalse(srt.contains("Um"), srt)
    }

    /// The macOS 13–25 recognizer, on-device only, keeps every sentence
    /// of a narration with long pauses. Opt-in (SHOTNIX_SPEECH_TEST=1).
    func testLegacyRecognizerKeepsEverySentence() async throws {
        guard ProcessInfo.processInfo.environment["SHOTNIX_SPEECH_TEST"] == "1" else {
            throw XCTSkip("Set SHOTNIX_SPEECH_TEST=1 to run the on-device speech test")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", audio.path, "Open the settings panel. [[slnc 2500]] Then turn on dark mode. [[slnc 2500]] Finally save your changes."]
        try say.run()
        say.waitUntilExit()
        // The older recognizer needs the Speech Recognition permission (and
        // a usage description the test runner doesn't have).
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw XCTSkip("Speech Recognition isn't allowed for the test runner")
        }
        VideoCaptionTranscriber.usesLegacyRecognizer = true
        defer { VideoCaptionTranscriber.usesLegacyRecognizer = false }
        do {
            let result = try await VideoCaptionTranscriber.transcribe(url: audio, languageIdentifier: "en-US") { _ in }
            let text = result.words.map(\.text).joined(separator: " ").lowercased()
            print("LEGACY TRANSCRIPT: \(text)")
            XCTAssertTrue(text.contains("settings"), text)
            XCTAssertTrue(text.contains("dark mode"), text)
            XCTAssertTrue(text.contains("save"), text)
        } catch VideoCaptionTranscriber.Failure.needsOnDeviceModel(let name) {
            throw XCTSkip("No on-device model for \(name) on this Mac")
        }
    }

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
