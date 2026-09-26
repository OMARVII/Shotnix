import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ShotnixCore

/// Editing behavior of the annotation canvas: non-destructive crop, undo and
/// dirty state, text, keyboard shortcuts on any layout, the newer tools, and
/// what VoiceOver sees.
@MainActor
final class AnnotationEditingTests: XCTestCase {

    private var settings: AnnotationSettingsSandbox!
    private var window: NSWindow!
    private var canvas: AnnotationCanvas!
    private let imageSize = CGSize(width: 300, height: 200)

    override func setUp() async throws {
        settings = AnnotationSettingsSandbox()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = container
        canvas = AnnotationCanvas(frame: NSRect(origin: .zero, size: imageSize))
        canvas.backgroundImage = AnnotationTestImages.solid(.white, pointSize: imageSize, density: 2)
        container.addSubview(canvas)
        window.makeFirstResponder(canvas)
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil
        canvas = nil
        settings.tearDown()
        settings = nil
    }

    // MARK: – Crop (item 2)

    func testCropKeepsAnnotationsEditableAndIsUndoable() throws {
        let arrow = ArrowAnnotation(start: CGPoint(x: 50, y: 50), end: CGPoint(x: 150, y: 100))
        canvas.objects = [arrow]
        canvas.activeTool = .arrow
        XCTAssertFalse(canvas.hasUnsavedChanges)

        canvas.keyDown(with: key("c", kVK_ANSI_C))
        XCTAssertEqual(canvas.activeTool, .crop)
        drag(from: CGPoint(x: 40, y: 30), to: CGPoint(x: 240, y: 160))
        XCTAssertEqual(canvas.pendingCrop, CGRect(x: 40, y: 30, width: 200, height: 130))
        XCTAssertTrue(canvas.canApplyCrop)

        canvas.keyDown(with: key("\r", kVK_Return))
        XCTAssertEqual(canvas.appliedCrop, CGRect(x: 40, y: 30, width: 200, height: 130), "Return applies the crop")
        XCTAssertEqual(canvas.activeTool, .arrow, "back to the tool used before cropping")
        XCTAssertEqual(canvas.frame.size, CGSize(width: 200, height: 130))
        XCTAssertTrue(canvas.objects.first === arrow, "annotations survive the crop, untouched")
        XCTAssertEqual(arrow.startPoint, CGPoint(x: 50, y: 50))
        XCTAssertTrue(canvas.hasUnsavedChanges, "a crop is an unsaved change")
        let cropped = canvas.flatten()
        XCTAssertEqual(cropped.size, NSSize(width: 200, height: 130))
        XCTAssertEqual(cropped.bestCGImage?.width, 400)

        // The arrow is still editable after cropping: drag it. (View point
        // (60, 45) is image point (100, 75), on the arrow.)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 60, y: 45)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 70, y: 55)))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 70, y: 55)))
        XCTAssertEqual(arrow.startPoint, CGPoint(x: 60, y: 60), "moved in image coordinates")
        canvas.performUndo()

        canvas.performUndo()
        XCTAssertNil(canvas.appliedCrop, "undo restores the whole screenshot")
        XCTAssertEqual(canvas.frame.size, imageSize)
        XCTAssertEqual(canvas.objects.count, 1)
        XCTAssertEqual((canvas.objects.first as? ArrowAnnotation)?.startPoint, CGPoint(x: 50, y: 50))
        XCTAssertFalse(canvas.hasUnsavedChanges, "back at the opened state")

        canvas.performRedo()
        XCTAssertEqual(canvas.appliedCrop, CGRect(x: 40, y: 30, width: 200, height: 130))
        XCTAssertTrue(canvas.hasUnsavedChanges)

        // Re-crop: crop editing shows the whole screenshot around the crop.
        canvas.activeTool = .crop
        XCTAssertEqual(canvas.pendingCrop, canvas.appliedCrop)
        XCTAssertEqual(canvas.frame.size, imageSize)
        canvas.resetCrop()
        XCTAssertTrue(canvas.canApplyCrop)
        canvas.applyCrop()
        XCTAssertNil(canvas.appliedCrop, "reset + apply removes the crop")
        XCTAssertEqual(canvas.frame.size, imageSize)
        canvas.performUndo()
        XCTAssertEqual(canvas.appliedCrop, CGRect(x: 40, y: 30, width: 200, height: 130))
    }

    func testCropCanBeMovedAndResizedBeforeApplying() {
        canvas.activeTool = .crop
        drag(from: CGPoint(x: 40, y: 30), to: CGPoint(x: 140, y: 110))
        drag(from: CGPoint(x: 90, y: 70), to: CGPoint(x: 110, y: 80)) // inside: move
        XCTAssertEqual(canvas.pendingCrop, CGRect(x: 60, y: 40, width: 100, height: 80))
        drag(from: CGPoint(x: 160, y: 120), to: CGPoint(x: 200, y: 150)) // bottom-right handle
        XCTAssertEqual(canvas.pendingCrop, CGRect(x: 60, y: 40, width: 140, height: 110))
        drag(from: CGPoint(x: 200, y: 150), to: CGPoint(x: 500, y: 500)) // clamped to the screenshot
        XCTAssertEqual(canvas.pendingCrop?.maxX, imageSize.width)
        XCTAssertEqual(canvas.pendingCrop?.maxY, imageSize.height)
    }

    func testEscapeLeavesCropEditingWithoutChangingTheCrop() {
        canvas.activeTool = .rectangle
        canvas.activeTool = .crop
        drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100))
        canvas.keyDown(with: key("\u{1b}", kVK_Escape))
        XCTAssertNil(canvas.appliedCrop)
        XCTAssertEqual(canvas.activeTool, .rectangle)
        XCTAssertFalse(canvas.canUndo)
    }

    func testClickInCropModeKeepsTheCropBeingEdited() {
        canvas.activeTool = .crop
        drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100))
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 200, y: 150)))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 200, y: 150)))
        XCTAssertEqual(canvas.pendingCrop, CGRect(x: 10, y: 10, width: 90, height: 90))
    }

    func testDoubleClickInsideTheCropAppliesIt() {
        canvas.activeTool = .crop
        drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 100))
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50), clickCount: 2))
        XCTAssertEqual(canvas.appliedCrop, CGRect(x: 10, y: 10, width: 90, height: 90))
        XCTAssertNotEqual(canvas.activeTool, .crop)
    }

    func testCropSnapsToWholePixels() {
        canvas.activeTool = .crop
        drag(from: CGPoint(x: 10.3, y: 10.8), to: CGPoint(x: 100.1, y: 99.6))
        canvas.applyCrop()
        let crop = try? XCTUnwrap(canvas.appliedCrop)
        for value in [crop?.minX, crop?.minY, crop?.width, crop?.height].compactMap({ $0 }) {
            XCTAssertEqual((value * 2).rounded(), value * 2, "crop edges fall on the 2x pixel grid")
        }
    }

    // MARK: – Dirty state and undo (item 2)

    func testUnsavedChangesFollowSavesUndoAndRedo() {
        canvas.activeTool = .rectangle
        XCTAssertFalse(canvas.hasUnsavedChanges)
        drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 80))
        XCTAssertTrue(canvas.hasUnsavedChanges)

        canvas.markSaved()
        XCTAssertFalse(canvas.hasUnsavedChanges, "a save or copy clears the warning")

        canvas.performUndo()
        XCTAssertTrue(canvas.hasUnsavedChanges, "undoing past the save is a change")
        canvas.performRedo()
        XCTAssertFalse(canvas.hasUnsavedChanges, "redo back to the saved state is clean")

        let revision = canvas.documentRevision
        drag(from: CGPoint(x: 120, y: 120), to: CGPoint(x: 180, y: 180))
        canvas.markSaved(revision: revision)
        XCTAssertTrue(canvas.hasUnsavedChanges, "an export of an older state doesn't clear newer edits")
    }

    func testSliderDragIsOneUndoStep() {
        let rect = RectangleAnnotation(rect: CGRect(x: 20, y: 20, width: 60, height: 60))
        canvas.objects = [rect]
        canvas.selectedObjects = [rect]
        for width in stride(from: 3.0, through: 12.0, by: 1.0) {
            canvas.setActiveLineWidth(CGFloat(width))
        }
        XCTAssertEqual(rect.lineWidth, 12)
        canvas.performUndo()
        XCTAssertEqual((canvas.objects.first as? RectangleAnnotation)?.lineWidth, 2)
        XCTAssertFalse(canvas.canUndo)
    }

    func testBackdropChangesAreUndoableAndNeverMoveAnnotations() {
        let rect = RectangleAnnotation(rect: CGRect(x: 20, y: 20, width: 60, height: 60))
        canvas.objects = [rect]
        var options = ScreenshotBackgroundOptions.editorDefault
        options.isEnabled = true
        options.padding = 40
        canvas.setBackgroundOptions(options)
        XCTAssertEqual(canvas.frame.size, CGSize(width: 380, height: 280))
        XCTAssertEqual(rect.rect.origin, CGPoint(x: 20, y: 20), "annotations live in image coordinates")
        XCTAssertTrue(canvas.hasUnsavedChanges)

        canvas.performUndo()
        XCTAssertFalse(canvas.backgroundOptions.isEnabled)
        XCTAssertEqual(canvas.frame.size, imageSize)
        XCTAssertEqual((canvas.objects.first as? RectangleAnnotation)?.rect.origin, CGPoint(x: 20, y: 20))
    }

    // MARK: – Text (item 11)

    func testReturnAddsALineAndCommandReturnCommits() throws {
        canvas.activeTool = .text
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 60, y: 60)))
        let editor = try XCTUnwrap(canvas.textEditor)
        editor.insertText("First line", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertNotNil(canvas.textEditor, "Return adds a line instead of committing")
        editor.insertText("Second line", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertGreaterThan(editor.frame.height, 40, "the editor grows with its lines")

        XCTAssertTrue(canvas.performKeyEquivalent(with: key("\r", kVK_Return, [.command])))
        XCTAssertNil(canvas.textEditor, "⌘Return commits")
        let text = try XCTUnwrap(canvas.objects.first as? TextAnnotation)
        XCTAssertEqual(text.text, "First line\nSecond line")
        let oneLine = AnnotationText.size(of: "First line", font: text.font).height
        XCTAssertGreaterThan(text.bounds.height, oneLine * 1.8)
        XCTAssertEqual(window.firstResponder, canvas, "keyboard shortcuts work again after committing")
    }

    func testCommittedTextLandsExactlyWhereTheEditorShowedIt() throws {
        canvas.activeColor = .systemRed
        canvas.activeTool = .text
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 60, y: 60)))
        try XCTUnwrap(canvas.textEditor).insertText("Where\nit was", replacementRange: NSRange(location: NSNotFound, length: 0))
        let editing = try XCTUnwrap(redBounds(in: canvas))
        canvas.commitTextField()
        let committed = try XCTUnwrap(redBounds(in: canvas))
        XCTAssertEqual(committed.minX, editing.minX, accuracy: 1.5)
        XCTAssertEqual(committed.minY, editing.minY, accuracy: 1.5)
        XCTAssertEqual(committed.maxX, editing.maxX, accuracy: 1.5)
        XCTAssertEqual(committed.maxY, editing.maxY, accuracy: 1.5)
    }

    func testEmptyEditorFitsItsPlaceholder() throws {
        canvas.activeTool = .text
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 60, y: 60)))
        let editor = try XCTUnwrap(canvas.textEditor as? AnnotationTextEditor)
        let placeholderWidth = (editor.placeholder as NSString).size(withAttributes: [.font: try XCTUnwrap(editor.font)]).width
        XCTAssertGreaterThanOrEqual(editor.frame.width, placeholderWidth)
    }

    /// Bounds (in canvas points) of the red text pixels as the canvas draws
    /// itself, editor included.
    private func redBounds(in view: NSView) -> CGRect? {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let pixels = AnnotationPixels(rep.cgImage!)
        let scale = CGFloat(pixels.width) / view.bounds.width
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let p = pixels.pixel(x, y)
                guard p.r > 180, p.g < 110, p.b < 110 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    func testEscapeAndTabCommitText() throws {
        canvas.activeTool = .text
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 60, y: 60)))
        try XCTUnwrap(canvas.textEditor).insertText("Esc", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.textEditor?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(canvas.textEditor)

        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 60, y: 140)))
        try XCTUnwrap(canvas.textEditor).insertText("Tab", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.textEditor?.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertNil(canvas.textEditor)
        XCTAssertEqual(canvas.objects.compactMap { ($0 as? TextAnnotation)?.text }, ["Esc", "Tab"])
    }

    func testTextSizeAndWeightApplyToSelectionAndNewText() throws {
        let text = TextAnnotation(origin: CGPoint(x: 40, y: 40))
        text.text = "Label"
        canvas.objects = [text]
        canvas.selectedObjects = [text]
        XCTAssertEqual(canvas.toolOptions.context, .text)

        canvas.setActiveFontSize(32)
        canvas.setActiveTextBold(false)
        XCTAssertEqual(text.fontSize, 32)
        XCTAssertFalse(text.isBold)
        XCTAssertEqual(text.font.pointSize, 32)
        XCTAssertFalse(text.font.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(Settings.annotationTextFontSize, 32, "remembered for next time")
        XCTAssertFalse(Settings.annotationTextBold)

        canvas.selectedObjects = []
        canvas.activeTool = .text
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 150, y: 150)))
        try XCTUnwrap(canvas.textEditor).insertText("New", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.commitTextField()
        let new = try XCTUnwrap(canvas.objects.last as? TextAnnotation)
        XCTAssertEqual(new.fontSize, 32)
        XCTAssertFalse(new.isBold)

        canvas.performUndo()
        canvas.performUndo()
        XCTAssertTrue((canvas.objects.first as? TextAnnotation)?.isBold ?? false, "weight change undoes on its own")
    }

    func testStyleChangesWhileTypingApplyToTheTextBeingTyped() throws {
        canvas.activeTool = .text
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 60, y: 60)))
        let editor = try XCTUnwrap(canvas.textEditor)
        editor.insertText("Big", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.setActiveFontSize(48)
        canvas.setActiveColor(.systemBlue)
        XCTAssertEqual(editor.font?.pointSize, 48, "the editor shows the new size live")
        canvas.commitTextField()
        let text = try XCTUnwrap(canvas.objects.first as? TextAnnotation)
        XCTAssertEqual(text.fontSize, 48)
        XCTAssertEqual(text.color, .systemBlue)
        canvas.performUndo()
        XCTAssertTrue(canvas.objects.isEmpty, "creating styled text is a single undo step")
    }

    func testReopenedTextKeepsItsLinesAndUnchangedEditsLeaveNoUndoStep() throws {
        let text = TextAnnotation(origin: CGPoint(x: 40, y: 40))
        text.text = "One\nTwo"
        text.isBold = false
        canvas.objects = [text]
        canvas.activeTool = .select
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 45, y: 45), clickCount: 2))
        XCTAssertEqual(canvas.textEditor?.string, "One\nTwo")
        canvas.commitTextField()
        XCTAssertEqual(text.text, "One\nTwo")
        XCTAssertFalse(text.isBold)
        XCTAssertFalse(canvas.canUndo, "opening and closing without edits isn't an edit")
        XCTAssertFalse(canvas.hasUnsavedChanges)
    }

    func testResizingMultilineTextScalesItsFont() {
        let text = TextAnnotation(origin: CGPoint(x: 40, y: 40))
        text.text = "One\nTwo"
        canvas.objects = [text]
        canvas.activeTool = .select
        canvas.selectedObjects = [text]
        let handle = CGPoint(x: text.bounds.maxX + 4, y: text.bounds.maxY + 4)
        drag(from: handle, to: CGPoint(x: handle.x + 20, y: handle.y + text.bounds.height))
        XCTAssertGreaterThan(text.fontSize, 30)
        XCTAssertEqual(text.text, "One\nTwo")
    }

    func testTypingUndoStaysOutOfTheCanvasUndo() throws {
        canvas.activeTool = .text
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 60, y: 60)))
        let editor = try XCTUnwrap(canvas.textEditor)
        editor.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(window.undoManager?.canUndo ?? false, "keystrokes are undone in the editor, not the window")
        canvas.commitTextField()
        XCTAssertFalse(canvas.undoManager?.canUndo ?? false)
        XCTAssertTrue(canvas.canUndo, "the canvas can undo the new text")
    }

    // MARK: – Keyboard (item 8)

    func testToolShortcutsWorkOnNonLatinLayouts() {
        // Russian layout: the V, A, S, O, H, C keys type м, ф, ы, щ, р, с.
        let cases: [(String, Int, NSEvent.ModifierFlags, AnnotationTool)] = [
            ("м", kVK_ANSI_V, [], .select),
            ("ф", kVK_ANSI_A, [], .arrow),
            ("ы", kVK_ANSI_S, [], .spotlight),
            ("щ", kVK_ANSI_O, [], .callout),
            ("Р", kVK_ANSI_H, [.shift], .freehandHighlighter),
            ("к", kVK_ANSI_R, [], .rectangle),
            ("с", kVK_ANSI_C, [], .crop),
        ]
        for (characters, keyCode, modifiers, tool) in cases {
            canvas.keyDown(with: key(characters, keyCode, modifiers))
            XCTAssertEqual(canvas.activeTool, tool, "\(characters) should select \(tool)")
        }
    }

    func testCommandShortcutsWorkOnNonLatinLayouts() {
        var saves = 0
        var copies = 0
        canvas.onSaveRequested = { saves += 1 }
        canvas.onCopyRequested = { copies += 1 }
        XCTAssertTrue(canvas.performKeyEquivalent(with: key("ы", kVK_ANSI_S, [.command])))
        canvas.keyDown(with: key("с", kVK_ANSI_C, [.command]))
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(copies, 1)

        canvas.activeTool = .rectangle
        drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 80, y: 80))
        canvas.keyDown(with: key("я", kVK_ANSI_Z, [.command]))
        XCTAssertTrue(canvas.objects.isEmpty, "⌘Z on a Russian layout undoes")
    }

    func testLatinLayoutsKeepTheirOwnLetters() {
        // AZERTY: the key typing "a" sits where QWERTY has Q.
        canvas.keyDown(with: key("a", kVK_ANSI_Q))
        XCTAssertEqual(canvas.activeTool, .arrow)
    }

    func testOptionRTogglesRoundedCorners() {
        canvas.activeTool = .arrow
        canvas.keyDown(with: key("®", kVK_ANSI_R, [.option]))
        XCTAssertEqual(canvas.activeTool, .rectangle)
        XCTAssertTrue(canvas.roundedRectangles)
        drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 90))
        let rect = canvas.objects.last as? RectangleAnnotation
        XCTAssertEqual(rect?.cornerRadius, RectangleAnnotation.roundedCornerRadius)

        canvas.keyDown(with: key("®", kVK_ANSI_R, [.option]))
        XCTAssertEqual(rect?.cornerRadius, 0, "applies to the selected rectangle")
        XCTAssertFalse(canvas.roundedRectangles)
        canvas.performUndo()
        XCTAssertEqual((canvas.objects.last as? RectangleAnnotation)?.cornerRadius, RectangleAnnotation.roundedCornerRadius)
    }

    // MARK: – New tools (item 12)

    func testSpotlightToolCreatesSelectsMovesResizesAndUndoes() throws {
        canvas.keyDown(with: key("s", kVK_ANSI_S))
        XCTAssertEqual(canvas.activeTool, .spotlight)
        drag(from: CGPoint(x: 50, y: 40), to: CGPoint(x: 150, y: 120))
        let spotlight = try XCTUnwrap(canvas.objects.last as? SpotlightAnnotation)
        XCTAssertEqual(spotlight.rect, CGRect(x: 50, y: 40, width: 100, height: 80))
        XCTAssertTrue(canvas.selectedObjects.first === spotlight)
        XCTAssertEqual(canvas.toolOptions.context, .spotlight)

        canvas.setSpotlightEllipse(true)
        XCTAssertTrue(spotlight.isEllipse)

        canvas.activeTool = .select
        drag(from: CGPoint(x: 100, y: 80), to: CGPoint(x: 110, y: 90))
        XCTAssertEqual(spotlight.rect.origin, CGPoint(x: 60, y: 50), "Select moves it from inside")
        drag(from: CGPoint(x: 164, y: 134), to: CGPoint(x: 184, y: 144)) // bottom-right handle
        XCTAssertEqual(spotlight.rect.size, CGSize(width: 120, height: 90))

        canvas.performUndo(); canvas.performUndo(); canvas.performUndo(); canvas.performUndo()
        XCTAssertTrue(canvas.objects.isEmpty)
    }

    func testCalloutPointsAtThePressAndOpensForTyping() throws {
        canvas.activeColor = .systemGreen
        canvas.activeTool = .callout
        drag(from: CGPoint(x: 60, y: 150), to: CGPoint(x: 200, y: 60))
        let callout = try XCTUnwrap(canvas.objects.last as? CalloutAnnotation)
        XCTAssertEqual(callout.tail, CGPoint(x: 60, y: 150), "the tail points where the drag started")
        XCTAssertEqual(callout.bubbleRect.midX, 200, accuracy: 1, "the bubble goes where the drag ended")
        XCTAssertEqual(callout.color, .systemGreen)
        let editor = try XCTUnwrap(canvas.textEditor, "a new callout opens for typing")
        editor.insertText("Look here", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(callout.text, "Look here", "the bubble grows while typing")
        canvas.commitTextField()
        XCTAssertEqual(callout.text, "Look here")

        // Aim the tail
        canvas.activeTool = .select
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: callout.bubbleRect.midX, y: callout.bubbleRect.midY)))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: callout.bubbleRect.midX, y: callout.bubbleRect.midY)))
        drag(from: CGPoint(x: 60, y: 150), to: CGPoint(x: 40, y: 180))
        XCTAssertEqual(callout.tail, CGPoint(x: 40, y: 180))
        canvas.performUndo()
        XCTAssertEqual((canvas.objects.last as? CalloutAnnotation)?.tail, CGPoint(x: 60, y: 150))

        // Double-click reopens it
        let bubble = (canvas.objects.last as? CalloutAnnotation)?.bubbleRect ?? .zero
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: bubble.midX, y: bubble.midY), clickCount: 2))
        XCTAssertEqual(canvas.textEditor?.string, "Look here")
        canvas.commitTextField()
    }

    func testEmptyCalloutIsDiscardedWithoutAnUndoStep() {
        canvas.activeTool = .callout
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 60, y: 150)))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 60, y: 150)))
        XCTAssertNotNil(canvas.textEditor)
        canvas.commitTextField()
        XCTAssertTrue(canvas.objects.isEmpty)
        XCTAssertFalse(canvas.canUndo)
    }

    func testCalloutClickPlacesTheBubbleOnTheScreenshot() throws {
        canvas.activeTool = .callout
        // Near the top-right corner: the default up-right placement would leave the screenshot.
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 280, y: 10)))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 280, y: 10)))
        let callout = try XCTUnwrap(canvas.objects.last as? CalloutAnnotation)
        XCTAssertGreaterThanOrEqual(callout.bubbleRect.minY, 0)
        XCTAssertLessThanOrEqual(callout.bubbleRect.maxX, imageSize.width)
        canvas.textEditor?.insertText("Hi", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.commitTextField()
    }

    func testFreehandHighlighterDrawsATranslucentStroke() throws {
        canvas.activeColor = .systemYellow
        canvas.keyDown(with: key("H", kVK_ANSI_H, [.shift]))
        XCTAssertEqual(canvas.activeTool, .freehandHighlighter)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 20, y: 50)))
        for x in stride(from: 30, through: 200, by: 10) {
            canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: CGFloat(x), y: 50 + CGFloat(x % 20))))
        }
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 200, y: 50)))
        let stroke = try XCTUnwrap(canvas.objects.last as? FreehandAnnotation)
        XCTAssertTrue(stroke.isHighlighter)
        XCTAssertEqual(stroke.lineWidth, 16)
        XCTAssertEqual(stroke.color, .systemYellow)
        XCTAssertGreaterThan(stroke.points.count, 10)

        canvas.setActiveColor(.systemPink)
        XCTAssertEqual(stroke.color, .systemPink, "color applies to the selected stroke")
        canvas.performUndo()
        XCTAssertEqual((canvas.objects.last as? FreehandAnnotation)?.color, .systemYellow)
    }

    func testRedactionStrengthAppliesToTheSelectionAndNewRegions() throws {
        canvas.activeTool = .blur
        XCTAssertEqual(canvas.toolOptions.context, .redaction)
        drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 120, y: 80))
        let blur = try XCTUnwrap(canvas.objects.last as? BlurAnnotation)
        XCTAssertEqual(blur.strength, AnnotationRedaction.defaultStrength)
        canvas.setActiveRedactionStrength(30)
        XCTAssertEqual(blur.strength, 30)
        canvas.setActiveRedactionStrength(500)
        XCTAssertEqual(blur.strength, AnnotationRedaction.strengthRange.upperBound, "clamped")

        canvas.activeTool = .pixelate
        canvas.selectedObjects = []
        drag(from: CGPoint(x: 150, y: 20), to: CGPoint(x: 250, y: 80))
        XCTAssertEqual((canvas.objects.last as? PixelateAnnotation)?.strength, AnnotationRedaction.strengthRange.upperBound)
        XCTAssertEqual(Settings.annotationRedactionStrength, Double(AnnotationRedaction.strengthRange.upperBound))
    }

    func testNewToolsHaveShortcutsInTheirTooltips() {
        XCTAssertEqual(AnnotationTool.spotlight.tooltip, "Spotlight (S)")
        XCTAssertEqual(AnnotationTool.callout.tooltip, "Callout (O)")
        XCTAssertEqual(AnnotationTool.freehandHighlighter.tooltip, "Freehand Highlighter (\u{21E7}H)")
        XCTAssertEqual(AnnotationTool.arrow.tooltip, "Arrow (A)")
        for tool in AnnotationTool.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: tool.icon, accessibilityDescription: nil), "\(tool) icon exists")
        }
    }

    func testToolOptionsFollowTheToolAndTheSelection() {
        let expectations: [(AnnotationTool, AnnotationToolOptions.Context)] = [
            (.select, .none), (.arrow, .stroke), (.rectangle, .rectangle), (.filledRectangle, .rectangle),
            (.text, .text), (.callout, .text), (.numberedStep, .none), (.freehandHighlighter, .stroke),
            (.blur, .redaction), (.pixelate, .redaction), (.spotlight, .spotlight), (.crop, .crop),
        ]
        for (tool, context) in expectations {
            canvas.activeTool = tool
            XCTAssertEqual(canvas.toolOptions.context, context, "\(tool)")
        }
        canvas.activeTool = .arrow
        let rect = RectangleAnnotation(rect: CGRect(x: 10, y: 10, width: 50, height: 50))
        rect.lineWidth = 7
        rect.cornerRadius = 12
        canvas.objects = [rect]
        canvas.selectedObjects = [rect]
        XCTAssertEqual(canvas.toolOptions.context, .rectangle, "the selection wins over the tool")
        XCTAssertEqual(canvas.toolOptions.lineWidth, 7)
        XCTAssertTrue(canvas.toolOptions.roundedCorners)
    }

    // MARK: – Accessibility (item 9)

    func testCanvasAndAnnotationsAreExposedToVoiceOver() {
        let text = TextAnnotation(origin: CGPoint(x: 20, y: 20))
        text.text = "Hello"
        let blur = BlurAnnotation(rect: CGRect(x: 100, y: 100, width: 50, height: 30))
        canvas.objects = [text, blur]
        canvas.selectedObjects = [blur]

        XCTAssertTrue(canvas.isAccessibilityElement())
        XCTAssertEqual(canvas.accessibilityRole(), .layoutArea)
        XCTAssertEqual(canvas.accessibilityLabel(), "Screenshot canvas")
        XCTAssertEqual(canvas.accessibilityValue() as? String, "2 annotations, Blurred area selected")
        XCTAssertNotNil(canvas.accessibilityHelp())
        let labels = (canvas.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        XCTAssertEqual(labels, ["Text: Hello", "Blurred area"])
    }

    // MARK: – Helpers

    private func key(_ characters: String, _ keyCode: Int, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        )!
    }

    private func drag(from start: CGPoint, to end: CGPoint) {
        canvas.mouseDown(with: mouse(.leftMouseDown, at: start))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: end))
    }

    private func mouse(_ type: NSEvent.EventType, at viewPoint: CGPoint, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: canvas.convert(viewPoint, to: nil),
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
