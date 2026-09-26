import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// One snapping rule for every bar on the timeline, and annotation lanes
/// that only exist for annotations you can see.
@MainActor
final class VideoTimelineSnappingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!
    private var window: NSWindow?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-snap-\(UUID().uuidString)", isDirectory: true)
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

    func testSnapperLandsTheNearerEdgeWithinReach() {
        let snapper = VideoTimelineSnapper(targets: [5, 1, 9], pointsPerSecond: 100, reach: 8)
        XCTAssertEqual(snapper.snap(5.05).time, 5)
        XCTAssertEqual(snapper.snap(5.05).target, 5)
        XCTAssertEqual(snapper.snap(5.2).time, 5.2, "out of reach")
        XCTAssertNil(snapper.snap(5.2).target)
        // A 2 s bar from 2.96: its start is 0.04 from nothing, its end 0.04 from 5.
        XCTAssertEqual(snapper.shift(start: 2.96, end: 4.96).delta, 0.04, accuracy: 0.0001)
        XCTAssertEqual(snapper.shift(start: 0.97, end: 2.97).delta, 0.03, accuracy: 0.0001, "the start lands on 1")
        XCTAssertEqual(snapper.shift(start: 6, end: 8).delta, 0)
    }

    private final class Host: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// 10 s in a timeline 1000 pt wide: x = 18 + 100·t.
    private static let size = CGSize(width: 1036, height: 360)
    private static let surfaceTop: CGFloat = 45

    private func x(_ time: Double) -> CGFloat { 18 + CGFloat(time) * 100 }

    private func makeModel() async throws -> VideoEditorModel {
        let model = try await T.make(in: directory, T.Options(seconds: 10, pointer: false))
        XCTAssertEqual(model.timelineDuration, 10, accuracy: 0.05)
        return model
    }

    private func mount(_ model: VideoEditorModel) async {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = Host(rootView: AnyView(VideoTimelineView(model: model).frame(width: Self.size.width, height: Self.size.height)))
        window.orderFrontRegardless()
        self.window = window
        await T.settle(0.15)
    }

    private func drag(from start: CGPoint, to end: CGPoint, steps: Int = 10) async {
        guard let window else { return }
        func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: Self.size.height - point.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        send(.leftMouseDown, start)
        await T.settle(0.05)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            send(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            await T.settle(0.03)
        }
        send(.leftMouseUp, end)
        await T.settle(0.15)
    }

    func testAnnotationsAndCaptionsSnapToThePlayheadAndEachOther() async throws {
        let model = try await makeModel()
        model.mutate { project in
            project.overlayEffects = [VideoDemoOverlayEffect(kind: .text, time: 1, duration: 2, x: 0.5, y: 0.5, width: 0.4, height: 0.1, text: "Hi")]
        }
        model.endGesture()
        model.seek(to: 5)
        await mount(model)
        // One annotation lane right under the ruler; drag its start from 1 s
        // to 4.95 s — 5 pt short of the playhead.
        let y = Self.surfaceTop + 31 + 13
        await drag(from: CGPoint(x: x(1.5), y: y), to: CGPoint(x: x(5.45), y: y))
        let moved = try XCTUnwrap(model.project.overlayEffects.first)
        XCTAssertEqual(moved.time, 5, accuracy: 0.001, "lands on the playhead")
        XCTAssertEqual(moved.duration, 2, accuracy: 0.01)

        // A caption's end lands on the annotation's start.
        model.mutate { project in
            project.captions = [VideoCaptionLine(start: 2, end: 3, text: "Hello there")]
        }
        model.endGesture()
        await T.settle(0.2)
        let captionY = Self.surfaceTop + 31 + 11
        await drag(from: CGPoint(x: x(3) - 3, y: captionY), to: CGPoint(x: x(4.94) - 3, y: captionY))
        let line = try XCTUnwrap(model.project.captions.first)
        XCTAssertEqual(line.start, 2, accuracy: 0.01)
        XCTAssertEqual(line.end, 5, accuracy: 0.001, "the caption's edge meets the annotation's")
    }

    func testAnnotationsInsideACutTakeNoLane() async throws {
        let model = try await makeModel()
        let visibleLow = VideoDemoOverlayEffect(kind: .highlight, time: 1, duration: 2, layer: 0)
        let hidden = VideoDemoOverlayEffect(kind: .blur, time: 5.2, duration: 0.5, layer: 1)
        let visibleHigh = VideoDemoOverlayEffect(kind: .text, time: 1.5, duration: 1, text: "Top", layer: 2)
        model.mutate { project in
            project.overlayEffects = [visibleLow, hidden, visibleHigh]
        }
        XCTAssertEqual(VideoTimelineMetrics.overlayLanes(model.project), 3)
        // Cut away the part the blur sits in.
        model.deleteRange(VideoDemoTimelineRange(start: 5, end: 6))
        XCTAssertEqual(model.project.overlayEffects.count, 3, "it's still there (restoring the cut brings it back)")
        XCTAssertEqual(VideoTimelineMetrics.overlayLanes(model.project), 2, "but takes no lane while cut away")
        XCTAssertEqual(VideoTimelineMetrics.overlayLayers(model.project), [0, 2])
        // One lane up from the bottom is the next lane on show.
        XCTAssertEqual(VideoTimelineMetrics.layer(movedFrom: 0, by: 1, in: [0, 2]), 2)
        XCTAssertEqual(VideoTimelineMetrics.layer(movedFrom: 2, by: 1, in: [0, 2]), 3, "above the top: a new lane")
        XCTAssertEqual(VideoTimelineMetrics.layer(movedFrom: 2, by: -1, in: [0, 2]), 0)

        await mount(model)
        let height = VideoTimelineMetrics.contentHeight(model.project)
        let rep = try XCTUnwrap(window?.contentView?.bitmapImageRepForCachingDisplay(in: window!.contentView!.bounds))
        window?.contentView?.cacheDisplay(in: window!.contentView!.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-ux-fixes/fix-12-compact-lanes.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT: \(url.path) (content \(height) pt)")
    }
}
