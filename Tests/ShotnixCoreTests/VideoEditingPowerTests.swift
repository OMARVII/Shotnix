import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Several items at once, clips in any order, speed and sound for part of
/// a clip, undo that says what it undoes — and keeps its history when the
/// editor is closed and opened again.
@MainActor
final class VideoEditingPowerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!
    private var window: NSWindow?

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-power-\(UUID().uuidString)", isDirectory: true)
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

    func testUndoSaysWhatItUndoes() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 6, pointer: false))
        let zoom = try XCTUnwrap(model.addZoom(at: 1))
        model.deleteZoom(zoom)
        XCTAssertEqual(model.undoLabel, "Delete Zoom")
        model.undo()
        XCTAssertEqual(model.notice?.message, "Undo Delete Zoom")
        XCTAssertEqual(model.redoLabel, "Delete Zoom")
        model.redo()
        XCTAssertEqual(model.notice?.message, "Redo Delete Zoom")

        model.seek(to: 2)
        model.splitAtPlayhead()
        XCTAssertEqual(model.undoLabel, "Split")
        model.seek(to: 1)
        model.addOverlay(.text)
        XCTAssertEqual(model.undoLabel, "Add Text")
        if let id = model.selectedOverlay?.id { model.updateOverlay(id) { $0.text = "Hello" } }
        XCTAssertEqual(model.undoLabel, "Edit Text")
        model.deleteRange(VideoDemoTimelineRange(start: 4, end: 5))
        XCTAssertEqual(model.undoLabel, "Cut")
        model.setStyle { $0.padding = 0.2 }
        XCTAssertEqual(model.undoLabel, "Style Change")
    }

    func testUndoHistorySurvivesClosingAndReopening() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 6, pointer: false))
        model.seek(to: 2)
        model.splitAtPlayhead()
        model.deleteRange(VideoDemoTimelineRange(start: 4, end: 5))
        let edited = model.timelineDuration
        model.stop()   // the window closing

        let reopened = VideoEditorModel(videoURL: model.project.sourceURL)
        await reopened.load()
        XCTAssertTrue(reopened.restoredDraft)
        XCTAssertEqual(reopened.timelineDuration, edited, accuracy: 0.01)
        XCTAssertTrue(reopened.canUndo, "⌘Z still steps back")
        XCTAssertEqual(reopened.undoLabel, "Cut")
        reopened.undo()
        XCTAssertEqual(reopened.timelineDuration, 6, accuracy: 0.05)
        reopened.undo()
        XCTAssertEqual(reopened.segments.count, 1, "back to before the split")

        // A draft that changed meanwhile doesn't get someone else's history.
        reopened.stop()
        var other = try XCTUnwrap(VideoDemoDraftStore.load(for: reopened.project.sourceURL)).project
        other.padding = 0.25
        VideoDemoDraftStore.save(other, for: other.sourceURL)
        let changed = VideoEditorModel(videoURL: reopened.project.sourceURL)
        await changed.load()
        XCTAssertFalse(changed.canUndo)
    }

    func testSpeedAndSoundForJustAPart() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 10, pointer: false))
        let range = VideoDemoTimelineRange(start: 2, end: 4)
        model.selection = .range(range)
        model.setRangeSpeed(range, 2)
        XCTAssertEqual(model.timelineDuration, 9, accuracy: 0.02, "2 s at 2× play in 1 s")
        XCTAssertEqual(model.segments.map { $0.clip.normalizedSpeed }, [1, 2, 1])
        guard case .range(let moved) = model.selection else { return XCTFail("the part stays selected") }
        XCTAssertEqual(moved.start, 2, accuracy: 0.02)
        XCTAssertEqual(moved.end, 3, accuracy: 0.02, "on the same material, now shorter")
        XCTAssertEqual(model.rangeSpeed(moved), 2)
        XCTAssertEqual(model.undoLabel, "Speed Change")

        model.toggleRangeMute(moved)
        XCTAssertTrue(model.rangeIsMuted(moved))
        XCTAssertEqual(model.segments.filter(\.clip.muted).count, 1, "only that part")
        model.undo()
        model.undo()
        XCTAssertEqual(model.timelineDuration, 10, accuracy: 0.02)
    }

    func testSeveralItemsDeleteAndMoveTogether() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 10, pointer: false))
        let zoom = try XCTUnwrap(model.addZoom(at: 1, length: 1))
        model.seek(to: 4)
        model.addOverlay(.text)
        let text = try XCTUnwrap(model.selectedOverlay?.id)
        model.mutate { $0.captions = [VideoCaptionLine(start: 6, end: 7, text: "Hi")] }
        let caption = try XCTUnwrap(model.project.captions.first?.id)
        model.selection = .zoom(zoom)
        model.toggleSelection(.overlay(text))
        model.toggleSelection(.caption(caption))
        XCTAssertEqual(model.selectedItems.count, 3)
        XCTAssertTrue(model.isSelected(.overlay(text)))

        // Drag one: they all move by the same amount, as one undo step.
        let before = [VideoEditorModel.Selection.zoom(zoom), .overlay(text), .caption(caption)].map { model.timelineSpan(of: $0)!.start }
        model.beginGroupMove()
        for step in 1...10 { model.moveGroup(by: Double(step) * 0.1) }
        model.endGroupMove()
        let after = [VideoEditorModel.Selection.zoom(zoom), .overlay(text), .caption(caption)].map { model.timelineSpan(of: $0)!.start }
        for (a, b) in zip(before, after) { XCTAssertEqual(b - a, 1, accuracy: 0.02) }
        XCTAssertEqual(model.undoLabel, "Move 3 Items")
        model.undo()
        let undone = [VideoEditorModel.Selection.zoom(zoom), .overlay(text), .caption(caption)].map { model.timelineSpan(of: $0)!.start }
        for (a, b) in zip(before, undone) { XCTAssertEqual(a, b, accuracy: 0.02) }

        // ⇧-clicking one again takes it out; a plain click keeps just one.
        model.selection = .zoom(zoom)
        model.toggleSelection(.overlay(text))
        model.toggleSelection(.overlay(text))
        XCTAssertEqual(model.selectedItems, [.zoom(zoom)])
        model.toggleSelection(.overlay(text))
        model.toggleSelection(.caption(caption))
        XCTAssertTrue(model.handleKey(T.key("\u{7f}", code: 51)))
        XCTAssertTrue(model.project.zoomRegions.isEmpty)
        XCTAssertTrue(model.project.overlayEffects.isEmpty)
        XCTAssertTrue(model.project.captions.isEmpty)
        XCTAssertEqual(model.selection, .none)
        model.undo()
        XCTAssertEqual(model.project.zoomRegions.count, 1, "all back in one step")
        XCTAssertEqual(model.project.overlayEffects.count, 1)
        XCTAssertEqual(model.project.captions.count, 1)
    }

    func testClipsMoveAroundAndStayConsistent() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 9, pointer: false))
        model.seek(to: 3)
        model.splitAtPlayhead()
        model.seek(to: 6)
        model.splitAtPlayhead()
        let ids = model.segments.map(\.id)
        XCTAssertEqual(ids.count, 3)
        model.moveClip(ids[2], toIndex: 0)
        XCTAssertEqual(model.segments.map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertEqual(model.timelineDuration, 9, accuracy: 0.01, "nothing lost")
        XCTAssertEqual(model.segments[0].clip.sourceStart, 6, accuracy: 0.01, "the last part plays first")
        XCTAssertEqual(model.playback.timelineDuration, 9, accuracy: 0.05, "and the player plays that order")
        XCTAssertEqual(model.undoLabel, "Move Clip")

        // Trimming can't grow into material another clip plays.
        model.trimClip(ids[2], leading: true, toSource: 1)
        model.endTrim(ids[2], leading: true)
        XCTAssertEqual(model.segments.first { $0.id == ids[2] }?.clip.sourceStart ?? 0, 6, accuracy: 0.01)

        // Cutting and restoring keeps the new order.
        model.deleteRange(VideoDemoTimelineRange(start: 1, end: 2))
        let gap = try XCTUnwrap(model.cutGaps.first)
        model.restore(gap)
        XCTAssertEqual(model.segments.first?.clip.sourceStart ?? 0, 6, accuracy: 0.01, "still first")
        XCTAssertEqual(model.timelineDuration, 9, accuracy: 0.02)
        model.undo()
        model.undo()
        model.undo()
        XCTAssertEqual(model.segments.map(\.id), ids, "undo puts them back in order")
    }

    private final class Host: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func testDraggingOneOfSeveralMovesThemAll() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 10, pointer: false))
        let first = VideoDemoOverlayEffect(kind: .text, time: 1, duration: 1.5, text: "One", layer: 0)
        let second = VideoDemoOverlayEffect(kind: .highlight, time: 5, duration: 1.5, layer: 0)
        model.mutate { $0.overlayEffects = [first, second] }
        model.endGesture()
        model.selection = .overlay(first.id)
        model.toggleSelection(.overlay(second.id))
        let size = CGSize(width: 1036, height: 300)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = Host(rootView: AnyView(VideoTimelineView(model: model).frame(width: size.width, height: size.height)))
        window.orderFrontRegardless()
        self.window = window
        await T.settle(0.3)
        func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: size.height - point.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        // One annotation lane under the ruler (x = 18 + 100·t): drag the
        // first by 1.2 s.
        let start = CGPoint(x: 18 + 150, y: 45 + 31 + 13)
        send(.leftMouseDown, start)
        await T.settle(0.05)
        for step in 1...10 {
            send(.leftMouseDragged, CGPoint(x: start.x + CGFloat(step) * 12, y: start.y))
            await T.settle(0.03)
        }
        send(.leftMouseUp, CGPoint(x: start.x + 120, y: start.y))
        await T.settle(0.2)
        let moved = model.project.overlayEffects
        XCTAssertEqual(moved.first { $0.id == first.id }?.time ?? 0, 2.2, accuracy: 0.05)
        XCTAssertEqual(moved.first { $0.id == second.id }?.time ?? 0, 6.2, accuracy: 0.05, "the other came along")
        XCTAssertEqual(model.selectedItems.count, 2, "both still selected")
        model.undo()
        XCTAssertEqual(model.project.overlayEffects.first { $0.id == second.id }?.time ?? 0, 5, accuracy: 0.01, "one undo step")
    }

    func testDraggingAClipByItsNameMovesIt() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 10, pointer: false))
        model.seek(to: 5)
        model.splitAtPlayhead()
        model.selection = .none
        let ids = model.segments.map(\.id)
        let size = CGSize(width: 1036, height: 300)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = Host(rootView: AnyView(VideoTimelineView(model: model).frame(width: size.width, height: size.height)))
        window.orderFrontRegardless()
        self.window = window
        await T.settle(0.3)
        func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: size.height - point.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        // The first clip's name chip sits at its top left: x 19 + 5…, and the
        // clip track under the (empty) zoom track: 45 + 72 + 5 + 9.
        let chip = CGPoint(x: 18 + 1 + 5 + 20, y: 45 + 72 + 5 + 9)
        send(.leftMouseDown, chip)
        await T.settle(0.05)
        for step in 1...12 {
            send(.leftMouseDragged, CGPoint(x: chip.x + CGFloat(step) * 55, y: chip.y))
            await T.settle(0.03)
        }
        send(.leftMouseUp, CGPoint(x: chip.x + 660, y: chip.y))
        await T.settle(0.3)
        XCTAssertEqual(model.segments.map(\.id), [ids[1], ids[0]], "dropped after the other clip")
    }
}
