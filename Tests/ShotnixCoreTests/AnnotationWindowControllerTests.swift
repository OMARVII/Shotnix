import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ShotnixCore

/// The editor window around the canvas: window level, closing with unsaved
/// changes, copy feedback, history write-back, and the toolbar.
@MainActor
final class AnnotationWindowControllerTests: XCTestCase {

    private var settings: AnnotationSettingsSandbox!
    private var controllers: [AnnotationWindowController] = []
    private var tempDir: URL?

    override func setUp() async throws {
        settings = AnnotationSettingsSandbox()
    }

    override func tearDown() async throws {
        for controller in controllers {
            controller.unsavedChangesPrompt = { $0(.discard) }
            controller.window?.close()
        }
        controllers = []
        AnnotationWindowController.quitReviewPrompt = nil
        NSColorPanel.shared.orderOut(nil)
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        settings.tearDown()
        settings = nil
    }

    private func makeController(image: NSImage? = nil, historyItem: HistoryItem? = nil, historyManager: HistoryManager? = nil) -> AnnotationWindowController {
        let image = image ?? AnnotationTestImages.solid(.white, pointSize: CGSize(width: 400, height: 260), density: 2)
        let controller = AnnotationWindowController(image: image, historyItem: historyItem, historyManager: historyManager)
        controller.showToast = { _, _ in }
        controllers.append(controller)
        return controller
    }

    private func addRectangle(to canvas: AnnotationCanvas) {
        canvas.activeTool = .rectangle
        let down = mouse(.leftMouseDown, at: CGPoint(x: 20, y: 20), in: canvas)
        canvas.mouseDown(with: down)
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 120, y: 90), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 120, y: 90), in: canvas))
    }

    // MARK: – Item 4: a normal window, with the color panel above it

    func testEditorIsANormalWindowAndTheColorPanelOpensAboveIt() throws {
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.level, .normal, "the editor must not float over every app")

        controller.toolbar.showColorPanel()
        XCTAssertGreaterThan(NSColorPanel.shared.level.rawValue, window.level.rawValue, "Custom… must never open behind the editor")
        NSColorPanel.shared.orderOut(nil)
    }

    // MARK: – Items 2 and 8: closing checks for unsaved changes (⌘W included)

    func testCleanEditorClosesWithoutAsking() throws {
        let controller = makeController()
        var asked = false
        controller.unsavedChangesPrompt = { _ in asked = true }
        XCTAssertTrue(controller.windowShouldClose(try XCTUnwrap(controller.window)))
        XCTAssertFalse(asked)
    }

    func testCommandWAsksBeforeClosingUnsavedWorkAndCloses() throws {
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        addRectangle(to: controller.canvas)
        XCTAssertTrue(controller.canvas.hasUnsavedChanges)
        XCTAssertTrue(window.isDocumentEdited, "the close button shows the unsaved dot")

        var answer: AnnotationWindowController.UnsavedChangesChoice = .cancel
        var prompts = 0
        controller.unsavedChangesPrompt = { resolve in
            prompts += 1
            resolve(answer)
        }
        var closed = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in
            closed = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertTrue(controller.canvas.performKeyEquivalent(with: commandKey("w", kVK_ANSI_W)))
        XCTAssertEqual(prompts, 1, "⌘W asks first")
        XCTAssertFalse(closed, "Cancel keeps the editor open")

        answer = .discard
        _ = controller.canvas.performKeyEquivalent(with: commandKey("w", kVK_ANSI_W))
        XCTAssertEqual(prompts, 2)
        XCTAssertTrue(closed, "Don't Save closes")
    }

    func testCommandWOnANonLatinLayoutClosesTheEditor() throws {
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        var closed = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in
            closed = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = controller.canvas.performKeyEquivalent(with: commandKey("ц", kVK_ANSI_W))
        XCTAssertTrue(closed)
    }

    // MARK: – Quitting with unsaved edits

    private func watchClose(of controller: AnnotationWindowController) throws -> () -> Bool {
        var closed = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: try XCTUnwrap(controller.window), queue: nil) { _ in
            closed = true
        }
        addTeardownBlock { NotificationCenter.default.removeObserver(observer) }
        return { closed }
    }

    func testQuittingWithCleanEditorsGoesAheadWithoutAsking() {
        let controller = makeController()
        var asked = false
        controller.unsavedChangesPrompt = { _ in asked = true }
        var canQuit: Bool?
        AnnotationWindowController.reviewUnsavedChanges(in: [controller]) { canQuit = $0 }
        XCTAssertEqual(canQuit, true)
        XCTAssertFalse(asked)
    }

    func testQuittingAsksAboutUnsavedEditsAndCancelKeepsTheEditor() throws {
        let controller = makeController()
        addRectangle(to: controller.canvas)
        let closed = try watchClose(of: controller)
        var answer: AnnotationWindowController.UnsavedChangesChoice = .cancel
        controller.unsavedChangesPrompt = { $0(answer) }

        var canQuit: Bool?
        AnnotationWindowController.reviewUnsavedChanges(in: [controller]) { canQuit = $0 }
        XCTAssertEqual(canQuit, false, "Cancel stops the quit")
        XCTAssertFalse(closed())

        answer = .discard
        canQuit = nil
        AnnotationWindowController.reviewUnsavedChanges(in: [controller]) { canQuit = $0 }
        XCTAssertEqual(canQuit, true, "Don't Save lets Shotnix quit")
        XCTAssertTrue(closed())
    }

    func testQuittingWithSeveralUnsavedEditorsOffersToReviewOrDiscardThem() throws {
        let first = makeController()
        let second = makeController()
        addRectangle(to: first.canvas)
        addRectangle(to: second.canvas)
        let firstClosed = try watchClose(of: first)
        let secondClosed = try watchClose(of: second)
        var asked: [ObjectIdentifier] = []
        for controller in [first, second] {
            controller.unsavedChangesPrompt = { resolve in
                asked.append(ObjectIdentifier(controller))
                resolve(.discard)
            }
        }
        var counts: [Int] = []
        var choice: AnnotationWindowController.QuitReviewChoice = .cancel
        AnnotationWindowController.quitReviewPrompt = { count in
            counts.append(count)
            return choice
        }

        var canQuit: Bool?
        AnnotationWindowController.reviewUnsavedChanges(in: [first, second]) { canQuit = $0 }
        XCTAssertEqual(counts, [2])
        XCTAssertEqual(canQuit, false)
        XCTAssertFalse(firstClosed() || secondClosed())
        XCTAssertTrue(asked.isEmpty)

        choice = .review
        AnnotationWindowController.reviewUnsavedChanges(in: [first, second]) { canQuit = $0 }
        XCTAssertEqual(asked, [ObjectIdentifier(first), ObjectIdentifier(second)], "each editor asks in turn")
        XCTAssertEqual(canQuit, true)
        XCTAssertTrue(firstClosed() && secondClosed())
    }

    func testQuitReviewSkipsAnEditorSavedWhileAnotherWasAsking() throws {
        let first = makeController()
        let second = makeController()
        addRectangle(to: first.canvas)
        addRectangle(to: second.canvas)
        var asked: [ObjectIdentifier] = []
        first.unsavedChangesPrompt = { resolve in
            asked.append(ObjectIdentifier(first))
            second.canvas.markSaved(revision: second.canvas.documentRevision) // saved meanwhile
            resolve(.discard)
        }
        second.unsavedChangesPrompt = { resolve in
            asked.append(ObjectIdentifier(second))
            resolve(.cancel)
        }
        AnnotationWindowController.quitReviewPrompt = { _ in .review }

        var canQuit: Bool?
        AnnotationWindowController.reviewUnsavedChanges(in: [first, second]) { canQuit = $0 }
        XCTAssertEqual(asked, [ObjectIdentifier(first)], "the saved editor isn't asked about again")
        XCTAssertEqual(canQuit, true)
    }

    func testDiscardingAllUnsavedEditorsClosesThemWithoutAskingEach() throws {
        let first = makeController()
        let second = makeController()
        addRectangle(to: first.canvas)
        addRectangle(to: second.canvas)
        let firstClosed = try watchClose(of: first)
        let secondClosed = try watchClose(of: second)
        var asked = false
        first.unsavedChangesPrompt = { _ in asked = true }
        second.unsavedChangesPrompt = { _ in asked = true }
        AnnotationWindowController.quitReviewPrompt = { _ in .discard }

        var canQuit: Bool?
        AnnotationWindowController.reviewUnsavedChanges(in: [first, second]) { canQuit = $0 }
        XCTAssertEqual(canQuit, true)
        XCTAssertFalse(asked)
        XCTAssertTrue(firstClosed() && secondClosed())
    }

    func testCropAloneCountsAsUnsavedAndASuccessfulCopyClearsIt() throws {
        let controller = makeController()
        let canvas = controller.canvas
        canvas.activeTool = .crop
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 20, y: 20), in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 200, y: 150), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 200, y: 150), in: canvas))
        canvas.applyCrop()
        XCTAssertTrue(canvas.hasUnsavedChanges, "the close warning must fire after a crop")
        XCTAssertTrue(canvas.objects.isEmpty)

        var copied: NSImage?
        controller.copyImage = { image in
            copied = image
            return true
        }
        canvas.onCopyRequested?()
        XCTAssertEqual(copied?.size, NSSize(width: 180, height: 130), "the copy is the cropped screenshot")
        XCTAssertFalse(canvas.hasUnsavedChanges, "nothing left to lose after a copy")
        XCTAssertTrue(controller.windowShouldClose(try XCTUnwrap(controller.window)))
    }

    // MARK: – Item 7: "Copied" only when it was

    func testFailedCopySaysSoAndKeepsTheWorkUnsaved() throws {
        let controller = makeController()
        addRectangle(to: controller.canvas)
        var toasts: [String] = []
        controller.showToast = { message, _ in toasts.append(message) }

        controller.copyImage = { _ in false }
        controller.canvas.onCopyRequested?()
        XCTAssertEqual(toasts.count, 1)
        XCTAssertFalse(toasts[0].contains("Copied"), "a failed copy must not claim success")
        XCTAssertTrue(controller.canvas.hasUnsavedChanges)

        controller.copyImage = { _ in true }
        controller.canvas.onCopyRequested?()
        XCTAssertEqual(toasts.last, "Copied to clipboard")
        XCTAssertFalse(controller.canvas.hasUnsavedChanges)
    }

    func testCopyToClipboardReportsFailureForAnImageWithoutPixels() {
        XCTAssertFalse(ImageExporter.copyToClipboard(image: NSImage()))
    }

    // MARK: – Item 10: saved/copied edits show in history, original kept

    func testCopyingAnEditUpdatesTheHistoryEntryAndKeepsTheOriginal() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ShotnixCoreTests.EditorHistory.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        let manager = HistoryManager(storageDir: dir)
        let capture = AnnotationTestImages.solid(.white, pointSize: CGSize(width: 120, height: 80), density: 2)
        let item = manager.add(image: capture, rect: nil)
        try await waitFor { FileManager.default.fileExists(atPath: item.thumbnailPath) }
        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: item.imagePath))

        let controller = makeController(image: capture, historyItem: item, historyManager: manager)
        controller.copyImage = { _ in true }
        // Unedited: copying doesn't touch history
        controller.canvas.onCopyRequested?()
        XCTAssertFalse(FileManager.default.fileExists(atPath: HistoryManager.originalImagePath(for: item)))

        let rect = RectangleAnnotation(rect: CGRect(x: 10, y: 10, width: 60, height: 40))
        rect.color = .black
        rect.lineWidth = 6
        controller.canvas.objects = [rect]
        controller.canvas.pushUndo()
        controller.canvas.onCopyRequested?()

        let originalPath = HistoryManager.originalImagePath(for: item)
        try await waitFor { FileManager.default.fileExists(atPath: originalPath) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: originalPath)), originalBytes, "the capture is kept as it was")
        try await waitFor {
            (try? Data(contentsOf: URL(fileURLWithPath: item.imagePath))) != originalBytes
        }
        let edited = AnnotationPixels(try XCTUnwrap(NSImage(contentsOfFile: item.imagePath)))
        XCTAssertLessThan(edited.luminance(22, 22), 40, "history now shows the annotated screenshot")
        XCTAssertEqual(manager.items.first?.id, item.id, "same entry, updated in place")

        // Deleting and restoring the entry moves the original with it.
        await manager.waitForPendingFileOperations()
        manager.delete(item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalPath))
        manager.restoreFromTrash(id: item.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalPath))
    }

    // MARK: – Item 9: toolbar accessibility

    func testToolbarControlsAreLabeledForVoiceOver() throws {
        let controller = makeController()
        let toolbar = controller.toolbar
        XCTAssertEqual(toolbar.accessibilityRole(), .toolbar)
        for tool in AnnotationTool.allCases {
            let button = try XCTUnwrap(toolbar.toolButton(for: tool), "\(tool) is in the toolbar")
            XCTAssertEqual(button.accessibilityLabel(), tool.name)
            XCTAssertEqual(button.accessibilityRole(), .radioButton)
        }
        controller.canvas.activeTool = .blur
        XCTAssertEqual(toolbar.toolButton(for: .blur)?.accessibilityValue() as? NSNumber, 1, "the active tool reads as selected")
        XCTAssertEqual(toolbar.toolButton(for: .arrow)?.accessibilityValue() as? NSNumber, 0)
        XCTAssertEqual(toolbar.colorControl?.accessibilityLabel(), "Color")
        XCTAssertEqual(toolbar.colorControl?.accessibilityValue() as? String, AnnotationToolbar.colorName(controller.canvas.activeColor))

        let visible = toolbar.visibleOptionControls.compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(visible.contains("Redaction strength"), "blur shows a labeled strength control: \(visible)")

        controller.canvas.activeTool = .text
        XCTAssertTrue(toolbar.visibleOptionControls.compactMap { $0.accessibilityLabel() }.contains("Text size"))
        XCTAssertTrue(toolbar.visibleOptionControls.compactMap { $0.accessibilityLabel() }.contains("Bold"))
        controller.canvas.activeTool = .rectangle
        XCTAssertTrue(toolbar.visibleOptionControls.compactMap { $0.accessibilityLabel() }.contains("Rounded corners"))
        controller.canvas.activeTool = .crop
        XCTAssertTrue(toolbar.visibleOptionControls.compactMap { $0.accessibilityLabel() }.contains("Apply crop"))
        XCTAssertEqual(controller.window?.title, "Screenshot Editor", "VoiceOver names the window")
    }

    func testToolbarFitsTheMinimumEditorWidth() throws {
        guard let screen = NSScreen.main, screen.visibleFrame.width >= AnnotationToolbar.requiredWidth + 160 else {
            throw XCTSkip("screen too narrow for the full toolbar")
        }
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        XCTAssertGreaterThanOrEqual(window.frame.width, AnnotationToolbar.requiredWidth, "the toolbar isn't clipped")
        XCTAssertEqual(controller.toolbar.frame.width, AnnotationToolbar.requiredWidth)
    }

    // MARK: – Snapshots to look at

    func testRenderEditorWindowSnapshots() throws {
        let image = AnnotationTestImages.document(pointSize: CGSize(width: 900, height: 420), density: 2)
        let controller = makeController(image: image)
        let window = try XCTUnwrap(controller.window)
        window.appearance = NSAppearance(named: .darkAqua)
        let canvas = controller.canvas
        let callout = CalloutAnnotation(origin: CGPoint(x: 420, y: 60), tail: CGPoint(x: 330, y: 120))
        callout.text = "Callout bubble"
        let spotlight = SpotlightAnnotation(rect: CGRect(x: 8, y: 100, width: 330, height: 60))
        canvas.objects = [spotlight, callout]
        canvas.activeTool = .select
        canvas.selectedObjects = [callout]
        let contentView = try XCTUnwrap(window.contentView)
        try AnnotationSnapshots.write(view: contentView, name: "editor-window-callout-selected")

        canvas.selectedObjects = []
        canvas.activeTool = .blur
        try AnnotationSnapshots.write(view: contentView, name: "editor-window-blur-options")

        canvas.activeTool = .text
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 560, y: 300), in: canvas))
        canvas.textEditor?.insertText("Multi-line\ntext", replacementRange: NSRange(location: NSNotFound, length: 0))
        try AnnotationSnapshots.write(view: contentView, name: "editor-window-text-editing")
        canvas.commitTextField()
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 560, y: 220), in: canvas))
        XCTAssertNotNil(canvas.textEditor)
        try AnnotationSnapshots.write(view: contentView, name: "editor-window-text-placeholder")
        canvas.commitTextField()

        canvas.activeTool = .crop
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 60), in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 700, y: 360), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 700, y: 360), in: canvas))
        try AnnotationSnapshots.write(view: contentView, name: "editor-window-crop")
    }

    // MARK: – Helpers

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out")
    }

    private func commandKey(_ characters: String, _ keyCode: Int) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        )!
    }

    private func mouse(_ type: NSEvent.EventType, at viewPoint: CGPoint, in canvas: AnnotationCanvas) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: canvas.convert(viewPoint, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: canvas.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}
