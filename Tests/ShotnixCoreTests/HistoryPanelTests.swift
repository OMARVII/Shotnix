import AppKit
import XCTest
@testable import ShotnixCore

/// The history grid: selectable (keyboard, Delete, multi-select), drags the
/// stored PNG under its capture-time name, filters by capture type.
@MainActor
final class HistoryPanelTests: XCTestCase {
    private var tempDir: URL!
    private var manager: HistoryManager!
    private let panel = HistoryPanelController.shared

    override func setUp() async throws {
        // The panel activates the app; xctest has no NSApp until asked.
        _ = NSApplication.shared
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotnixCoreTests.HistoryPanel.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        manager = HistoryManager(storageDir: tempDir)
    }

    override func tearDown() async throws {
        for window in NSApp.windows where window.title == "Shotnix - Capture History" {
            window.close()
        }
        // The panel forgets its window on the next main-actor turn.
        try await Task.sleep(nanoseconds: 150_000_000)
        manager = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testGridIsSelectableForKeyboardAndMultiCardDrags() throws {
        manager.add(image: HistoryManagerTests.makeImage(), rect: nil, type: .area)
        panel.show(historyManager: manager)
        let grid = try XCTUnwrap(panel.collectionView)
        XCTAssertTrue(grid.isSelectable, "selection is what lets a card be dragged to Finder")
        XCTAssertTrue(grid.allowsMultipleSelection)
        XCTAssertTrue(grid is HistoryCollectionView)
    }

    func testDragHandsOverTheStoredPNGUnderItsCaptureTimeName() async throws {
        let item = manager.add(image: HistoryManagerTests.makeImage(size: 200), rect: nil, type: .window)
        await manager.waitForPendingFileOperations()
        panel.show(historyManager: manager)
        let grid = try XCTUnwrap(panel.collectionView)

        let writer = panel.collectionView(grid, pasteboardWriterForItemAt: IndexPath(item: 0, section: 0))
        let url = try XCTUnwrap(writer as? NSURL) as URL
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, ImageExporter.captureName(for: item.createdAt))
        XCTAssertEqual(url.pathExtension, "png")
        // The very same bytes — cloned, not re-encoded.
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: URL(fileURLWithPath: item.imagePath)))
        XCTAssertNotNil(Self.xattr("com.apple.metadata:kMDItemIsScreenCapture", at: url), "screenshot metadata survives the drag")
    }

    func testSameSecondDragsGetNumberedNames() {
        let date = Date()
        let first = HistoryItem(id: UUID(), createdAt: date, imagePath: "/a", thumbnailPath: "/a", captureRect: nil)
        let second = HistoryItem(id: UUID(), createdAt: date, imagePath: "/b", thumbnailPath: "/b", captureRect: nil)
        let base = ImageExporter.captureName(for: date)
        XCTAssertEqual(panel.dragFileName(for: first, among: [first, second]), base)
        XCTAssertEqual(panel.dragFileName(for: second, among: [first, second]), "\(base) 2")
        XCTAssertEqual(panel.dragFileName(for: second, among: [second]), base)
    }

    func testTypeFilterShowsOnlyThatKindOfCapture() throws {
        manager.add(image: HistoryManagerTests.makeImage(), rect: nil, type: .area)
        manager.add(image: HistoryManagerTests.makeImage(), rect: nil, type: .window)
        manager.add(image: HistoryManagerTests.makeImage(), rect: nil, type: .scrolling)
        panel.show(historyManager: manager)
        let grid = try XCTUnwrap(panel.collectionView)
        XCTAssertEqual(Self.itemCount(in: grid), 3)

        panel.setTypeFilter(.window)
        XCTAssertEqual(Self.itemCount(in: grid), 1)
        panel.setTypeFilter(.text)
        XCTAssertEqual(Self.itemCount(in: grid), 0)
        panel.setTypeFilter(nil)
        XCTAssertEqual(Self.itemCount(in: grid), 3)
    }

    func testFilterCombinesTypeAndText() {
        let area = HistoryItem(id: UUID(), createdAt: Date(), imagePath: "/a", thumbnailPath: "/a", captureRect: nil, ocrText: "quarterly report", captureTypeRaw: "area")
        let text = HistoryItem(id: UUID(), createdAt: Date(), imagePath: "/b", thumbnailPath: "/b", captureRect: nil, ocrText: "quarterly numbers", captureTypeRaw: "text")
        let legacy = HistoryItem(id: UUID(), createdAt: Date(), imagePath: "/c", thumbnailPath: "/c", captureRect: nil, ocrText: "quarterly")
        XCTAssertEqual(HistoryPanelController.filter([area, text, legacy], query: "quarterly", type: .text).map(\.id), [text.id])
        XCTAssertEqual(HistoryPanelController.filter([area, text, legacy], query: "", type: nil).count, 3)
        XCTAssertEqual(HistoryPanelController.filter([area, text, legacy], query: "report", type: nil).map(\.id), [area.id])
    }

    func testDeleteKeyRemovesTheSelectionAndUndoRestoresIt() async throws {
        let first = manager.add(image: HistoryManagerTests.makeImage(), rect: nil, type: .area)
        let second = manager.add(image: HistoryManagerTests.makeImage(), rect: nil, type: .area)
        let third = manager.add(image: HistoryManagerTests.makeImage(), rect: nil, type: .area)
        await manager.waitForPendingFileOperations()
        panel.show(historyManager: manager)
        let grid = try XCTUnwrap(panel.collectionView as? HistoryCollectionView)
        grid.selectItems(at: [IndexPath(item: 0, section: 0), IndexPath(item: 2, section: 0)], scrollPosition: [])
        XCTAssertEqual(Set(panel.selectedItems.map(\.id)), [third.id, first.id])

        grid.keyDown(with: try XCTUnwrap(Self.key(51, window: grid.window)))
        XCTAssertEqual(manager.items.map(\.id), [second.id])

        // What the undo toast does:
        for id in [third.id, first.id] { manager.restoreFromTrash(id: id) }
        XCTAssertEqual(manager.items.map(\.id), [third.id, second.id, first.id], "back in their places")
    }

    func testTypingOnTheGridSearchesAndDownArrowGoesBackToTheResults() throws {
        manager.add(image: HistoryManagerTests.makeImage(), rect: nil, type: .area)
        manager.add(image: HistoryManagerTests.makeImage(), rect: nil, type: .area)
        panel.show(historyManager: manager)
        let grid = try XCTUnwrap(panel.collectionView as? HistoryCollectionView)
        let window = try XCTUnwrap(grid.window)
        let search = try XCTUnwrap(Self.searchField(in: window.contentView))
        XCTAssertTrue(window.firstResponder === grid, "arrows and Delete work straight away")

        grid.keyDown(with: try XCTUnwrap(Self.typed("q", keyCode: 12, window: window)))
        XCTAssertEqual(search.stringValue, "q", "typing starts a search")
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate === search, "and keeps typing into the field")
        XCTAssertEqual(Self.itemCount(in: grid), 0)

        search.stringValue = ""
        XCTAssertTrue(search.sendAction(search.action, to: search.target))
        XCTAssertEqual(Self.itemCount(in: grid), 2)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(panel.control(search, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(window.firstResponder === grid, "Down arrow moves on to the results")
        XCTAssertEqual(grid.selectionIndexPaths, [IndexPath(item: 0, section: 0)])

        // Shortcuts and navigation keys stay with the grid.
        XCTAssertFalse(panel.searchByTyping(try XCTUnwrap(Self.typed("c", keyCode: 8, window: window, modifiers: .command))))
        XCTAssertFalse(panel.searchByTyping(try XCTUnwrap(Self.typed(String(UnicodeScalar(NSRightArrowFunctionKey)!), keyCode: 124, window: window))))
        XCTAssertFalse(panel.searchByTyping(try XCTUnwrap(Self.typed(" ", keyCode: 49, window: window))), "a leading space isn't a search")
        XCTAssertTrue(window.firstResponder === grid)

        XCTAssertTrue(grid.performKeyEquivalent(with: try XCTUnwrap(Self.typed("f", keyCode: 3, window: window, modifiers: .command))))
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate === search, "⌘F focuses search")
    }

    private static func typed(_ characters: String, keyCode: UInt16, window: NSWindow, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
    }

    private static func searchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }

    func testCommandZBringsDeletedCapturesBackAndRedoDeletesThemAgain() async throws {
        let first = manager.add(image: HistoryManagerTests.makeImage(), rect: nil, type: .area)
        let second = manager.add(image: HistoryManagerTests.makeImage(), rect: nil, type: .area)
        await manager.waitForPendingFileOperations()
        panel.show(historyManager: manager)
        let grid = try XCTUnwrap(panel.collectionView as? HistoryCollectionView)
        grid.selectItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: [])
        grid.keyDown(with: try XCTUnwrap(Self.key(51, window: grid.window)))
        XCTAssertEqual(manager.items.map(\.id), [first.id])

        let undoManager = try XCTUnwrap(grid.window?.undoManager)
        XCTAssertEqual(undoManager.undoActionName, "Delete Screenshot")
        undoManager.undo()
        XCTAssertEqual(manager.items.map(\.id), [second.id, first.id], "long after the toast, ⌘Z still works")
        undoManager.redo()
        XCTAssertEqual(manager.items.map(\.id), [first.id])
    }

    func testEmptyStateNamesTheRealShortcut() {
        XCTAssertEqual(HistoryPanelController.emptyStateHint(captureAreaShortcut: "⌃⌥S"), "Press ⌃⌥S to take your first screenshot")
        XCTAssertFalse(HistoryPanelController.emptyStateHint(captureAreaShortcut: nil).contains("⌘"), "never promise an unassigned key")
    }

    func testRenderHistoryPanelSnapshot() async throws {
        manager.add(image: Self.sampleCapture(hue: 0.58), rect: CGRect(x: 0, y: 0, width: 800, height: 500), type: .area)
        manager.add(image: Self.sampleCapture(hue: 0.08), rect: CGRect(x: 0, y: 0, width: 1200, height: 700), type: .window)
        manager.add(image: Self.sampleCapture(hue: 0.33), rect: CGRect(x: 0, y: 0, width: 600, height: 400), type: .scrolling)
        await manager.waitForPendingFileOperations()
        panel.show(historyManager: manager)
        let grid = try XCTUnwrap(panel.collectionView)
        grid.selectItems(at: [IndexPath(item: 1, section: 0)], scrollPosition: [])
        try await Task.sleep(nanoseconds: 600_000_000)

        let window = try XCTUnwrap(grid.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-capture-snapshots/history-panel.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT-HISTORY: \(url.path)")
    }

    // MARK: - Helpers

    private static func itemCount(in grid: NSCollectionView) -> Int {
        (0..<grid.numberOfSections).reduce(0) { $0 + grid.numberOfItems(inSection: $1) }
    }

    private static func key(_ keyCode: UInt16, window: NSWindow?) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil, characters: "\u{8}", charactersIgnoringModifiers: "\u{8}", isARepeat: false, keyCode: keyCode)
    }

    private static func xattr(_ name: String, at url: URL) -> Data? {
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        _ = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, length, 0, 0) }
        return data
    }

    private static func sampleCapture(hue: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 320, height: 200))
        image.lockFocus()
        NSColor(calibratedHue: hue, saturation: 0.5, brightness: 0.9, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 320, height: 200)).fill()
        NSColor.white.withAlphaComponent(0.85).setFill()
        for row in 0..<6 {
            NSBezierPath(roundedRect: NSRect(x: 24, y: 150 - row * 22, width: 180 - row * 18, height: 10), xRadius: 3, yRadius: 3).fill()
        }
        image.unlockFocus()
        return image
    }
}
