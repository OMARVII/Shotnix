import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Selecting something keeps the tabs: its settings sit above the tab,
/// which keeps its place, and ⌫ in the transcript means words.
@MainActor
final class VideoInspectorLayoutTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!
    private var window: NSWindow?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        if let directory {
            VideoDemoDraftStore.delete(for: directory.appendingPathComponent("rec.mp4"))
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private typealias T = VideoEditorTestModel

    private func mount<V: View>(_ view: V, size: CGSize) async -> NSView {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        self.window = window
        await T.settle(0.4)
        return host
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func textView(in view: NSView) -> TranscriptTextView? {
        (view as? TranscriptTextView) ?? view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }

    private func words(_ model: VideoEditorModel) {
        let spoken: [(String, Double, Double)] = [("So,", 0.5, 0.8), ("um,", 0.9, 1.3), ("open", 1.4, 1.7), ("the", 1.7, 1.85), ("settings.", 1.85, 2.4), ("Then,", 5.4, 5.8), ("uh,", 5.9, 6.2), ("save.", 6.3, 6.8)]
        model.mutate { $0.captions = VideoCaptionBuilder.lines(from: spoken.map { VideoCaptionWord(text: $0.0, start: $0.1, end: $0.2) }) }
        model.endGesture()
    }

    func testSelectingKeepsTheTabAndItsPlace() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 8))
        model.inspectorTab = .background
        let host = await mount(VideoInspectorView(model: model), size: CGSize(width: 318, height: 700))
        let tabScroll = try XCTUnwrap(scrollViews(in: host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        tabScroll.contentView.scroll(to: NSPoint(x: 0, y: 180))
        tabScroll.reflectScrolledClipView(tabScroll.contentView)
        let offset = tabScroll.contentView.bounds.minY

        model.selection = .clip(model.segments[0].id)
        await T.settle(0.3)
        XCTAssertTrue(scrollViews(in: host).contains { $0 === tabScroll }, "the tab stays on screen under the clip's settings")
        model.selection = .none
        await T.settle(0.3)
        XCTAssertTrue(scrollViews(in: host).contains { $0 === tabScroll }, "the same list, not a new one")
        XCTAssertEqual(tabScroll.contentView.bounds.minY, offset, accuracy: 1, "scrolled where it was")

        // The transcript isn't rebuilt either.
        words(model)
        model.inspectorTab = .captions
        UserDefaults.standard.set("transcript", forKey: "videoScriptMode")
        await T.settle(0.4)
        let text = try XCTUnwrap(textView(in: host))
        let rebuilds = try XCTUnwrap(text.coordinator).rebuilds
        model.selection = .clip(model.segments[0].id)
        await T.settle(0.3)
        model.selection = .none
        await T.settle(0.3)
        XCTAssertTrue(textView(in: host) === text, "the transcript stays")
        XCTAssertEqual(text.coordinator?.rebuilds, rebuilds)

        model.selection = .clip(model.segments[0].id)
        try await VideoEditorFixesSnapshotTests.render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 760), name: "fix-09-selection-over-tabs")
    }

    func testDeleteInTheTranscriptCutsWordsNotTheSelectedClip() async throws {
        var options = T.Options(seconds: 8)
        options.audio = true
        let model = try await T.make(in: directory, options)
        words(model)
        let host = await mount(VideoTranscriptPanel(model: model, timeline: model.timelineState), size: CGSize(width: 320, height: 500))
        let text = try XCTUnwrap(textView(in: host))
        // A clip was clicked on the timeline, then the transcript.
        model.selection = .clip(model.segments[0].id)
        let before = model.timelineDuration
        let caret = (text.string as NSString).range(of: "open").upperBound
        window?.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: caret, length: 0))
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        text.keyDown(with: delete)
        let all = model.transcriptWords
        XCTAssertFalse(model.isIncluded(all[2]), "the word before the cursor is cut")
        XCTAssertTrue(model.isIncluded(all[3]))
        XCTAssertGreaterThan(model.timelineDuration, before - 1, "not the whole clip")
        XCTAssertEqual(model.segments.count, 2, "the clip is split around the word, not removed")
        // ⌫ again on the cut word puts it back.
        await T.settle(0.2)
        text.setSelectedRange(NSRange(location: (text.string as NSString).range(of: "open").upperBound, length: 0))
        text.keyDown(with: delete)
        XCTAssertTrue(model.isIncluded(model.transcriptWords[2]))
    }
}
