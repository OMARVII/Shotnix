import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Clicking and dragging annotations right on the preview, with real
/// (synthesized) mouse events in an offscreen window.
@MainActor
final class VideoPreviewInteractionTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
        VideoStageView.drawsStills = true
    }

    override class func tearDown() {
        VideoStageView.drawsStills = false
        super.tearDown()
    }

    private var directory: URL!
    private var window: NSWindow?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-stage-\(UUID().uuidString)", isDirectory: true)
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

    /// The picture fills the view exactly: 640×400 points for a 640×400
    /// recording with no margin, so video-normalized (x, y) is at
    /// (640·x, 400·y).
    private static let size = CGSize(width: 640, height: 400)

    private func makeModel() async throws -> VideoEditorModel {
        let model = try await T.make(in: directory, T.Options(seconds: 6))
        model.mutate { project in
            project.zoomRegions = []
            project.aspectPreset = .source
            project.padding = 0
        }
        model.endGesture()
        model.seek(to: 2)
        return model
    }

    private func mount(_ model: VideoEditorModel) async {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = Host(rootView: AnyView(VideoStageView(model: model).frame(width: Self.size.width, height: Self.size.height)))
        window.orderFrontRegardless()
        self.window = window
        await T.settle(0.3)
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: Self.size.width * x, y: Self.size.height * y) }

    private func send(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) {
        guard let window else { return }
        let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: Self.size.height - point.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        window.sendEvent(event)
    }

    private func click(_ at: CGPoint, clicks: Int = 1) async {
        send(.leftMouseDown, at, clicks: clicks)
        await T.settle(0.04)
        send(.leftMouseUp, at, clicks: clicks)
        await T.settle(0.12)
    }

    private func drag(from start: CGPoint, to end: CGPoint, steps: Int = 8) async {
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

    private func add(_ effect: VideoDemoOverlayEffect) {
        model?.mutate { project in
            project.overlayEffects.append(effect)
            project.overlayEffects = VideoDemoProject.normalizedEffectLayers(project.overlayEffects)
        }
        model?.endGesture()
    }

    private var model: VideoEditorModel?

    func testClickingAnAnnotationSelectsItAndTheRestPlays() async throws {
        let model = try await makeModel()
        self.model = model
        let text = VideoDemoOverlayEffect(kind: .text, time: 1, duration: 3, x: 0.3, y: 0.3, width: 0.3, height: 0.1, text: "Hello")
        add(text)
        model.selection = .none
        await mount(model)

        await click(point(0.3, 0.3))
        XCTAssertEqual(model.selection, .overlay(text.id), "a click on it selects it")
        XCTAssertFalse(model.isPlaying, "and doesn't start playback")

        await click(point(0.8, 0.8))
        XCTAssertEqual(model.selection, .none, "the picture around it deselects")
        await click(point(0.8, 0.8))
        XCTAssertTrue(model.isPlaying, "and with nothing selected, plays")
        model.pause()
        await T.settle(0.2)
        model.seek(to: 2)
        await T.settle(0.2)

        // Double-click: select, then type.
        let requests = model.textEditRequest
        await click(point(0.3, 0.3))
        send(.leftMouseDown, point(0.3, 0.3), clicks: 2)
        await T.settle(0.03)
        send(.leftMouseUp, point(0.3, 0.3), clicks: 2)
        await T.settle(0.15)
        XCTAssertEqual(model.selection, .overlay(text.id))
        XCTAssertEqual(model.textEditRequest, requests + 1, "a double-click puts the cursor in its text")

        // Drag it: 64 × 40 points is a tenth of the frame each way.
        model.selection = .none
        await T.settle(0.1)
        await drag(from: point(0.3, 0.3), to: point(0.4, 0.4))
        let moved = try XCTUnwrap(model.project.overlayEffects.first { $0.id == text.id })
        XCTAssertEqual(moved.x, 0.4, accuracy: 0.01)
        XCTAssertEqual(moved.y, 0.4, accuracy: 0.01)
        XCTAssertEqual(model.selection, .overlay(text.id), "dragging an unselected one picks it up")
        model.undo()
        XCTAssertEqual(model.project.overlayEffects.first { $0.id == text.id }?.x ?? 0, 0.3, accuracy: 0.001, "one undo step")
    }

    func testTheFrontmostAnnotationWinsAndArrowsAreHitOnTheirLine() async throws {
        let model = try await makeModel()
        self.model = model
        let highlight = VideoDemoOverlayEffect(kind: .highlight, time: 1, duration: 3, x: 0.5, y: 0.5, width: 0.4, height: 0.4, layer: 0)
        var label = VideoDemoOverlayEffect(kind: .text, time: 1, duration: 3, x: 0.5, y: 0.5, width: 0.2, height: 0.1, text: "Front", layer: 1)
        label.layer = 1
        var arrow = VideoDemoOverlayEffect(kind: .arrow, time: 1, duration: 3)
        arrow.setArrow(tail: CGPoint(x: 0.9, y: 0.25), head: CGPoint(x: 0.6, y: 0.1))
        // A lane of its own: the lanes are sorted out in ID order, so an
        // arrow asking for lane 0 could push the highlight above the label.
        arrow.layer = 2
        add(highlight)
        add(label)
        add(arrow)
        model.selection = .none
        await mount(model)

        await click(point(0.5, 0.5))
        XCTAssertEqual(model.selection, .overlay(label.id), "the higher lane is in front")
        await click(point(0.35, 0.65))
        XCTAssertEqual(model.selection, .overlay(highlight.id), "the one behind, where only it is")

        model.selection = .none
        await T.settle(0.1)
        await click(point(0.75, 0.175))
        XCTAssertEqual(model.selection, .overlay(arrow.id), "on the arrow's line")
        model.selection = .none
        await T.settle(0.1)
        await click(point(0.62, 0.24))
        XCTAssertNotEqual(model.selection, .overlay(arrow.id), "not the empty corner of its box")
        model.pause()
    }

    func testDraggingAnArrowsHeadPointsItAnywhere() async throws {
        let model = try await makeModel()
        self.model = model
        var arrow = VideoDemoOverlayEffect(kind: .arrow, time: 1, duration: 3)
        arrow.setArrow(tail: CGPoint(x: 0.3, y: 0.6), head: CGPoint(x: 0.5, y: 0.4))
        add(arrow)
        model.selection = .overlay(arrow.id)
        await mount(model)
        // Head from up-right of the tail to down-left of it.
        await drag(from: point(0.5, 0.4), to: point(0.1, 0.8))
        let turned = try XCTUnwrap(model.project.overlayEffects.first { $0.id == arrow.id })
        let points = turned.arrowPoints
        XCTAssertEqual(points.tail.x, 0.3, accuracy: 0.01, "the tail stays")
        XCTAssertEqual(points.tail.y, 0.6, accuracy: 0.01)
        XCTAssertEqual(points.head.x, 0.1, accuracy: 0.01)
        XCTAssertEqual(points.head.y, 0.8, accuracy: 0.01)
        // The box fits the arrow, so it's placed and selected like the rest.
        XCTAssertEqual(turned.x, 0.2, accuracy: 0.01)
        XCTAssertEqual(turned.width, 0.2 + VideoDemoOverlayEffect.arrowPadding * 2, accuracy: 0.01)

        // Moving the box carries the ends.
        model.updateOverlay(arrow.id) { $0.x += 0.1 }
        let shifted = try XCTUnwrap(model.project.overlayEffects.first { $0.id == arrow.id }).arrowPoints
        XCTAssertEqual(shifted.head.x, 0.2, accuracy: 0.001)
        XCTAssertEqual(shifted.tail.x, 0.4, accuracy: 0.001)

        model.flipArrow(arrow.id)
        let flipped = try XCTUnwrap(model.project.overlayEffects.first { $0.id == arrow.id }).arrowPoints
        XCTAssertEqual(flipped.head.x, 0.4, accuracy: 0.001, "turned around")
    }
}
