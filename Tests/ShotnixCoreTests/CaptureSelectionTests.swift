import AppKit
import XCTest
@testable import ShotnixCore

/// The area-selection overlay, driven by synthesized mouse and key events:
/// capture on release by default, the adjustable stage (⇧ at release, or
/// the setting off), handles, moving, nudging, and the display clamp.
@MainActor
final class CaptureSelectionTests: XCTestCase {

    private var window: NSWindow!
    private var view: SelectionOverlayView!
    private var captured: [CGRect] = []
    private var cancelled = 0

    override func setUp() async throws {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        view = SelectionOverlayView(mode: .area, frozenImage: nil)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = view
        view.captureImmediately = true
        captured = []
        cancelled = 0
        view.selectionHandler = { [weak self] rect, _ in self?.captured.append(rect) }
        view.cancelHandler = { [weak self] in self?.cancelled += 1 }
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil
        view = nil
    }

    func testReleaseCapturesRightAwayByDefault() {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.size, CGSize(width: 200, height: 150))
        XCTAssertEqual(view.stage, .drawing, "done — the overlay is torn down by its owner")
    }

    func testShiftAtReleaseKeepsTheSelectionAdjustable() {
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250), releaseFlags: [.shift])
        XCTAssertTrue(captured.isEmpty)
        XCTAssertEqual(view.stage, .adjusting)

        press(36) // Return
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.size, CGSize(width: 200, height: 150))
    }

    func testWithTheSettingOffEverySelectionIsAdjustable() {
        view.captureImmediately = false
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        XCTAssertEqual(view.stage, .adjusting)
        XCTAssertTrue(captured.isEmpty)

        press(53) // Esc
        XCTAssertEqual(cancelled, 1)
        XCTAssertTrue(captured.isEmpty)
    }

    func testShiftFlipsTheSettingOffBehaviorToCaptureNow() {
        view.captureImmediately = false
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250), releaseFlags: [.shift])
        XCTAssertEqual(captured.count, 1)
    }

    func testShiftStillHeldFromTheShortcutDoesNotCount() {
        // ⌘⇧4 pressed and ⇧ not yet released when the drag ends.
        view.shiftHeldSinceStart = true
        XCTAssertFalse(view.wantsAdjustStage(releasedWith: [.shift]))
        view.flagsChanged(with: flagsEvent([]))
        XCTAssertTrue(view.wantsAdjustStage(releasedWith: [.shift]), "a fresh ⇧ press counts")
    }

    func testEdgesAndCornersResizeAndTheInsideMoves() {
        enterAdjustStage(CGRect(x: 100, y: 100, width: 200, height: 150))

        drag(from: CGPoint(x: 300, y: 175), to: CGPoint(x: 340, y: 175)) // right edge
        XCTAssertEqual(view.currentRect, CGRect(x: 100, y: 100, width: 240, height: 150))

        drag(from: CGPoint(x: 100, y: 250), to: CGPoint(x: 80, y: 280)) // top-left corner
        XCTAssertEqual(view.currentRect, CGRect(x: 80, y: 100, width: 260, height: 180))

        drag(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 230, y: 180)) // inside: move
        XCTAssertEqual(view.currentRect, CGRect(x: 110, y: 80, width: 260, height: 180))
        XCTAssertEqual(view.stage, .adjusting)
        XCTAssertTrue(captured.isEmpty, "adjusting never captures by itself")
    }

    func testAnEdgeCannotBeDraggedPastTheOppositeOne() {
        enterAdjustStage(CGRect(x: 100, y: 100, width: 200, height: 150))
        drag(from: CGPoint(x: 300, y: 175), to: CGPoint(x: 20, y: 175))
        XCTAssertEqual(view.currentRect.minX, 100)
        XCTAssertEqual(view.currentRect.width, SelectionOverlayView.minimumSize)
    }

    func testArrowKeysNudgeAndOptionArrowsResize() {
        enterAdjustStage(CGRect(x: 100, y: 100, width: 200, height: 150))
        press(124) // →
        XCTAssertEqual(view.currentRect.origin, CGPoint(x: 101, y: 100))
        press(126, flags: [.shift]) // ⇧↑
        XCTAssertEqual(view.currentRect.origin, CGPoint(x: 101, y: 110))
        press(124, flags: [.option]) // ⌥→ widens
        XCTAssertEqual(view.currentRect.size, CGSize(width: 201, height: 150))
        press(125, flags: [.option, .shift]) // ⌥⇧↓ shortens by 10
        XCTAssertEqual(view.currentRect.size, CGSize(width: 201, height: 140))
    }

    func testNudgingStopsAtTheDisplayEdge() {
        enterAdjustStage(CGRect(x: 5, y: 100, width: 200, height: 150))
        press(123, flags: [.shift])
        XCTAssertEqual(view.currentRect.minX, 0)
    }

    func testTheCaptureButtonAndDoubleClickCapture() {
        enterAdjustStage(CGRect(x: 100, y: 200, width: 200, height: 150))
        let button = view.confirmButtonRect(for: view.currentRect)
        click(at: CGPoint(x: button.midX, y: button.midY))
        XCTAssertEqual(captured.count, 1)

        view.resetSelection()
        enterAdjustStage(CGRect(x: 100, y: 200, width: 200, height: 150))
        click(at: CGPoint(x: 200, y: 270), clickCount: 2)
        XCTAssertEqual(captured.count, 2)
    }

    func testAPlainClickBesideTheSelectionKeepsIt() {
        enterAdjustStage(CGRect(x: 100, y: 100, width: 200, height: 150))
        click(at: CGPoint(x: 600, y: 500))
        XCTAssertEqual(view.stage, .adjusting)
        XCTAssertEqual(view.currentRect, CGRect(x: 100, y: 100, width: 200, height: 150))
        XCTAssertEqual(cancelled, 0)
    }

    func testDraggingOutsideTheSelectionStartsANewOne() {
        enterAdjustStage(CGRect(x: 100, y: 100, width: 200, height: 150))
        drag(from: CGPoint(x: 500, y: 300), to: CGPoint(x: 600, y: 420), releaseFlags: [.shift])
        XCTAssertEqual(view.currentRect, CGRect(x: 500, y: 300, width: 100, height: 120))
    }

    /// A selection dragged onto the neighboring display used to come back
    /// partly black: it's limited to the display it started on.
    func testSelectionStaysOnTheDisplayItStartedOn() {
        drag(from: CGPoint(x: 600, y: 400), to: CGPoint(x: 1300, y: 900))
        XCTAssertEqual(captured.count, 1)
        let rect = try? XCTUnwrap(captured.first)
        XCTAssertEqual(rect?.maxX, window.frame.maxX)
        XCTAssertEqual(rect?.maxY, window.frame.maxY)
        XCTAssertEqual(rect?.size, CGSize(width: 200, height: 200))
    }

    func testHintLineExplainsWhatReleaseWillDo() {
        XCTAssertTrue(view.hintText.contains("⇧"))
        XCTAssertTrue(view.hintText.contains("adjust"))
        view.captureImmediately = false
        XCTAssertTrue(view.hintText.contains("capture right away"))
        enterAdjustStage(CGRect(x: 100, y: 100, width: 200, height: 150))
        XCTAssertTrue(view.hintText.contains("Return captures"))
    }

    func testVoiceOverDescribesTheOverlayAndTheSelection() {
        XCTAssertEqual(view.accessibilityRole(), .layoutArea)
        XCTAssertEqual(view.accessibilityLabel(), "Screenshot selection")
        enterAdjustStage(CGRect(x: 100, y: 100, width: 200, height: 150))
        XCTAssertEqual(view.accessibilityValue() as? String, "Selection 200 by 150 points")
    }

    func testRenderAdjustStageSnapshot() throws {
        view.captureImmediately = false
        drag(from: CGPoint(x: 180, y: 160), to: CGPoint(x: 560, y: 420))
        try renderSnapshot(named: "selection-adjust-stage")
    }

    func testRenderIdleHintSnapshot() throws {
        view.mouseMoved(with: mouseEvent(.mouseMoved, at: CGPoint(x: 400, y: 380)))
        try renderSnapshot(named: "selection-idle-hint")
    }

    // MARK: - Events

    private func enterAdjustStage(_ rect: CGRect) {
        view.captureImmediately = false
        drag(from: rect.origin, to: CGPoint(x: rect.maxX, y: rect.maxY))
        XCTAssertEqual(view.stage, .adjusting)
        XCTAssertEqual(view.currentRect, rect)
    }

    private func drag(from start: CGPoint, to end: CGPoint, releaseFlags: NSEvent.ModifierFlags = []) {
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: start))
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: mid))
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: end))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: end, flags: releaseFlags))
    }

    private func click(at point: CGPoint, clickCount: Int = 1) {
        view.mouseDown(with: mouseEvent(.leftMouseDown, at: point, clickCount: clickCount))
        view.mouseUp(with: mouseEvent(.leftMouseUp, at: point, clickCount: clickCount))
    }

    private func press(_ keyCode: UInt16, flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode)!
        view.keyDown(with: event)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags = [], clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
    }

    private func flagsEvent(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
    }

    private func renderSnapshot(named name: String) throws {
        // A backdrop so the dimming and handles read as they do on screen.
        let backdrop = NSImageView(frame: view.bounds)
        backdrop.image = NSImage(size: view.bounds.size, flipped: false) { rect in
            NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: rect, angle: 35)
            NSColor.white.withAlphaComponent(0.9).setFill()
            for row in 0..<12 {
                NSBezierPath(roundedRect: NSRect(x: 60, y: 520 - row * 40, width: 420 - row * 12, height: 14), xRadius: 4, yRadius: 4).fill()
            }
            return true
        }
        let container = NSView(frame: view.bounds)
        container.addSubview(backdrop)
        view.removeFromSuperview()
        container.addSubview(view)
        window.contentView = container

        let rep = try XCTUnwrap(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-capture-snapshots/\(name).png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT-SELECTION: \(url.path)")
    }
}
