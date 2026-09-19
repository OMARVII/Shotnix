import AppKit
import XCTest
@testable import ShotnixCore

/// Event-level regression tests for direct manipulation on the annotation
/// canvas: clicking an existing annotation with a drawing tool active must
/// grab and move it instead of drawing a new object on top.
@MainActor
final class AnnotationCanvasInteractionTests: XCTestCase {

    private var window: NSWindow!
    private var canvas: AnnotationCanvas!

    override func setUp() async throws {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        canvas = AnnotationCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = canvas
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil
        canvas = nil
    }

    func testHighlightMovesWhenDraggedWithHighlighterToolActive() {
        let highlight = HighlighterAnnotation(start: CGPoint(x: 100, y: 100), end: CGPoint(x: 200, y: 100))
        canvas.objects = [highlight]
        canvas.activeTool = .highlighter

        drag(from: CGPoint(x: 150, y: 100), to: CGPoint(x: 180, y: 140))

        XCTAssertEqual(highlight.startPoint.x, 130, accuracy: 0.5)
        XCTAssertEqual(highlight.startPoint.y, 140, accuracy: 0.5)
        XCTAssertEqual(highlight.endPoint.x, 230, accuracy: 0.5)
        XCTAssertEqual(canvas.objects.count, 1, "must move the highlight, not draw a second one")
        XCTAssertTrue(canvas.selectedObjects.contains(where: { $0.id == highlight.id }))
    }

    func testRectangleMovesWhenDraggedFromItsInteriorWithRectangleToolActive() {
        let rect = RectangleAnnotation(rect: CGRect(x: 50, y: 50, width: 120, height: 80))
        canvas.objects = [rect]
        canvas.activeTool = .rectangle

        drag(from: CGPoint(x: 110, y: 90), to: CGPoint(x: 150, y: 120))

        XCTAssertEqual(rect.rect.origin.x, 90, accuracy: 0.5)
        XCTAssertEqual(rect.rect.origin.y, 80, accuracy: 0.5)
        XCTAssertEqual(canvas.objects.count, 1, "must move the rectangle, not draw a second one")
    }

    func testDrawingStillWorksOnEmptyCanvasArea() {
        let rect = RectangleAnnotation(rect: CGRect(x: 50, y: 50, width: 60, height: 40))
        canvas.objects = [rect]
        canvas.activeTool = .rectangle

        drag(from: CGPoint(x: 250, y: 200), to: CGPoint(x: 320, y: 260))

        XCTAssertEqual(canvas.objects.count, 2, "drag starting on empty space must draw a new object")
        XCTAssertEqual(rect.rect.origin.x, 50, accuracy: 0.5, "existing object must not move")
    }

    func testTextToolStillPlacesTextOnTopOfShapes() {
        let rect = RectangleAnnotation(rect: CGRect(x: 50, y: 50, width: 120, height: 80))
        canvas.objects = [rect]
        canvas.activeTool = .text

        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 110, y: 90)))

        XCTAssertEqual(rect.rect.origin.x, 50, accuracy: 0.5, "text click inside a shape must not grab the shape")
    }

    func testDoubleClickReopensTextAnnotationForEditing() {
        let text = TextAnnotation(origin: CGPoint(x: 80, y: 80))
        text.text = "Hello"
        text.fontSize = 24
        text.color = .systemGreen
        canvas.objects = [text]
        canvas.activeTool = .select

        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 85, y: 85), clickCount: 2))

        XCTAssertTrue(canvas.objects.isEmpty, "annotation must be lifted into a live text field")
        let field = canvas.subviews.compactMap { $0 as? NSTextField }.first
        XCTAssertEqual(field?.stringValue, "Hello")

        field?.stringValue = "Hello world"
        canvas.commitTextField()

        let restored = canvas.objects.compactMap { $0 as? TextAnnotation }.first
        XCTAssertEqual(restored?.text, "Hello world")
        XCTAssertEqual(restored?.fontSize ?? 0, 24, accuracy: 0.1, "edited text must keep its original size")
    }

    // MARK: - Event synthesis

    private func drag(from start: CGPoint, to end: CGPoint) {
        canvas.mouseDown(with: event(.leftMouseDown, at: start))
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        canvas.mouseDragged(with: event(.leftMouseDragged, at: mid))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: end))
        canvas.mouseUp(with: event(.leftMouseUp, at: end))
    }

    private func event(_ type: NSEvent.EventType, at viewPoint: CGPoint, clickCount: Int = 1) -> NSEvent {
        let windowPoint = canvas.convert(viewPoint, to: nil)
        return NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )!
    }
}
