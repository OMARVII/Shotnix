import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

@MainActor
final class VideoTranscriptTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory {
            VideoDemoDraftStore.delete(for: directory.appendingPathComponent("rec.mp4"))
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// "So, um, open the settings. [3 s silence] Then, uh, save."
    private static let spoken: [(String, Double, Double)] = [
        ("So,", 0.5, 0.8), ("um,", 0.9, 1.3), ("open", 1.4, 1.7), ("the", 1.7, 1.85), ("settings.", 1.85, 2.4),
        ("Then,", 5.4, 5.8), ("uh,", 5.9, 6.2), ("save.", 6.3, 6.8),
    ]

    private func makeModel(seconds: Double = 8, spoken: [(String, Double, Double)]? = nil) async throws -> VideoEditorModel {
        let url = directory.appendingPathComponent("rec.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 640, height: 400), seconds: seconds, fps: 30, audioSeconds: seconds)
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        XCTAssertTrue(model.isReady)
        let words = (spoken ?? Self.spoken).map { VideoCaptionWord(text: $0.0, start: $0.1, end: $0.2) }
        model.mutate { $0.captions = VideoCaptionBuilder.lines(from: words) }
        return model
    }

    func testRemoveAndRestoreSourceRanges() {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/t.mp4"), duration: 10, sourceSize: CGSize(width: 640, height: 400))
        project.ensureTimeline(totalDuration: 10)
        XCTAssertTrue(project.removeSourceRanges([2...3, 5...6.5], totalDuration: 10))
        XCTAssertEqual(project.timelineClips.map { [$0.sourceStart, $0.sourceEnd] }, [[0, 2], [3, 5], [6.5, 10]])
        XCTAssertEqual(Set(project.timelineClips.map(\.id)).count, 3, "every piece has its own id")
        // Restoring the middle of a gap makes its own clip, then merges.
        project.restoreSourceRange(5.5...6.0, totalDuration: 10)
        XCTAssertEqual(project.timelineDuration(totalDuration: 10), 8, accuracy: 0.01)
        project.restoreSourceRange(2...3, totalDuration: 10)
        project.restoreSourceRange(5...6.5, totalDuration: 10)
        XCTAssertEqual(project.timelineClips.map { [$0.sourceStart, $0.sourceEnd] }, [[0, 10]], "fully restored and merged")
        XCTAssertFalse(project.removeSourceRanges([0...10], totalDuration: 10), "never removes everything")
    }

    func testCutAndRestoreWords() async throws {
        let model = try await makeModel()
        let words = model.transcriptWords
        XCTAssertEqual(words.map(\.text), Self.spoken.map(\.0))
        let before = model.timelineDuration
        // Cut "open the" (indices 2, 3).
        model.cutWords(IndexSet([2, 3]))
        XCTAssertFalse(model.isIncluded(words[2]))
        XCTAssertFalse(model.isIncluded(words[3]))
        XCTAssertTrue(model.isIncluded(words[4]))
        XCTAssertEqual(before - model.timelineDuration, 1.85 - 1.38, accuracy: 0.05)
        // The caption drops the cut words.
        let caption = try XCTUnwrap(model.plan.captions.first)
        XCTAssertFalse(caption.text.contains("open"))
        XCTAssertTrue(caption.text.contains("settings."))
        // Restore puts them back exactly.
        model.restoreWords(IndexSet([2, 3]))
        XCTAssertTrue(model.isIncluded(words[2]))
        XCTAssertEqual(model.timelineDuration, before, accuracy: 0.02)
        XCTAssertEqual(model.segments.count, 1, "seamless again")
    }

    func testRemoveFillersAndShortenPauses() async throws {
        let model = try await makeModel()
        XCTAssertEqual(model.fillerCount, 2)
        let before = model.timelineDuration
        model.removeFillers()
        XCTAssertEqual(model.fillerCount, 0)
        let words = model.transcriptWords
        XCTAssertFalse(model.isIncluded(words[1]), "um is gone")
        XCTAssertTrue(model.isIncluded(words[0]))
        XCTAssertTrue(model.isIncluded(words[2]))
        XCTAssertGreaterThan(before - model.timelineDuration, 0.4)

        // The 3 s silence (no activity) shortens to about 0.4 s.
        XCTAssertEqual(model.pauseRanges.count, 1)
        let beforePause = model.timelineDuration
        model.shortenPauses()
        XCTAssertEqual(beforePause - model.timelineDuration, 3.0 - 0.4, accuracy: 0.05)
        XCTAssertTrue(model.pauseRanges.isEmpty)
    }

    func testPausesWithOnScreenActivityStay() async throws {
        let model = try await makeModel()
        // A click in the middle of the silence: that pause is the demo.
        model.mutate { $0.clickEvents = [VideoDemoClickEvent(time: 4.0, x: 0.5, y: 0.5, button: .left, endTime: 4.1)] }
        XCTAssertTrue(model.pauseRanges.isEmpty)
        model.mutate { $0.clickEvents = [] ; $0.keystrokes = [VideoKeystrokeEvent(time: 3.2, keys: ["⌘", "S"])] }
        XCTAssertTrue(model.pauseRanges.isEmpty, "a shortcut counts as activity too")
    }

    // MARK: Cuts follow the sound, not the recognizer's times

    /// A 50 Hz waveform: loud where something is said, a quiet room elsewhere.
    private static func waveform(_ sounds: [(Double, Double)], seconds: Double = 8) -> VideoWaveform {
        let rate = VideoWaveform.bucketsPerSecond
        var peaks = [Float](repeating: 0.004, count: Int(seconds * rate))
        for (start, end) in sounds {
            for index in Int((start * rate).rounded())..<min(Int((end * rate).rounded()), peaks.count) { peaks[index] = 0.6 }
        }
        return VideoWaveform(peaks: peaks)
    }

    private static func transcript(_ timed: [(String, Double, Double)]) -> [VideoTranscriptWord] {
        VideoTranscript.words(from: VideoCaptionBuilder.lines(from: timed.map { VideoCaptionWord(text: $0.0, start: $0.1, end: $0.2) }), language: "en")
    }

    /// Measured on real transcription: "uh" reported 80 ms late and 0.2 s
    /// long, so a cut by its times took the start of "we". The cut now
    /// takes the "uh" itself and stops before "we".
    func testFillerCutFollowsItsSoundNotItsLateTime() throws {
        let words = Self.transcript([("First,", 3.22, 3.90), ("ah,", 3.90, 4.26), ("we", 4.26, 4.32), ("open", 4.32, 4.50), ("the", 4.50, 4.74), ("app.", 4.74, 5.16)])
        let sound = Self.waveform([(3.16, 3.74), (3.82, 3.98), (4.10, 4.94)])
        let timed = try XCTUnwrap(VideoTranscript.cutRange(words: words, run: 1...1, sound: nil))
        XCTAssertGreaterThan(timed.upperBound, 4.2, "by the recognizer's times the cut runs into \"we\"")
        let cut = try XCTUnwrap(VideoTranscript.fillerCuts(words: words, sound: sound) { _ in true }.first?.range)
        XCTAssertLessThanOrEqual(cut.lowerBound, 3.82)
        XCTAssertGreaterThanOrEqual(cut.upperBound, 3.98, "all of the uh")
        XCTAssertGreaterThanOrEqual(cut.lowerBound, 3.74, "none of First")
        XCTAssertLessThanOrEqual(cut.upperBound, 4.10, "none of we")
    }

    /// Over room noise the recognizer stretched "um" back over half of
    /// "Okay" (whose "k" is a short silence of its own). The cut takes only
    /// the stretch of sound nearest the um's middle.
    func testFillerTimedOverItsNeighbourKeepsTheNeighbour() throws {
        let words = Self.transcript([("Okay", 0.47, 0.66), ("um,", 0.66, 1.68), ("let's", 1.68, 2.04), ("record", 2.04, 2.16)])
        let sound = Self.waveform([(0.50, 0.64), (0.66, 1.06), (1.14, 1.50), (1.58, 2.90)])
        let cut = try XCTUnwrap(VideoTranscript.fillerCuts(words: words, sound: sound) { _ in true }.first?.range)
        XCTAssertLessThanOrEqual(cut.lowerBound, 1.14)
        XCTAssertGreaterThanOrEqual(cut.upperBound, 1.50)
        XCTAssertGreaterThanOrEqual(cut.lowerBound, 1.06, "none of Okay")
        XCTAssertLessThanOrEqual(cut.upperBound, 1.58, "none of let's")
    }

    /// The recognizer put "ah" past its sound, onto the next word's: it
    /// takes the stretch left over between First and we.
    func testFillerTimedPastItsSoundFindsIt() throws {
        let words = Self.transcript([("First,", 3.22, 3.96), ("ah,", 3.96, 4.26), ("we", 4.26, 4.32), ("open", 4.32, 4.50)])
        let sound = Self.waveform([(3.24, 3.56), (3.70, 3.72), (3.82, 3.98), (4.10, 4.94)])
        let cut = try XCTUnwrap(VideoTranscript.fillerCuts(words: words, sound: sound) { _ in true }.first?.range)
        XCTAssertLessThanOrEqual(cut.lowerBound, 3.82)
        XCTAssertGreaterThanOrEqual(cut.upperBound, 3.98)
        XCTAssertGreaterThanOrEqual(cut.lowerBound, 3.72)
        XCTAssertLessThanOrEqual(cut.upperBound, 4.10, "none of we")
    }

    /// Words said without a break between them: the cut stays where the
    /// words put it (no stretch of sound is the word's alone).
    func testWordInRunningSpeechStaysNearItsTime() throws {
        let words = Self.transcript([("open", 1.0, 1.4), ("the", 1.4, 1.6), ("settings", 1.6, 2.2)])
        let sound = Self.waveform([(1.0, 2.2)])
        let cut = try XCTUnwrap(VideoTranscript.cutRange(words: words, run: 1...1, sound: sound))
        XCTAssertGreaterThanOrEqual(cut.lowerBound, 1.4 - 0.1)
        XCTAssertLessThanOrEqual(cut.upperBound, 1.6)
    }

    /// Shortening a pause never takes sound, even from a word timed early.
    func testShortenedPauseKeepsTheWordsSound() throws {
        let words = Self.transcript([("settings.", 1.85, 2.40), ("Then,", 5.40, 5.80)])
        let sound = Self.waveform([(1.85, 2.75), (5.20, 5.80)])
        let pause = try XCTUnwrap(VideoTranscript.pauseRanges(words: words, busy: [], sound: sound) { _ in true }.first)
        XCTAssertGreaterThanOrEqual(pause.lowerBound, 2.75, "settings ran on past its time")
        XCTAssertLessThanOrEqual(pause.upperBound, 5.20)
    }

    /// In the editor: the um is cut by its sound, the transcript shows it
    /// cut (its time moved onto what was cut), and it comes back exactly.
    func testRemoveFillersFollowsTheSoundAndRestores() async throws {
        // "um" reported 0.2 s late: by its times its middle is past its sound.
        let model = try await makeModel(spoken: [("So,", 0.5, 0.8), ("um,", 1.0, 1.4), ("open", 1.4, 1.7), ("the", 1.7, 1.85), ("settings.", 1.85, 2.4)])
        model.applyTimelineMedia(thumbnails: [], waveform: Self.waveform([(0.45, 0.70), (0.78, 1.05), (1.25, 2.30)]))
        let before = model.timelineDuration
        model.removeFillers()
        XCTAssertEqual(model.fillerCount, 0)
        let words = model.transcriptWords
        XCTAssertFalse(model.isIncluded(words[1]), "the transcript shows the um cut")
        XCTAssertTrue(model.isIncluded(words[0]))
        XCTAssertTrue(model.isIncluded(words[2]))
        XCTAssertTrue(model.isIncluded(sourceTime: 1.25), "open starts where its sound does")
        XCTAssertFalse(model.isIncluded(sourceTime: 0.9), "the um's sound is gone")
        model.restoreWords(IndexSet(integer: 1))
        XCTAssertEqual(model.timelineDuration, before, accuracy: 0.02)
        XCTAssertTrue(model.isIncluded(sourceTime: 0.9))
    }

    private final class Host: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func testTranscriptEditorCutsWithDelete() async throws {
        let model = try await makeModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = Host(rootView: AnyView(VideoTranscriptPanel(model: model, timeline: model.timelineState).frame(width: 320, height: 500)))
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 300_000_000)
        func findTextView(_ view: NSView) -> TranscriptTextView? {
            if let text = view as? TranscriptTextView { return text }
            for sub in view.subviews { if let found = findTextView(sub) { return found } }
            return nil
        }
        let textView = try XCTUnwrap(findTextView(host))
        let string = textView.string
        print("TRANSCRIPT TEXT: \(string.replacingOccurrences(of: "\n", with: " ⏎ "))")
        XCTAssertTrue(string.contains("settings."))
        XCTAssertTrue(string.contains("⏸"), "the 3 s silence shows as a pause token")

        // Select "open the" and press Delete.
        let range = (string as NSString).range(of: "open the")
        textView.setSelectedRange(range)
        window.makeFirstResponder(textView)
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        textView.keyDown(with: delete)
        let words = model.transcriptWords
        XCTAssertFalse(model.isIncluded(words[2]))
        XCTAssertFalse(model.isIncluded(words[3]))
        try await Task.sleep(nanoseconds: 300_000_000)
        // The text now shows them struck through.
        let storage = try XCTUnwrap(textView.textStorage)
        let struck = (textView.string as NSString).range(of: "open")
        let style = storage.attribute(.strikethroughStyle, at: struck.location, effectiveRange: nil) as? Int
        XCTAssertEqual(style, NSUnderlineStyle.single.rawValue)

        // Delete again on the struck words restores them.
        textView.setSelectedRange((textView.string as NSString).range(of: "open the"))
        textView.keyDown(with: delete)
        XCTAssertTrue(model.isIncluded(words[2]))

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-transcript.png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT: \(url.path)")
        window.orderOut(nil)
    }
}
