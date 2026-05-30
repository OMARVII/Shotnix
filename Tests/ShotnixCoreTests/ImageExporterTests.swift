import AppKit
import XCTest
@testable import ShotnixCore

final class ImageExporterTests: XCTestCase {
    func testPrimitiveEncodersProduceData() throws {
        let image = Self.makeImage()
        let cg = try XCTUnwrap(image.bestCGImage)

        XCTAssertNotNil(ImageExporter.pngData(from: cg))
        XCTAssertNotNil(ImageExporter.jpegData(from: cg))
    }

    func testWebPSaveReturnsWritableImageFileOrFallback() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShotnixCoreTests.ImageExporter.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let savedURL = try XCTUnwrap(ImageExporter.save(image: Self.makeImage(), to: dir.appendingPathComponent("capture.webp")))

        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertTrue(["webp", "png"].contains(savedURL.pathExtension.lowercased()))
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
