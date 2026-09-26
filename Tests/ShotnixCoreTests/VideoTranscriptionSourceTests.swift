import XCTest
@testable import ShotnixCore

/// What gets transcribed, how progress is reported on older Macs, and how
/// word timings survive a caption edit.
final class VideoTranscriptionSourceTests: XCTestCase {
    private let recording = URL(fileURLWithPath: "/tmp/rec.mp4")
    private let enhanced = URL(fileURLWithPath: "/tmp/voice.m4a")

    func testTheVoiceIsTranscribedOnItsOwn() {
        typealias S = VideoCaptionTranscriber.Source
        func source(_ kinds: [VideoAudioKind], enhanced: URL? = nil) -> S {
            VideoCaptionTranscriber.source(recording: recording, kinds: kinds, enhancedVoice: enhanced, voiceStart: 0.25)
        }
        XCTAssertEqual(source([.microphone, .system]), S(url: recording, trackIndex: 0), "the mic, not the Mac's music")
        XCTAssertEqual(source([.system, .microphone]), S(url: recording, trackIndex: 1))
        XCTAssertEqual(source([.microphone, .system], enhanced: enhanced), S(url: enhanced, trackIndex: 0, offset: 0.25), "the cleaned-up voice, shifted to where the voice track starts")
        XCTAssertEqual(source([.microphone]), S(url: recording, trackIndex: nil))
        XCTAssertEqual(source([.mixed]), S(url: recording, trackIndex: nil), "one unknown track: that track")
        XCTAssertEqual(source([.mixed, .mixed]), S(url: recording, trackIndex: nil), "unknown kinds: everything, mixed")
        XCTAssertEqual(source([.system]), S(url: recording, trackIndex: nil), "only the Mac's sound: that's all there is")
    }

    func testOlderMacsReportHowFarTheyGot() {
        let recognition = LegacyRecognition()
        let log = ProgressLog()
        recognition.onProgress = { log.add($0) }
        recognition.report(3)
        recognition.report(2)
        recognition.report(7.5)
        XCTAssertEqual(log.values, [3, 7.5], "only ever forward")
    }

    private func words(_ spec: [(String, Double, Double)]) -> [VideoCaptionWord] {
        spec.map { VideoCaptionWord(text: $0.0, start: $0.1, end: $0.2) }
    }

    func testEditedCaptionsKeepTheTimingsOfWordsThatStayed() {
        let spoken = words([("So", 0.5, 0.7), ("um,", 0.8, 1.2), ("open", 1.3, 1.6), ("the", 1.65, 1.8), ("settings", 1.85, 2.3), ("panel.", 2.35, 2.8)])
        func retime(_ text: String) -> [VideoCaptionWord] {
            VideoEditorModel.retimedWords(for: text, previous: spoken, start: 0.45, end: 3.1)
        }
        // A deleted filler: every other word keeps its real time.
        let noUm = retime("So open the settings panel.")
        XCTAssertEqual(noUm.map(\.text), ["So", "open", "the", "settings", "panel."])
        XCTAssertEqual(noUm.map(\.start), [0.5, 1.3, 1.65, 1.85, 2.35])
        XCTAssertEqual(noUm.map(\.end), [0.7, 1.6, 1.8, 2.3, 2.8])

        // A corrected word takes the time of the word it replaced;
        // punctuation and case changes don't count as changes.
        let fixed = retime("so um, close the settings panel,")
        XCTAssertEqual(fixed.map(\.text), ["so", "um,", "close", "the", "settings", "panel,"])
        XCTAssertEqual(fixed[2].start, 1.3, accuracy: 0.0001)
        XCTAssertEqual(fixed[2].end, 1.6, accuracy: 0.0001)
        XCTAssertEqual(fixed[5].start, 2.35, accuracy: 0.0001)

        // Two words become three: only they are estimated, inside the time
        // the two took; their neighbours don't move.
        let expanded = retime("So um, open up the whole settings panel.")
        XCTAssertEqual(expanded.map(\.text), ["So", "um,", "open", "up", "the", "whole", "settings", "panel."])
        XCTAssertEqual(expanded[2].start, 1.3, accuracy: 0.0001, "open stayed")
        XCTAssertEqual(expanded[4].start, 1.65, accuracy: 0.0001, "the stayed")
        XCTAssertGreaterThanOrEqual(expanded[3].start, 1.6 - 0.0001, "up fits between open and the")
        XCTAssertLessThanOrEqual(expanded[3].end, 1.65 + 0.0001)
        XCTAssertGreaterThanOrEqual(expanded[5].start, 1.8 - 0.0001, "whole fits between the and settings")
        XCTAssertLessThanOrEqual(expanded[5].end, 1.85 + 0.0001)
        XCTAssertEqual(expanded[6].start, 1.85, accuracy: 0.0001)

        // Everything retyped: spread across what was said, in order.
        let rewritten = retime("A completely different sentence")
        XCTAssertEqual(rewritten.first?.start ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(rewritten.last?.end ?? 0, 2.8, accuracy: 0.0001)
        XCTAssertTrue(zip(rewritten, rewritten.dropFirst()).allSatisfy { $0.end <= $1.start + 0.0001 })

        // A typed line stays typed.
        XCTAssertTrue(VideoEditorModel.retimedWords(for: "Hello", previous: [], start: 0, end: 1).isEmpty)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    var values: [Double] { lock.withLock { stored } }
    func add(_ value: Double) { lock.withLock { stored.append(value) } }
}
