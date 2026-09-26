import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Arrows any way, a text size control, spotlights, and tidy lanes.
@MainActor
final class VideoAnnotationToolsTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory {
            VideoDemoDraftStore.delete(for: directory.appendingPathComponent("rec.mp4"))
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private typealias T = VideoEditorTestModel

    private func project(_ effects: [VideoDemoOverlayEffect]) -> VideoDemoProject {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/tools.mp4"), duration: 5, sourceSize: CGSize(width: 1920, height: 1080))
        project.cursor.visible = false
        project.padding = 0
        project.overlayEffects = effects
        return project
    }

    private func render(_ effects: [VideoDemoOverlayEffect], source: CIImage) -> CIImage {
        let plan = VideoDemoExporter.makePlan(project: project(effects), sourceDuration: 5, recording: nil)
        return VideoFrameRenderer().render(source: source, timelineTime: 2, plan: plan, outputSize: CGSize(width: 1920, height: 1080))
    }

    /// Output pixel (top-left origin) → average color around it.
    private func sample(_ image: CIImage, x: CGFloat, y: CGFloat, radius: CGFloat = 4) -> (r: Double, g: Double, b: Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let rect = CGRect(x: x - radius, y: 1080 - y - radius, width: radius * 2, height: radius * 2)
        CIContext().render(image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)]), toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    func testArrowsPointWhereverTheirEndsSay() throws {
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        var arrow = VideoDemoOverlayEffect(kind: .arrow, time: 0, duration: 5, color: VideoRGBA(hex: 0x0A84FF), thickness: .bold)
        // Down and to the left: from (0.7, 0.3) to (0.3, 0.7).
        arrow.setArrow(tail: CGPoint(x: 0.7, y: 0.3), head: CGPoint(x: 0.3, y: 0.7))
        let image = render([arrow], source: white)
        let middle = sample(image, x: 960, y: 540)
        XCTAssertLessThan(middle.r, 0.6, "ink along the line")
        let nearHead = sample(image, x: 1920 * 0.33, y: 1080 * 0.67, radius: 10)
        XCTAssertLessThan(nearHead.r, 0.7, "the head is down at the left")
        let oldHeadCorner = sample(image, x: 1920 * 0.67, y: 1080 * 0.67, radius: 10)
        XCTAssertGreaterThan(oldHeadCorner.r, 0.95, "nothing where an up-right arrow's box corner would be")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-ux-fixes", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let screen = CIImage(cgImage: VideoTestSupport.fakeScreen(size: CGSize(width: 1920, height: 1080), progress: 0.4, typed: "Hello"))
        var arrows: [VideoDemoOverlayEffect] = []
        for (index, (tail, head)) in [
            (CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.35, y: 0.2)),
            (CGPoint(x: 0.5, y: 0.15), CGPoint(x: 0.5, y: 0.35)),
            (CGPoint(x: 0.85, y: 0.3), CGPoint(x: 0.65, y: 0.5)),
            (CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.35, y: 0.6)),
        ].enumerated() {
            var effect = VideoDemoOverlayEffect(kind: .arrow, time: 0, duration: 5, layer: index, color: VideoRGBA(hex: 0xFF453A))
            effect.setArrow(tail: tail, head: head)
            arrows.append(effect)
        }
        var spot = VideoDemoOverlayEffect(kind: .spotlight, time: 0, duration: 5, x: 0.72, y: 0.72, width: 0.3, height: 0.3, layer: 4)
        spot.shape = .ellipse
        let url = dir.appendingPathComponent("fix-12-arrows-and-spotlight.png")
        try VideoTestSupport.writePNG(render(arrows + [spot], source: screen), size: CGSize(width: 1920, height: 1080), to: url)
        print("SNAPSHOT: \(url.path)")
    }

    func testSpotlightDimsEverythingAroundIt() {
        let gray = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        var spot = VideoDemoOverlayEffect(kind: .spotlight, time: 0, duration: 5, x: 0.5, y: 0.5, width: 0.4, height: 0.4)
        let rect = render([spot], source: gray)
        XCTAssertEqual(sample(rect, x: 960, y: 540).r, 0.8, accuracy: 0.03, "the spot stays bright")
        XCTAssertLessThan(sample(rect, x: 150, y: 150).r, 0.55, "around it dims")
        XCTAssertEqual(sample(rect, x: 1920 * 0.32, y: 1080 * 0.32).r, 0.8, accuracy: 0.05, "a rectangle keeps its corners")

        spot.shape = .ellipse
        let ellipse = render([spot], source: gray)
        XCTAssertEqual(sample(ellipse, x: 960, y: 540).r, 0.8, accuracy: 0.03)
        XCTAssertLessThan(sample(ellipse, x: 1920 * 0.31, y: 1080 * 0.31).r, 0.6, "an ellipse dims its box's corners")
    }

    func testTextSizeIsItsOwnControl() async throws {
        let model = try await T.make(in: directory)
        model.addOverlay(.text)
        let id = try XCTUnwrap(model.selectedOverlay?.id)
        let before = try XCTUnwrap(model.selectedOverlay)
        model.setTextSize(48, of: id)
        model.endGesture()
        let after = try XCTUnwrap(model.selectedOverlay)
        XCTAssertEqual(model.textSize(of: after), 48, accuracy: 0.5)
        XCTAssertEqual(after.width, before.width, accuracy: 0.0001, "the line length stays")
        XCTAssertEqual(after.y, before.y, accuracy: 0.0001, "it grows around its middle")
        XCTAssertGreaterThan(after.height, before.height)
        model.undo()
        XCTAssertEqual(model.selectedOverlay?.height ?? 0, before.height, accuracy: 0.0001)
    }

    func testNewArrowsAndSpotlightsStartReady() async throws {
        let model = try await T.make(in: directory)
        model.seek(to: 2)
        model.addOverlay(.arrow)
        let arrow = try XCTUnwrap(model.selectedOverlay)
        XCTAssertNotNil(arrow.arrowEnds, "new arrows save their ends (so they can turn)")
        XCTAssertLessThan(arrow.arrowPoints.head.y, arrow.arrowPoints.tail.y, "pointing up and right, as before")
        model.duplicateOverlay(arrow.id)
        let copy = try XCTUnwrap(model.selectedOverlay)
        XCTAssertEqual(copy.arrowPoints.head.x, arrow.arrowPoints.head.x + 0.03, accuracy: 0.001, "a copy's arrow moves with its box")

        VideoOverlayStyleMemory.shape = .ellipse
        defer { VideoOverlayStyleMemory.shape = .rectangle }
        model.addOverlay(.spotlight)
        XCTAssertEqual(model.selectedOverlay?.kind, .spotlight)
        XCTAssertEqual(model.selectedOverlay?.shape, .ellipse, "starts with the last shape picked")
    }
}
