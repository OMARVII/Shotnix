import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Drives the real SwiftUI timeline with synthesized mouse drags in an
/// offscreen window and checks that objects track the pointer 1:1.
@MainActor
final class VideoTimelineInteractionTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!
    private var window: NSWindow?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-drag-\(UUID().uuidString)", isDirectory: true)
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

    private final class Host: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// 10 s recording in a timeline whose content is exactly 1000 pt wide
    /// (100 pt per second, x = 18 + 100·t).
    private static let size = CGSize(width: 1036, height: 360)
    private static let surfaceTop: CGFloat = 45 // toolbar + hairline

    private func makeModel() async throws -> VideoEditorModel {
        let url = directory.appendingPathComponent("rec.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 640, height: 400), seconds: 10, fps: 30)
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        XCTAssertTrue(model.isReady, model.loadError ?? "not ready")
        XCTAssertEqual(model.timelineDuration, 10, accuracy: 0.05)
        return model
    }

    private func mount(_ model: VideoEditorModel) async {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = Host(rootView: AnyView(VideoTimelineView(model: model).frame(width: Self.size.width, height: Self.size.height)))
        window.orderFrontRegardless()
        self.window = window
        await settle()
    }

    private func settle(_ seconds: Double = 0.15) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func x(_ time: Double) -> CGFloat { 18 + CGFloat(time) * 100 }

    /// Drag in top-left view coordinates, in small steps like a real hand.
    private func drag(from start: CGPoint, to end: CGPoint, steps: Int = 10) async {
        guard let window else { return }
        func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            let location = NSPoint(x: point.x, y: Self.size.height - point.y)
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        send(.leftMouseDown, start)
        await settle(0.05)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            send(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            await settle(0.03)
        }
        send(.leftMouseUp, end)
        await settle()
    }

    func testZoomBlockMovesOneToOne() async throws {
        let model = try await makeModel()
        model.mutate { $0.zoomRegions = [VideoZoomRegion(start: 2, end: 4, scale: 2, followsCursor: false)] }
        await mount(model)
        // Zoom track: ruler 24 + gap 7, block inset 2, 30 tall.
        let y = Self.surfaceTop + 31 + 2 + 15
        await drag(from: CGPoint(x: x(2.8), y: y), to: CGPoint(x: x(4.3), y: y))
        let region = try XCTUnwrap(model.project.zoomRegions.first)
        XCTAssertEqual(region.start, 3.5, accuracy: 0.05, "moved 150 pt = 1.5 s")
        XCTAssertEqual(region.end, 5.5, accuracy: 0.05)

        // Trailing edge resize.
        await drag(from: CGPoint(x: x(5.5) - 4, y: y), to: CGPoint(x: x(6.5) - 4, y: y))
        let resized = try XCTUnwrap(model.project.zoomRegions.first)
        XCTAssertEqual(resized.start, 3.5, accuracy: 0.05)
        XCTAssertEqual(resized.end, 6.5, accuracy: 0.05)
    }

    func testAnnotationMovesOneToOneAndStacksUp() async throws {
        let model = try await makeModel()
        model.mutate { project in
            project.overlayEffects = [VideoDemoOverlayEffect(kind: .text, time: 5, duration: 2, x: 0.5, y: 0.5, width: 0.4, height: 0.1, text: "Hi")]
        }
        await mount(model)
        // One annotation lane right under the ruler.
        let y = Self.surfaceTop + 31 + 13
        await drag(from: CGPoint(x: x(6), y: y), to: CGPoint(x: x(5), y: y))
        let moved = try XCTUnwrap(model.project.overlayEffects.first)
        XCTAssertEqual(moved.time, 4, accuracy: 0.05, "moved 100 pt left = 1 s earlier")
        XCTAssertEqual(moved.duration, 2, accuracy: 0.05)
    }

    func testCaptionChipMovesAndResizes() async throws {
        let model = try await makeModel()
        model.mutate { project in
            project.captions = [VideoCaptionLine(start: 3, end: 5, text: "Hello there", words: [
                VideoCaptionWord(text: "Hello", start: 3.1, end: 3.5),
                VideoCaptionWord(text: "there", start: 3.6, end: 4.2),
            ])]
        }
        await mount(model)
        let y = Self.surfaceTop + 31 + 11
        await drag(from: CGPoint(x: x(4), y: y), to: CGPoint(x: x(4.5), y: y))
        let line = try XCTUnwrap(model.project.captions.first)
        XCTAssertEqual(line.start, 3.5, accuracy: 0.05)
        XCTAssertEqual(line.end, 5.5, accuracy: 0.05)
        XCTAssertEqual(line.words.first?.start ?? 0, 3.6, accuracy: 0.05, "words travel with the line")

        // Leading edge: start later, end stays.
        await drag(from: CGPoint(x: x(3.5) + 4, y: y), to: CGPoint(x: x(4.0) + 4, y: y))
        let trimmed = try XCTUnwrap(model.project.captions.first)
        XCTAssertEqual(trimmed.start, 4.0, accuracy: 0.05)
        XCTAssertEqual(trimmed.end, 5.5, accuracy: 0.05)
    }

    func testClipEndTrimTracksThePointer() async throws {
        let model = try await makeModel()
        await mount(model)
        // Clip track right under the (empty) zoom track: 31 + 34 + 7.
        let y = Self.surfaceTop + 72 + 33
        await drag(from: CGPoint(x: x(10) - 5, y: y), to: CGPoint(x: x(8) - 5, y: y), steps: 16)
        let clip = try XCTUnwrap(model.project.timelineClips.first)
        XCTAssertEqual(clip.sourceEnd, 8, accuracy: 0.06, "200 pt left = 2 s trimmed, even as the timeline shrinks")
        XCTAssertNil(model.layoutDurationLock)
    }
}
