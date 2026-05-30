import AppKit
import XCTest
@testable import ShotnixCore

@MainActor
final class HistoryManagerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotnixCoreTests.History.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
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

    private static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 24, height: 24)).fill()
        image.unlockFocus()
        return image
    }
}
