import AppKit
import XCTest
@testable import ShotnixCore

/// Event-level regression tests for direct manipulation on the annotation
/// canvas: with a drawing tool, grabbing an annotation's outline moves it,
/// while a drag inside a shape draws a new annotation. Select still grabs
/// anywhere inside.
@MainActor
final class AnnotationCanvasInteractionTests: XCTestCase {

    private var window: NSWindow!
    private var canvas: AnnotationCanvas!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "ShotnixCoreTests.AnnotationInteraction.\(UUID().uuidString)"
        Settings.defaults = UserDefaults(suiteName: suiteName)!
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
        UserDefaults().removePersistentDomain(forName: suiteName)
        Settings.defaults = .standard
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

    func testDragInsideRectangleWithRectangleToolDrawsANewRectangle() {
        let rect = RectangleAnnotation(rect: CGRect(x: 50, y: 50, width: 120, height: 80))
        canvas.objects = [rect]
        canvas.activeTool = .rectangle

        drag(from: CGPoint(x: 80, y: 70), to: CGPoint(x: 140, y: 110))

        XCTAssertEqual(rect.rect.origin.x, 50, accuracy: 0.5, "the existing rectangle must not move")
        XCTAssertEqual(rect.rect.origin.y, 50, accuracy: 0.5)
        XCTAssertEqual(canvas.objects.count, 2, "a drag inside a shape draws a new one")
        let drawn = canvas.objects.last as? RectangleAnnotation
        XCTAssertEqual(drawn?.rect ?? .zero, CGRect(x: 80, y: 70, width: 60, height: 40))
    }

    func testDragOnRectangleOutlineWithRectangleToolMovesIt() {
        let rect = RectangleAnnotation(rect: CGRect(x: 50, y: 50, width: 120, height: 80))
        canvas.objects = [rect]
        canvas.activeTool = .rectangle

        // Just inside the left edge
        drag(from: CGPoint(x: 53, y: 90), to: CGPoint(x: 93, y: 120))

        XCTAssertEqual(rect.rect.origin.x, 90, accuracy: 0.5)
        XCTAssertEqual(rect.rect.origin.y, 80, accuracy: 0.5)
        XCTAssertEqual(canvas.objects.count, 1, "grabbing the outline moves the rectangle")
    }

    func testSelectToolStillMovesShapesDraggedFromTheirInterior() {
        let rect = RectangleAnnotation(rect: CGRect(x: 50, y: 50, width: 120, height: 80))
        canvas.objects = [rect]
        canvas.activeTool = .select

        drag(from: CGPoint(x: 110, y: 90), to: CGPoint(x: 150, y: 120))

        XCTAssertEqual(rect.rect.origin.x, 90, accuracy: 0.5)
        XCTAssertEqual(rect.rect.origin.y, 80, accuracy: 0.5)
        XCTAssertEqual(canvas.objects.count, 1)
    }

    func testDragInsideEllipseBlurAndSpotlightDrawsWithDrawingTools() {
        let ellipse = EllipseAnnotation(rect: CGRect(x: 20, y: 20, width: 160, height: 120))
        let blur = BlurAnnotation(rect: CGRect(x: 200, y: 20, width: 180, height: 120))
        let spotlight = SpotlightAnnotation(rect: CGRect(x: 20, y: 160, width: 360, height: 120))
        canvas.objects = [ellipse, blur, spotlight]

        canvas.activeTool = .arrow
        drag(from: CGPoint(x: 100, y: 80), to: CGPoint(x: 130, y: 100))
        XCTAssertTrue(canvas.objects.last is ArrowAnnotation, "drag inside an ellipse draws an arrow")

        canvas.activeTool = .rectangle
        drag(from: CGPoint(x: 260, y: 60), to: CGPoint(x: 320, y: 100))
        XCTAssertTrue(canvas.objects.last is RectangleAnnotation, "drag inside a blur region draws")
        XCTAssertEqual(blur.rect.origin.x, 200, accuracy: 0.5)

        canvas.activeTool = .ellipse
        drag(from: CGPoint(x: 150, y: 200), to: CGPoint(x: 220, y: 250))
        XCTAssertTrue(canvas.objects.last is EllipseAnnotation, "drag inside a spotlight draws")
        XCTAssertEqual(spotlight.rect.origin.y, 160, accuracy: 0.5)
        XCTAssertEqual(ellipse.rect.origin.x, 20, accuracy: 0.5)
        XCTAssertEqual(canvas.objects.count, 6)
    }

    func testDragOnEllipseOutlineMovesIt() {
        let ellipse = EllipseAnnotation(rect: CGRect(x: 20, y: 20, width: 160, height: 120))
        canvas.objects = [ellipse]
        canvas.activeTool = .arrow

        drag(from: CGPoint(x: 100, y: 21), to: CGPoint(x: 110, y: 31)) // top of the outline

        XCTAssertEqual(ellipse.rect.origin.x, 30, accuracy: 0.5)
        XCTAssertEqual(ellipse.rect.origin.y, 30, accuracy: 0.5)
        XCTAssertEqual(canvas.objects.count, 1)
    }

    func testTextLabelsStillGrabAnywhereWithDrawingTools() {
        let text = TextAnnotation(origin: CGPoint(x: 80, y: 80))
        text.text = "Label"
        canvas.objects = [text]
        canvas.activeTool = .arrow

        drag(from: CGPoint(x: 90, y: 90), to: CGPoint(x: 120, y: 110))

        XCTAssertEqual(text.origin.x, 110, accuracy: 0.5)
        XCTAssertEqual(canvas.objects.count, 1, "text is solid: dragging it moves it")
    }

    func testFreehandStrokeOnlyGrabsNearTheStroke() {
        let scribble = FreehandAnnotation()
        scribble.points = [CGPoint(x: 50, y: 50), CGPoint(x: 250, y: 50), CGPoint(x: 250, y: 250)]
        canvas.objects = [scribble]
        canvas.activeTool = .rectangle

        // Inside the scribble's bounding box, far from its stroke
        drag(from: CGPoint(x: 100, y: 150), to: CGPoint(x: 150, y: 200))
        XCTAssertEqual(canvas.objects.count, 2, "empty space inside a scribble's box draws")

        drag(from: CGPoint(x: 150, y: 51), to: CGPoint(x: 160, y: 61))
        XCTAssertEqual(scribble.points[0].x, 60, accuracy: 0.5, "the stroke itself grabs")
    }

    func testDrawingStillWorksOnEmptyCanvasArea() {
        let rect = RectangleAnnotation(rect: CGRect(x: 50, y: 50, width: 60, height: 40))
        canvas.objects = [rect]
        canvas.activeTool = .rectangle

        drag(from: CGPoint(x: 250, y: 200), to: CGPoint(x: 320, y: 260))

        XCTAssertEqual(canvas.objects.count, 2, "drag starting on empty space must draw a new object")
        XCTAssertEqual(rect.rect.origin.x, 50, accuracy: 0.5, "existing object must not move")
    }

    func testClickWithoutDragDrawsNothingAndLeavesNoUndoStep() {
        canvas.activeTool = .rectangle
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 100, y: 100)))

        XCTAssertTrue(canvas.objects.isEmpty, "a zero-size rectangle is not an annotation")
        XCTAssertFalse(canvas.canUndo)
        XCTAssertFalse(canvas.hasUnsavedChanges)
    }

    func testTextToolStillPlacesTextOnTopOfShapes() {
        let rect = RectangleAnnotation(rect: CGRect(x: 50, y: 50, width: 120, height: 80))
        canvas.objects = [rect]
        canvas.activeTool = .text

        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 110, y: 90)))

        XCTAssertEqual(rect.rect.origin.x, 50, accuracy: 0.5, "text click inside a shape must not grab the shape")
        XCTAssertNotNil(canvas.textEditor, "the click opens a text editor")
    }

    func testDoubleClickReopensTextAnnotationForEditing() {
        let text = TextAnnotation(origin: CGPoint(x: 80, y: 80))
        text.text = "Hello"
        text.fontSize = 24
        text.color = .systemGreen
        canvas.objects = [text]
        canvas.activeTool = .select

        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 85, y: 85), clickCount: 2))

        XCTAssertTrue(text.isEditing, "annotation hides behind the live editor")
        XCTAssertEqual(canvas.textEditor?.string, "Hello")

        canvas.textEditor?.string = "Hello world"
        canvas.commitTextField()

        XCTAssertNil(canvas.textEditor)
        let restored = canvas.objects.compactMap { $0 as? TextAnnotation }.first
        XCTAssertEqual(restored?.text, "Hello world")
        XCTAssertFalse(restored?.isEditing ?? true)
        XCTAssertEqual(restored?.fontSize ?? 0, 24, accuracy: 0.1, "edited text must keep its original size")
        XCTAssertEqual(restored?.color, .systemGreen, "edited text must keep its original color")
        XCTAssertEqual(canvas.objects.count, 1)
    }

    func testSwitchingToolsCommitsPendingTextFieldImmediately() {
        canvas.activeTool = .text
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        let editor = canvas.textEditor
        XCTAssertNotNil(editor, "text tool click must open a live editor")
        editor?.string = "Note"

        // Switching tools commits the field right away — not on the next
        // canvas click, where the appearing annotation looks like the new
        // tool spawned it.
        canvas.activeTool = .select
        XCTAssertNil(canvas.textEditor)
        XCTAssertTrue(canvas.subviews.compactMap { $0 as? NSTextView }.isEmpty)
        XCTAssertEqual(canvas.objects.compactMap { $0 as? TextAnnotation }.first?.text, "Note")

        let countBefore = canvas.objects.count
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 300, y: 250)))
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 300, y: 250)))
        XCTAssertEqual(canvas.objects.count, countBefore, "clicking with Select must never create anything")
    }

    func testSwitchingToolsDiscardsEmptyPendingTextField() {
        canvas.activeTool = .text
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        XCTAssertNotNil(canvas.textEditor)

        canvas.activeTool = .select
        XCTAssertNil(canvas.textEditor, "empty editor must vanish on tool switch")
        XCTAssertTrue(canvas.objects.isEmpty, "no annotation from an empty field")
        XCTAssertFalse(canvas.canUndo, "an abandoned empty text leaves no undo step")
    }

    func testClickingAwayFromTextOnlyCommitsIt() {
        canvas.activeTool = .text
        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        canvas.textEditor?.string = "First"

        canvas.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 250, y: 200)))

        XCTAssertNil(canvas.textEditor, "the click away commits without opening a second editor")
        XCTAssertEqual(canvas.objects.compactMap { ($0 as? TextAnnotation)?.text }, ["First"])
    }

    func testClickingAwayThroughRealWindowDispatchOnlyCommits() {
        // NSWindow moves focus to the canvas before delivering mouseDown, so
        // the editor commits first; the click must not also start new text.
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFront(nil)
        canvas.activeTool = .text
        dispatch(.leftMouseDown, at: CGPoint(x: 100, y: 100))
        dispatch(.leftMouseUp, at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(window.firstResponder === canvas.textEditor)
        canvas.textEditor?.insertText("Hello", replacementRange: NSRange(location: NSNotFound, length: 0))

        dispatch(.leftMouseDown, at: CGPoint(x: 250, y: 200))
        dispatch(.leftMouseUp, at: CGPoint(x: 250, y: 200))

        XCTAssertNil(canvas.textEditor, "the click away finishes the text without opening another editor")
        XCTAssertEqual(canvas.objects.compactMap { ($0 as? TextAnnotation)?.text }, ["Hello"])

        // The next click places new text as usual.
        dispatch(.leftMouseDown, at: CGPoint(x: 250, y: 200))
        dispatch(.leftMouseUp, at: CGPoint(x: 250, y: 200))
        XCTAssertNotNil(canvas.textEditor)
    }

    // MARK: - Event synthesis

    private func dispatch(_ type: NSEvent.EventType, at viewPoint: CGPoint) {
        window.sendEvent(event(type, at: viewPoint))
    }

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
