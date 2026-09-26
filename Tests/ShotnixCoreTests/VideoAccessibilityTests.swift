import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// The keyboard and VoiceOver reach everything on the timeline: ⌥← / ⌥→
/// select what's there (announcing it), and every kind of item has a spoken
/// description — the one the timeline's drawn chips and blocks give
/// VoiceOver. (The accessibility tree itself can't be read in a test: the
/// test runner doesn't serve the accessibility API.)
@MainActor
final class VideoAccessibilityTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-ax-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory {
            VideoDemoDraftStore.delete(for: directory.appendingPathComponent("rec.mp4"))
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private typealias T = VideoEditorTestModel

    func testOptionArrowsStepThroughTheTimeline() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 10, pointer: false))
        let zoom = try XCTUnwrap(model.addZoom(at: 1.2, length: 1))
        model.seek(to: 4)
        model.addOverlay(.text)
        let text = try XCTUnwrap(model.selectedOverlay?.id)
        model.mutate { $0.captions = [VideoCaptionLine(start: 7, end: 8, text: "Hello")] }
        let caption = try XCTUnwrap(model.project.captions.first?.id)
        model.selection = .none
        model.seek(to: 0.5)

        XCTAssertTrue(model.handleKey(T.key("", code: 124, modifiers: [.option])))
        XCTAssertEqual(model.selection, .zoom(zoom), "the first thing after the playhead")
        XCTAssertEqual(model.clock.time, model.timelineSpan(of: .zoom(zoom))?.start ?? -1, accuracy: 0.01, "with the playhead on it")
        XCTAssertTrue(model.handleKey(T.key("", code: 124, modifiers: [.option])))
        XCTAssertEqual(model.selection, .overlay(text), "then the annotation — no mouse needed")
        XCTAssertTrue(model.handleKey(T.key("", code: 124, modifiers: [.option])))
        XCTAssertEqual(model.selection, .caption(caption))
        XCTAssertTrue(model.handleKey(T.key("", code: 123, modifiers: [.option])))
        XCTAssertEqual(model.selection, .overlay(text), "and back")
        // Plain arrows still step frames.
        let time = model.clock.time
        XCTAssertTrue(model.handleKey(T.key("", code: 124)))
        XCTAssertGreaterThan(model.clock.time, time)
    }

    func testEveryKindOfItemHasASpokenDescription() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 10, pointer: false))
        let zoom = try XCTUnwrap(model.addZoom(at: 1, length: 1))
        model.mutate { project in
            project.captions = [VideoCaptionLine(start: 3, end: 4.5, text: "Hello there")]
            project.keystrokes = [VideoKeystrokeEvent(time: 6, keys: ["⌘", "S"])]
            project.clickEvents = [VideoDemoClickEvent(time: 7, x: 0.5, y: 0.5, button: .left)]
        }
        model.seek(to: 2)
        model.splitAtPlayhead()
        let second = try XCTUnwrap(model.segments.last?.id)
        model.setClipSpeed(second, 2)
        model.setClipMuted(second, true)
        model.seek(to: 4)
        model.addOverlay(.text)
        let text = try XCTUnwrap(model.selectedOverlay?.id)
        let descriptions = [
            model.accessibilityDescription(of: .zoom(zoom)),
            model.accessibilityDescription(of: .caption(model.project.captions[0].id)),
            model.accessibilityDescription(of: .keystroke(model.project.keystrokes[0].id)),
            model.accessibilityDescription(of: .click(model.project.clickEvents[0].id)),
            model.accessibilityDescription(of: .clip(second)),
            model.accessibilityDescription(of: .range(VideoDemoTimelineRange(start: 1, end: 2))),
            model.accessibilityDescription(of: .overlay(text)),
        ]
        print("AX: \(descriptions)")
        XCTAssertTrue(descriptions[0].hasPrefix("Zoom 2×"))
        XCTAssertTrue(descriptions[1].hasPrefix("Caption “Hello there”, 0:"))
        XCTAssertTrue(descriptions[2].hasPrefix("Shortcut ⌘S, at 0:0"))
        XCTAssertTrue(descriptions[3].hasPrefix("Click, at 0:0"))
        XCTAssertEqual(descriptions[4], "Clip 2, 4.0s long, 2× speed, muted, 0:02.0 to 0:06.0")
        XCTAssertEqual(descriptions[5], "Selected part, 0:01.0 to 0:02.0")
        XCTAssertTrue(descriptions[6].hasPrefix("Text “Your text”, 0:04.0 to"))
        XCTAssertEqual(model.timelineItems.count, 7, "zoom, annotation, caption, shortcut, click, two clips")
    }
}
