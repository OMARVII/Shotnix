import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Long, heavily cut takes stay responsive: trims don't rebuild the player
/// on every move, the transcript isn't rebuilt for unrelated changes, big
/// recordings preview from smaller frames while moving, and a closed editor
/// is freed.
@MainActor
final class VideoLongTakeTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-longtake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory {
            for name in ["rec.mp4", "long.mp4", "big.mp4"] {
                VideoDemoDraftStore.delete(for: directory.appendingPathComponent(name))
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private typealias T = VideoEditorTestModel

    private func ms(_ label: String, _ work: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        work()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "LONGTAKE: %@ %.2f ms", label, elapsed))
        return elapsed
    }

    func testTrimmingRebuildsThePlayerOnceAtTheEnd() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 6, pointer: false))
        let clip = try XCTUnwrap(model.segments.first?.id)
        let before = model.playback.itemRebuilds
        for step in 1...20 {
            model.trimClip(clip, leading: false, toSource: 6 - Double(step) * 0.1)
        }
        XCTAssertEqual(model.playback.itemRebuilds, before, "no new player item while dragging")
        XCTAssertEqual(model.timelineDuration, 4, accuracy: 0.05, "the timeline follows the drag")
        model.endTrim(clip, leading: false)
        XCTAssertEqual(model.playback.itemRebuilds, before + 1, "one, when the drag ends")
        XCTAssertEqual(model.playback.timelineDuration, 4, accuracy: 0.05, "and it plays the trimmed clip")
    }

    func testForwardCursorMatchesTheClipListSearch() {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/cursor.mp4"), duration: 600, sourceSize: CGSize(width: 640, height: 400))
        project.ensureTimeline(totalDuration: 600)
        let cuts: [ClosedRange<Double>] = (0..<300).map { index in
            let start = Double(index) * 2 + 0.5
            return start...(start + 0.5)
        }
        XCTAssertTrue(project.removeSourceRanges(cuts, totalDuration: 600))
        let segments = project.timelineSegments(totalDuration: 600)
        XCTAssertGreaterThan(segments.count, 290)
        var cursor = SegmentCursor(segments: segments)
        var t = 0.0
        let end = segments.last?.timelineEnd ?? 0
        while t <= end {
            XCTAssertEqual(cursor.sourceTime(forTimelineTime: t), VideoDemoProject.sourceTime(forTimelineTime: t, segments: segments), accuracy: 0.000001)
            t += 0.37
        }
    }

    func testTranscriptIsRebuiltOnlyWhenItsWordsOrCutsChange() async throws {
        var options = T.Options(seconds: 8, pointer: false)
        options.audio = true
        let model = try await T.make(in: directory, options)
        let spoken: [(String, Double, Double)] = [("So,", 0.5, 0.8), ("um,", 0.9, 1.3), ("open", 1.4, 1.7), ("the", 1.7, 1.85), ("settings.", 1.85, 2.4), ("Then,", 5.4, 5.8), ("uh,", 5.9, 6.2), ("save.", 6.3, 6.8)]
        model.mutate { $0.captions = VideoCaptionBuilder.lines(from: spoken.map { VideoCaptionWord(text: $0.0, start: $0.1, end: $0.2) }) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: VideoTranscriptPanel(model: model, timeline: model.timelineState).frame(width: 320, height: 500))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        await T.settle(0.3)
        func textView(_ view: NSView) -> TranscriptTextView? {
            (view as? TranscriptTextView) ?? view.subviews.lazy.compactMap { textView($0) }.first
        }
        let text = try XCTUnwrap(textView(try XCTUnwrap(window.contentView)))
        let coordinator = try XCTUnwrap(text.coordinator)
        let rebuilds = coordinator.rebuilds
        XCTAssertGreaterThan(rebuilds, 0)

        // Zooming the timeline, selecting a clip: nothing to redo.
        model.timelineZoom = 3
        model.selection = .clip(model.segments[0].id)
        await T.settle(0.2)
        XCTAssertEqual(coordinator.rebuilds, rebuilds, "unrelated timeline changes leave the text alone")

        // A cut elsewhere keeps the selected words selected.
        let saveRange = (text.string as NSString).range(of: "save.")
        text.setSelectedRange(saveRange)
        model.cutWords(IndexSet([2, 3]))
        await T.settle(0.2)
        XCTAssertEqual(coordinator.rebuilds, rebuilds + 1)
        XCTAssertEqual((text.string as NSString).substring(with: text.selectedRange()), "save.", "the selection stays on the same words")
    }

    /// 20 minutes, 300 cuts, a transcript of every word: interactive edits
    /// stay well inside a frame.
    func testThreeHundredCutLongTake() async throws {
        let duration = 1200.0
        let url = directory.appendingPathComponent("long.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 320, height: 200), seconds: duration, fps: 1)
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        XCTAssertTrue(model.isReady, model.loadError ?? "")

        var words: [VideoCaptionWord] = []
        var t = 1.0
        var index = 0
        while t < duration - 2 {
            words.append(VideoCaptionWord(text: index % 17 == 0 ? "um" : "word\(index)", start: t, end: t + 0.3))
            t += index % 40 == 39 ? 2.4 : 0.45
            index += 1
        }
        model.mutate { $0.captions = VideoCaptionBuilder.lines(from: words) }
        let cuts = (0..<300).map { i -> ClosedRange<Double> in
            let start = 2 + Double(i) * 3.9
            return start...(start + 0.4)
        }
        let cutAll = ms("300 cuts in one edit") { model.mutate { _ = $0.removeSourceRanges(cuts, totalDuration: duration) } }
        XCTAssertGreaterThan(model.segments.count, 290)
        print("LONGTAKE: \(model.segments.count) clips, \(model.transcriptWords.count) words, \(model.project.captions.count) lines")

        let oneCut = ms("one more cut") { model.deleteRange(VideoDemoTimelineRange(start: 600, end: 601)) }
        let inclusion = ms("is every word still in the video") {
            _ = model.transcriptWords.filter { model.isIncluded($0) }.count
        }
        let cleanup = ms("filler count + pauses") {
            _ = model.fillerCount
            _ = model.pauseRanges
        }
        let snap = ms("snap targets") { _ = model.snapTargets(excluding: []) }

        let clip = model.segments[150].id
        let source = model.segments[150].clip.sourceEnd
        var trims: [Double] = []
        for step in 1...10 {
            trims.append(ms("trim step") { model.trimClip(clip, leading: false, toSource: source - Double(step) * 0.05) })
        }
        model.endTrim(clip, leading: false)
        let trimAverage = trims.reduce(0, +) / Double(trims.count)

        model.setAspect(.vertical)
        let reframe = ms("rebuild with reframing") { model.setStyle { $0.reframe = true; $0.padding = 0.05 } }

        XCTAssertLessThan(inclusion, 30, "a binary search per word")
        XCTAssertLessThan(cleanup, 60)
        XCTAssertLessThan(snap, 30)
        XCTAssertLessThan(trimAverage, 30, "trimming never waits on the player")
        XCTAssertLessThan(oneCut, 400)
        XCTAssertLessThan(reframe, 800)
        _ = cutAll
        model.stop()
    }

    func testBigRecordingsPreviewFromSmallerFramesWhileMoving() async throws {
        let url = directory.appendingPathComponent("big.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 3840, height: 2160), seconds: 2, fps: 10)
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        XCTAssertTrue(model.hasLargeSource)
        XCTAssertFalse(model.previewPrefersSpeed, "paused: full quality")
        XCTAssertFalse(model.playback.usesSmallFrames)

        model.seek(to: 1.0, fast: true)
        XCTAssertTrue(model.previewPrefersSpeed, "scrubbing")
        XCTAssertTrue(model.playback.usesSmallFrames)
        await T.settle(0.5)
        if let frame = model.playback.frame(forHostTime: CACurrentMediaTime()) {
            XCTAssertLessThanOrEqual(CVPixelBufferGetWidth(frame.buffer), Int(VideoPlaybackController.smallFrameWidth), "smaller frames while moving")
        }
        model.seek(to: 1.2)
        XCTAssertFalse(model.previewPrefersSpeed, "released: full quality again")
        XCTAssertFalse(model.playback.usesSmallFrames)
        await T.settle(0.5)
        if let frame = model.playback.frame(forHostTime: CACurrentMediaTime()) {
            XCTAssertEqual(CVPixelBufferGetWidth(frame.buffer), 3840, "the full frame when paused")
        }

        // Draft skips the costly passes: measurably faster on a 4K frame.
        let source = CIImage(cgImage: VideoTestSupport.fakeScreen(size: CGSize(width: 3840, height: 2160), progress: 0.5))
        let renderer = VideoFrameRenderer()
        let context = VideoRenderContext.makeContext()
        let size = CGSize(width: 2400, height: 1350)
        func time(draft: Bool) -> Double {
            var options = VideoFrameRenderer.Options()
            options.draft = draft
            for _ in 0..<3 { _ = context.createCGImage(renderer.render(source: source, timelineTime: 0.5, plan: model.plan, outputSize: size, options: options), from: CGRect(origin: .zero, size: size)) }
            let start = CFAbsoluteTimeGetCurrent()
            for i in 0..<10 { _ = context.createCGImage(renderer.render(source: source, timelineTime: 0.5 + Double(i) * 0.01, plan: model.plan, outputSize: size, options: options), from: CGRect(origin: .zero, size: size)) }
            return (CFAbsoluteTimeGetCurrent() - start) * 100
        }
        // The best of a few runs each, so other work in the process doesn't
        // decide it.
        let full = (0..<3).map { _ in time(draft: false) }.min() ?? 0
        let draft = (0..<3).map { _ in time(draft: true) }.min() ?? 0
        print(String(format: "LONGTAKE: 4K preview frame %.1f ms full, %.1f ms draft", full, draft))
        XCTAssertLessThan(draft, full * 1.05)
        model.stop()
    }

    func testAClosedEditorIsFreed() async throws {
        let url = directory.appendingPathComponent("rec.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 320, height: 200), seconds: 2, fps: 10)
        VideoDemoDraftStore.delete(for: url)
        weak var weakModel: VideoEditorModel?
        weak var weakController: VideoDemoEditorWindowController?
        weak var weakWindow: NSWindow?
        weak var weakHost: NSView?
        do {
            let controller = VideoDemoEditorWindowController(videoURL: url)
            weakController = controller
            weakModel = controller.model
            weakWindow = controller.window
            weakHost = controller.window?.contentView
            controller.window?.orderFrontRegardless()
            for _ in 0..<40 where !(controller.model.isReady) {
                await T.settle(0.05)
            }
            XCTAssertTrue(controller.model.isReady)
            await T.settle(1.5)
            let policy = NSApp.activationPolicy()
            controller.window?.close()
            // Closing an editor syncs the app's Dock presence; keep the test
            // runner's.
            NSApp.setActivationPolicy(policy)
        }
        for _ in 0..<40 where weakModel != nil || weakHost != nil {
            await T.settle(0.1)
        }
        // (AppKit may hold on to a closed NSWindow itself for a while — a
        // plain titled window does too — but not to what was in it.)
        _ = weakWindow
        XCTAssertNil(weakController, "the window controller goes")
        XCTAssertNil(weakHost, "the editor's views go")
        XCTAssertNil(weakModel, "and the editor with its player and monitors")
    }
}
