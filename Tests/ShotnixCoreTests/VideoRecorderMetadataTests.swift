import AppKit
import XCTest
@testable import ShotnixCore

/// The pointer recorder: samples, re-anchoring to the first frame, the
/// captured pointer artwork, and what it tells the editor.
@MainActor
final class VideoRecorderMetadataTests: XCTestCase {
    func testRecorderCapturesPathShapesAndRenderIntent() async throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let recorder = VideoDemoRecordingMetadataRecorder(
            videoURL: URL(fileURLWithPath: "/tmp/rec.mp4"),
            captureRect: screen.frame,
            sourcePixelSize: CGSize(width: screen.frame.width * 2, height: screen.frame.height * 2),
            fps: 60,
            nativeCursorVisible: false,
            renderCursor: true
        )
        recorder.start()
        try await Task.sleep(nanoseconds: 400_000_000)
        recorder.alignStart(to: CACurrentMediaTime() - 0.2)
        try await Task.sleep(nanoseconds: 300_000_000)
        let metadata = recorder.finish(duration: 0.5)

        XCTAssertFalse(metadata.cursorSamples.isEmpty)
        XCTAssertEqual(metadata.cursorSamples.first?.time ?? -1, 0, accuracy: 0.001, "pre-roll samples collapse onto t=0")
        XCTAssertTrue(metadata.cursorSamples.allSatisfy { $0.time >= 0 })
        XCTAssertEqual(metadata.pointPixelScale ?? 0, 2, accuracy: 0.001)
        XCTAssertTrue(metadata.shouldRenderCursor)
        XCTAssertFalse(metadata.nativeCursorVisible)
        // The system pointer's artwork is captured (when the environment exposes one).
        if let shapes = metadata.cursorShapes {
            XCTAssertFalse(shapes.isEmpty)
            XCTAssertEqual(metadata.cursorShapeEvents?.first?.time ?? -1, 0, accuracy: 0.001)
            let artwork = VideoCursorArtwork(metadata: metadata)
            XCTAssertTrue(artwork.hasCapturedShapes)
        }
    }

    func testBakedCursorRecordingDoesNotDrawASecondPointer() {
        let recorder = VideoDemoRecordingMetadataRecorder(
            videoURL: URL(fileURLWithPath: "/tmp/rec.mp4"),
            captureRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            sourcePixelSize: CGSize(width: 200, height: 200),
            fps: 30,
            nativeCursorVisible: true,
            renderCursor: false
        )
        recorder.start()
        let metadata = recorder.finish(duration: 0.1)
        XCTAssertFalse(metadata.shouldRenderCursor)
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/rec.mp4"))
        project.apply(metadata: metadata)
        XCTAssertFalse(project.rendersCursor)
    }
}
