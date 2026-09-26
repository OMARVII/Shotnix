import AppKit
import XCTest
@testable import ShotnixCore

@MainActor
final class HistoryManagerTests: XCTestCase {
    private var tempDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotnixCoreTests.History.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        suiteName = "ShotnixCoreTests.History.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Settings.defaults = defaults
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        defaults.removePersistentDomain(forName: suiteName)
        Settings.defaults = .standard
        try super.tearDownWithError()
    }

    func testAddPersistsImageAndIndex() async throws {
        let manager = HistoryManager(storageDir: tempDir)
        let item = manager.add(image: Self.makeImage(), rect: CGRect(x: 10, y: 20, width: 30, height: 40))

        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.items.first?.id, item.id)

        try await waitForFile(atPath: item.imagePath)
        try await waitForFile(atPath: item.thumbnailPath)
        try await waitForFile(atPath: tempDir.appendingPathComponent("index.json").path)

        let indexData = try Data(contentsOf: tempDir.appendingPathComponent("index.json"))
        let decoded = try JSONDecoder().decode([HistoryItem].self, from: indexData)
        XCTAssertEqual(decoded.first?.id, item.id)
        XCTAssertEqual(decoded.first?.captureRect?.cgRect, CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    func testDeleteUpdatesInMemoryIndex() async throws {
        let manager = HistoryManager(storageDir: tempDir)
        let item = manager.add(image: Self.makeImage(), rect: nil)
        try await waitForFile(atPath: item.imagePath)

        XCTAssertEqual(manager.items.count, 1)
        manager.delete(item)
        XCTAssertTrue(manager.items.isEmpty)
    }

    func testCorruptIndexStartsEmptyWithoutOverwritingFile() throws {
        let indexURL = tempDir.appendingPathComponent("index.json")
        try "not-json".data(using: .utf8)?.write(to: indexURL)

        let manager = HistoryManager(storageDir: tempDir)

        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertEqual(String(data: try Data(contentsOf: indexURL), encoding: .utf8), "not-json")
    }

    // MARK: Capture type

    func testCaptureTypeIsRecordedAndSurvivesARelaunch() async throws {
        let manager = HistoryManager(storageDir: tempDir)
        let window = manager.add(image: Self.makeImage(), rect: nil, type: .window)
        let text = manager.add(image: Self.makeImage(), rect: nil, type: .text, ocrText: "Invoice 42")
        await manager.waitForPendingFileOperations()
        manager.flushPendingWrites()

        let reloaded = HistoryManager(storageDir: tempDir)
        XCTAssertEqual(reloaded.items.first(where: { $0.id == window.id })?.captureType, .window)
        let textItem = try XCTUnwrap(reloaded.items.first(where: { $0.id == text.id }))
        XCTAssertEqual(textItem.captureType, .text)
        XCTAssertEqual(textItem.ocrText, "Invoice 42", "text captures arrive already indexed")
    }

    func testIndexFromANewerVersionWithAnUnknownTypeStillLoads() throws {
        let id = UUID()
        let imagePath = tempDir.appendingPathComponent("\(id.uuidString).png").path
        try ImageExporter.pngData(from: Self.makeImage())?.write(to: URL(fileURLWithPath: imagePath))
        let json = """
        [{"id":"\(id.uuidString)","createdAt":700000000,"imagePath":"\(imagePath)","thumbnailPath":"\(imagePath)","captureTypeRaw":"hologram"}]
        """
        try json.data(using: .utf8)?.write(to: tempDir.appendingPathComponent("index.json"))

        let manager = HistoryManager(storageDir: tempDir)
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertNil(manager.items.first?.captureType)
    }

    // MARK: Retention

    func testRetentionDefaultsToForever() throws {
        XCTAssertEqual(Settings.historyRetention, .forever)
        try seedIndex(ages: [400, 90, 1].map { TimeInterval($0) * 86_400 })
        let manager = HistoryManager(storageDir: tempDir)
        XCTAssertEqual(manager.items.count, 3, "an update must never start deleting history")
    }

    func testAgeRetentionDeletesOldCapturesAndTheirFiles() async throws {
        let seeded = try seedIndex(ages: [45, 31, 10, 0].map { TimeInterval($0) * 86_400 })
        Settings.historyRetention = .days30
        let manager = HistoryManager(storageDir: tempDir)
        await manager.waitForPendingFileOperations()

        XCTAssertEqual(Set(manager.items.map(\.id)), Set(seeded.suffix(2).map(\.id)))
        for old in seeded.prefix(2) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.imagePath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.thumbnailPath))
        }
        for kept in seeded.suffix(2) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.imagePath))
        }
    }

    func testCountRetentionKeepsTheNewest() async throws {
        let seeded = try seedIndex(ages: (0..<105).map { TimeInterval($0) * 60 })
        let manager = HistoryManager(storageDir: tempDir)
        XCTAssertEqual(manager.itemsExceedingRetention(.items100).count, 5)

        XCTAssertEqual(manager.applyRetention(.items100), 5)
        await manager.waitForPendingFileOperations()
        XCTAssertEqual(manager.items.count, 100)
        // The five oldest went; the newest stayed.
        let removed = Set(seeded.suffix(5).map(\.id))
        XCTAssertTrue(manager.items.allSatisfy { !removed.contains($0.id) })
    }

    // MARK: Disk upkeep

    func testSweepRemovesOnlyUntrackedCaptureFiles() async throws {
        let seeded = try seedIndex(ages: [0])
        let strayID = UUID().uuidString
        let stray = tempDir.appendingPathComponent("\(strayID).png")
        let strayThumb = tempDir.appendingPathComponent("\(strayID)_thumb.png")
        let trashDir = tempDir.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let strayTrash = trashDir.appendingPathComponent("\(UUID().uuidString).png")
        let notes = tempDir.appendingPathComponent("notes.txt")
        let lookalike = tempDir.appendingPathComponent("holiday.png")
        for url in [stray, strayThumb, strayTrash, notes, lookalike] {
            try Data([1, 2, 3]).write(to: url)
        }

        let manager = HistoryManager(storageDir: tempDir)
        await manager.sweepOrphanedFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: strayThumb.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: strayTrash.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notes.path), "files Shotnix didn't name are never touched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lookalike.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded[0].imagePath))
    }

    func testDeleteRightAfterACaptureWaitsForItsWrite() async throws {
        let manager = HistoryManager(storageDir: tempDir)
        // Big enough that the background encode is still running at delete.
        let item = manager.add(image: Self.makeImage(size: 1600), rect: nil)
        manager.delete(item)
        await manager.waitForPendingFileOperations()

        let trashed = tempDir.appendingPathComponent("Trash/\(item.id.uuidString).png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.imagePath), "no untracked PNG left behind")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path), "the file follows its tombstone into the trash")

        XCTAssertNotNil(manager.restoreFromTrash(id: item.id))
        await manager.waitForPendingFileOperations()
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.imagePath), "undo brings the file back")
    }

    func testIndexWritesAreBatched() async throws {
        let manager = HistoryManager(storageDir: tempDir)
        for _ in 0..<12 {
            manager.add(image: Self.makeImage(), rect: nil)
        }
        await manager.waitForPendingFileOperations()
        try await Task.sleep(nanoseconds: 400_000_000)
        manager.flushPendingWrites()

        XCTAssertLessThanOrEqual(manager.indexWriteCount, 4, "twelve captures, a handful of index writes")
        let decoded = try JSONDecoder().decode([HistoryItem].self, from: Data(contentsOf: tempDir.appendingPathComponent("index.json")))
        XCTAssertEqual(decoded.count, 12)
    }

    func testDiskUsageAndCleanUp() async throws {
        let manager = HistoryManager(storageDir: tempDir)
        let kept = manager.add(image: Self.makeImage(size: 300), rect: nil)
        let deleted = manager.add(image: Self.makeImage(size: 300), rect: nil)
        await manager.waitForPendingFileOperations()
        manager.delete(deleted)
        let orphan = tempDir.appendingPathComponent("\(UUID().uuidString).png")
        try Data(repeating: 7, count: 200_000).write(to: orphan)

        let before = await manager.diskUsage()
        XCTAssertGreaterThan(before, 200_000)

        let freed = await manager.cleanUp()
        let after = await manager.diskUsage()

        XCTAssertGreaterThan(freed, 200_000)
        XCTAssertLessThan(after, before)
        XCTAssertTrue(manager.trashEntries.isEmpty, "Clean Up empties the History trash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.imagePath), "live captures are untouched")
    }

    func testCaptureFileNamesAreRecognizedStrictly() {
        let id = UUID()
        XCTAssertEqual(HistoryManager.captureID(fromFileName: "\(id.uuidString).png"), id)
        XCTAssertEqual(HistoryManager.captureID(fromFileName: "\(id.uuidString)_thumb.png"), id)
        XCTAssertNil(HistoryManager.captureID(fromFileName: "\(id.uuidString).jpg"))
        XCTAssertNil(HistoryManager.captureID(fromFileName: "Screenshot.png"))
        XCTAssertNil(HistoryManager.captureID(fromFileName: "index.json"))
    }

    // MARK: - Helpers

    /// Writes captures (files + index.json) with the given ages in seconds;
    /// returned newest-age-first in the order given.
    @discardableResult
    private func seedIndex(ages: [TimeInterval]) throws -> [HistoryItem] {
        let png = try XCTUnwrap(ImageExporter.pngData(from: Self.makeImage()))
        let items = ages.map { age -> HistoryItem in
            let id = UUID()
            let imagePath = tempDir.appendingPathComponent("\(id.uuidString).png").path
            let thumbPath = tempDir.appendingPathComponent("\(id.uuidString)_thumb.png").path
            try? png.write(to: URL(fileURLWithPath: imagePath))
            try? png.write(to: URL(fileURLWithPath: thumbPath))
            return HistoryItem(id: id, createdAt: Date().addingTimeInterval(-age), imagePath: imagePath, thumbnailPath: thumbPath, captureRect: nil, ocrText: "")
        }
        try JSONEncoder().encode(items).write(to: tempDir.appendingPathComponent("index.json"))
        return items
    }

    private func waitForFile(atPath path: String, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for file at \(path)")
    }

    static func makeImage(size: CGFloat = 24) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: NSRect(x: size * 0.2, y: size * 0.2, width: size * 0.5, height: size * 0.4)).fill()
        image.unlockFocus()
        return image
    }
}
