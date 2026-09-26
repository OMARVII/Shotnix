import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Long timelines: zoom far enough in on any length, keep the playhead (or
/// the pointer) in place while zooming, page along while playing, and keep
/// restore markers from piling up.
@MainActor
final class VideoLongTimelineTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!
    private var window: NSWindow?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-longline-\(UUID().uuidString)", isDirectory: true)
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

    private final class Host: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// 10 s in a timeline whose lanes are 1000 pt wide (x = 18 + 100·t at 1×).
    private static let size = CGSize(width: 1036, height: 300)

    private func mount(_ model: VideoEditorModel) async {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = Host(rootView: AnyView(VideoTimelineView(model: model).frame(width: Self.size.width, height: Self.size.height)))
        window.orderFrontRegardless()
        self.window = window
        await T.settle(0.3)
    }

    private func horizontalScrollView() throws -> NSScrollView {
        func all(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { all($0) }
        }
        let views = all(try XCTUnwrap(window?.contentView))
        return try XCTUnwrap(views.first { ($0.documentView?.frame.width ?? 0) > $0.contentSize.width + 50 } ?? views.last)
    }

    func testZoomReachesFrameLevelOnLongTakes() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 10, pointer: false))
        model.timelineViewportWidth = 1000
        XCTAssertEqual(model.maxTimelineZoom, 40, "short takes keep the usual range")
        // What a 30-minute take would get: 150 points a second at the most.
        let perSecond = { (duration: Double) in max(40, duration * 150 / 1000) * 1000 / duration }
        XCTAssertEqual(perSecond(1800), 150, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(perSecond(10), 150)
        model.zoomTimeline(by: 1000)
        XCTAssertEqual(model.timelineZoom, model.maxTimelineZoom)
        model.zoomTimeline(by: 0.0001)
        XCTAssertEqual(model.timelineZoom, 1)
    }

    func testZoomKeepsThePlayheadAndThePointerInPlace() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 10, pointer: false))
        model.seek(to: 7)
        await mount(model)
        let scroll = try horizontalScrollView()
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        // The playhead is 718 pt in; after 4× it stays there on screen.
        model.zoomTimeline(by: 4)
        await T.settle(0.3)
        let playheadX = 18 + 7 * 400.0
        XCTAssertEqual(scroll.contentView.bounds.minX, playheadX - 718, accuracy: 2, "the playhead stays under your eyes")

        // ⌘-scroll or a pinch anchors on the pointer instead: 3 s sits 200
        // pt into the view and stays there.
        model.pendingZoomAnchor = (3, 200)
        model.zoomTimeline(by: 2)
        await T.settle(0.3)
        XCTAssertEqual(scroll.contentView.bounds.minX, 18 + 3 * 800 - 200, accuracy: 2, "the moment under the pointer stays put")
    }

    func testPlaybackPagesAlongUntilYouScroll() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 10, pointer: false))
        await mount(model)
        model.zoomTimeline(by: 4)
        await T.settle(0.3)
        let scroll = try horizontalScrollView()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        model.seek(to: 2.2)
        await T.settle(0.2)
        // The visible strip ends at 2.5 s; playing past it turns the page.
        model.togglePlay()
        for _ in 0..<30 where scroll.contentView.bounds.minX < 1 {
            await T.settle(0.1)
        }
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, 500, "the timeline followed the playhead")

        // Scrolling by hand stops the following.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: NSPoint(x: 100, y: scroll.contentView.bounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        await T.settle(1.2)
        XCTAssertEqual(scroll.contentView.bounds.minX, 100, accuracy: 1, "left where you put it")
        model.pause()
    }

    func testRestoreMarkersGroupWhenTheyCrowd() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 10, pointer: false))
        // Five little cuts close together, one far away.
        let ranges: [ClosedRange<Double>] = [2.0...2.2, 2.4...2.6, 2.8...3.0, 3.2...3.4, 3.6...3.8, 8.0...8.5]
        model.mutate { _ = $0.removeSourceRanges(ranges, totalDuration: 10) }
        model.endGesture()
        let gaps = model.cutGaps
        XCTAssertEqual(gaps.count, 6)
        // At 100 pt a second, markers within 46 pt share one.
        let groups = VideoEditorModel.CutGap.grouped(gaps, within: 0.46)
        XCTAssertEqual(groups.map(\.count), [5, 1])
        // Zoomed in far enough, each has its own again.
        XCTAssertEqual(VideoEditorModel.CutGap.grouped(gaps, within: 0.05).count, 6)

        let before = model.timelineDuration
        model.restore(groups[0])
        XCTAssertEqual(model.timelineDuration, before + 1.0, accuracy: 0.02, "Restore All brings the five back")
        XCTAssertEqual(model.cutGaps.count, 1)
        model.undo()
        XCTAssertEqual(model.cutGaps.count, 6, "in one undo step")
    }
}
