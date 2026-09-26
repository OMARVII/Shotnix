import XCTest
@testable import ShotnixCore

/// Shorten Pauses and Speed Up Idle leave the demo alone: shortcuts and
/// bursts of screen changes (typing, scrolling) count as something
/// happening, like the pointer and clicks.
@MainActor
final class VideoActivityTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory {
            VideoDemoDraftStore.delete(for: directory.appendingPathComponent("rec.mp4"))
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private typealias T = VideoEditorTestModel

    func testOnlyBurstsOfScreenChangesCount() {
        // A blinking text cursor (every half second), then typing.
        let blink = stride(from: 1.0, through: 4.0, by: 0.53).map { $0 }
        let typing = stride(from: 6.0, through: 7.0, by: 0.1).map { $0 }
        let busy = VideoTranscript.screenBusyTimes(blink + typing + [9.0])
        XCTAssertEqual(busy.count, typing.count, "the blink and the lone change don't count")
        XCTAssertEqual(busy.first ?? 0, 6.0, accuracy: 0.001)
    }

    /// The pointer rests from 2 s to 11 s; nobody speaks from 2.6 s to 9.4 s.
    private func quietModel(screen: [Double]?, keystrokes: [VideoKeystrokeEvent]? = nil) async throws -> VideoEditorModel {
        var options = T.Options(seconds: 12)
        options.waypoints = [
            .init(x: 0.3, y: 0.3, arrive: 0, click: false),
            .init(x: 0.6, y: 0.6, arrive: 1.5, click: true),
            .init(x: 0.6, y: 0.6, arrive: 11.2, click: false),
            .init(x: 0.3, y: 0.7, arrive: 11.9, click: false),
        ]
        options.screenActivity = screen
        options.keystrokes = keystrokes
        let model = try await T.make(in: directory, options)
        // No hand tremor while resting.
        model.mutate { project in
            project.cursorSamples = project.cursorSamples.map { sample in
                var still = sample
                if sample.time > 2, sample.time < 11 { still.x = 0.6; still.y = 0.6 }
                return still
            }
        }
        let words: [(String, Double, Double)] = [("Open", 1.8, 2.1), ("settings.", 2.15, 2.6), ("Then", 9.4, 9.7), ("save.", 9.75, 10.2)]
        model.mutate { $0.captions = VideoCaptionBuilder.lines(from: words.map { VideoCaptionWord(text: $0.0, start: $0.1, end: $0.2) }) }
        model.endGesture()
        return model
    }

    func testTypingDuringAPauseKeepsIt() async throws {
        // Typing from 5 s to 6.5 s, ten screen changes a second.
        let typing = stride(from: 5.0, through: 6.5, by: 0.1).map { $0 }
        let model = try await quietModel(screen: typing)
        XCTAssertTrue(model.seesScreenChanges)
        XCTAssertTrue(model.pauseRanges.isEmpty, "the pause is the demo: \(model.pauseRanges)")
        // And Speed Up Idle leaves the typing at 1×.
        let idle = model.idleRanges()
        XCTAssertFalse(idle.isEmpty)
        XCTAssertFalse(idle.contains { $0.overlaps(5.0...6.5) }, "\(idle)")
    }

    func testABlinkingCursorDoesntKeepAPause() async throws {
        let blink = stride(from: 3.0, through: 9.0, by: 0.53).map { $0 }
        let model = try await quietModel(screen: blink)
        XCTAssertEqual(model.pauseRanges.count, 1, "nothing really happens on screen")
    }

    func testShortcutsCountForIdleToo() async throws {
        let model = try await quietModel(screen: nil, keystrokes: [VideoKeystrokeEvent(time: 6.8, keys: ["⌘", "S"])])
        XCTAssertFalse(model.seesScreenChanges, "an older recording")
        XCTAssertTrue(model.pauseRanges.isEmpty)
        let idle = model.idleRanges()
        XCTAssertFalse(idle.contains { $0.contains(6.8) }, "the shortcut isn't fast-forwarded: \(idle)")
        XCTAssertEqual(idle.count, 2, "the still stretch splits around it")
    }

    func testOlderRecordingsStillFindIdleStretches() async throws {
        let model = try await quietModel(screen: nil)
        XCTAssertEqual(model.idleRanges().count, 1)
        XCTAssertEqual(model.pauseRanges.count, 1)
        model.speedUpIdle(speed: 8)
        XCTAssertTrue(model.segments.contains { abs($0.clip.normalizedSpeed - 8) < 0.01 })
        XCTAssertTrue(model.notice?.message.contains("check any typing") ?? false, "honest about what it can't see")
    }
}
