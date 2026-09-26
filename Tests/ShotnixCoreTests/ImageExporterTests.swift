import AppKit
import XCTest
@testable import ShotnixCore

@MainActor
final class ImageExporterTests: XCTestCase {
    private var dir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotnixCoreTests.ImageExporter.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "ShotnixCoreTests.ImageExporter.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Settings.defaults = defaults
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suiteName)
        Settings.defaults = .standard
        try super.tearDownWithError()
    }

    func testPrimitiveEncodersProduceData() throws {
        let image = Self.makeImage()
        let cg = try XCTUnwrap(image.bestCGImage)

        XCTAssertNotNil(ImageExporter.pngData(from: cg))
        XCTAssertNotNil(ImageExporter.jpegData(from: cg))
    }

    func testWebPSaveReturnsWritableImageFileOrFallback() throws {
        let savedURL = try XCTUnwrap(ImageExporter.save(image: Self.makeImage(), to: dir.appendingPathComponent("capture.webp")))

        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertTrue(["webp", "png"].contains(savedURL.pathExtension.lowercased()))
    }

    // MARK: Auto-save names

    func testUniqueURLNumbersTakenNames() throws {
        XCTAssertEqual(ImageExporter.uniqueURL(in: dir, baseName: "Shot", pathExtension: "png").lastPathComponent, "Shot.png")
        try Data([1]).write(to: dir.appendingPathComponent("Shot.png"))
        try Data([2]).write(to: dir.appendingPathComponent("Shot 2.png"))
        XCTAssertEqual(ImageExporter.uniqueURL(in: dir, baseName: "Shot", pathExtension: "png").lastPathComponent, "Shot 3.png")
    }

    func testAutoSaveNeverReplacesAnExistingFile() async throws {
        let existing = dir.appendingPathComponent("Shotnix 2026-04-12 at 10.30.48.png")
        try Data("keep me".utf8).write(to: existing)

        let saved = try await autoSave(baseName: "Shotnix 2026-04-12 at 10.30.48")

        XCTAssertEqual(saved.lastPathComponent, "Shotnix 2026-04-12 at 10.30.48 2.png")
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep me".utf8), "the earlier screenshot is untouched")
        XCTAssertNotNil(NSImage(contentsOf: saved))
    }

    func testSameSecondAutoSavesAllLand() async throws {
        // All Displays: one capture per screen, same timestamp.
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<4 {
                group.addTask { @MainActor in try await self.autoSave(baseName: "Burst") }
            }
            return try await group.reduce(into: [URL]()) { $0.append($1) }
        }
        XCTAssertEqual(Set(urls.map(\.lastPathComponent)), ["Burst.png", "Burst 2.png", "Burst 3.png", "Burst 4.png"])
    }

    func testAutoSaveKeepsTheChosenFormatsExtension() async throws {
        let saved = try await autoSave(baseName: "Photo", format: "jpeg")
        XCTAssertEqual(saved.pathExtension, "jpeg")
    }

    func testAutoSaveReportsTheFileActuallyWrittenForWebP() async throws {
        let saved = try await autoSave(baseName: "Web", format: "webp")
        XCTAssertEqual(saved.pathExtension, ImageExporter.isWebPSupported ? "webp" : "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testAutoSaveIntoAReadOnlyFolderFailsLoudly() async throws {
        let locked = dir.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        do {
            _ = try await autoSave(baseName: "Nope", in: locked)
            XCTFail("saving into a read-only folder must fail")
        } catch {
            let message = ImageExporter.autoSaveFailureMessage(for: error, directory: locked)
            XCTAssertTrue(message.contains("can't write to Locked"), message)
        }
    }

    func testFailureMessagesExplainTheProblem() {
        let full = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertTrue(ImageExporter.autoSaveFailureMessage(for: full, directory: dir).contains("disk is full"))
        let posixFull = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertTrue(ImageExporter.autoSaveFailureMessage(for: posixFull, directory: dir).contains("disk is full"))
        let readOnly = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError)
        XCTAssertTrue(ImageExporter.autoSaveFailureMessage(for: readOnly, directory: dir).contains("can't write to"))
    }

    /// Save As: the user picked the name (and confirmed replacing it), so the
    /// explicit save writes exactly there — encoded off the main thread.
    func testExplicitSaveWritesTheChosenFileOffTheMainThread() async throws {
        let target = dir.appendingPathComponent("Chosen.png")
        try Data("old".utf8).write(to: target)
        let saved: URL = try await withCheckedThrowingContinuation { continuation in
            ImageExporter.saveAsync(image: Self.makeImage(), to: target) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(saved, target)
        XCTAssertNotNil(NSImage(contentsOf: saved), "replaced with the screenshot")
    }

    // MARK: Clipboard

    func testFailedCopyLeavesTheClipboardAlone() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ShotnixTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("precious", forType: .string)

        XCTAssertFalse(ImageExporter.copyToClipboard(image: NSImage(), pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "precious", "an image that can't encode must not empty the clipboard")
        pasteboard.releaseGlobally()
    }

    func testAsyncCopyEncodesOffTheMainThreadThenReports() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ShotnixTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let before = pasteboard.changeCount
        let copied = expectation(description: "copied")
        var succeeded = false
        ImageExporter.copyToClipboardAsync(image: Self.makeImage(), pasteboard: pasteboard) { ok in
            succeeded = ok
            copied.fulfill()
        }
        XCTAssertEqual(pasteboard.changeCount, before, "the call returns before the encode finishes")
        await fulfillment(of: [copied], timeout: 5)
        XCTAssertTrue(succeeded)
        XCTAssertNotNil(pasteboard.data(forType: .png))
        pasteboard.releaseGlobally()
    }

    // MARK: WebP

    func testWebPIsOfferedOnlyWhereMacOSCanWriteIt() {
        XCTAssertEqual(ImageExporter.availableFormats.contains("webp"), ImageExporter.isWebPSupported)
        XCTAssertEqual(Array(ImageExporter.availableFormats.prefix(2)), ["png", "jpeg"])
    }

    func testStoredWebPChoiceMigratesToPNGWhereUnsupported() {
        Settings.didMigrateLegacyToolShortcuts = true // keep this test off KeyboardShortcuts' storage
        Settings.screenshotFormat = "webp"
        Settings.migrateCaptureSettingsIfNeeded(webPSupported: false)
        XCTAssertEqual(Settings.screenshotFormat, "png")

        Settings.screenshotFormat = "webp"
        Settings.migrateCaptureSettingsIfNeeded(webPSupported: true)
        XCTAssertEqual(Settings.screenshotFormat, "webp", "kept where macOS can encode it")
    }

    func testSavedToastNamesTheFileActuallyWritten() {
        let url = URL(fileURLWithPath: "/Users/someone/Desktop/Shot 2.png")
        XCTAssertTrue(QuickAccessOverlay.savedMessage(for: url).contains("Shot 2.png"))
    }

    // MARK: - Helpers

    private func autoSave(baseName: String, format: String = "png", in directory: URL? = nil) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            ImageExporter.autoSave(image: Self.makeImage(), in: directory ?? dir, baseName: baseName, format: format) { result in
                continuation.resume(with: result)
            }
        }
    }

    private static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 16, height: 16)).fill()
        image.unlockFocus()
        return image
    }
}
