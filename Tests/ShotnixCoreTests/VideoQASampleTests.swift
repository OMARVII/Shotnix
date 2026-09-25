import AppKit
import XCTest
@testable import ShotnixCore

/// Writes a realistic sample recording (+ sidecar metadata, as the recorder
/// would) for hands-on QA of the editor. Opt-in: set SHOTNIX_QA_SAMPLE_DIR.
final class VideoQASampleTests: XCTestCase {
    func testWriteQASample() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SHOTNIX_QA_SAMPLE_DIR"] else {
            throw XCTSkip("Set SHOTNIX_QA_SAMPLE_DIR to write the QA sample")
        }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Shotnix QA Demo.mp4")
        let size = CGSize(width: 2880, height: 1800)
        let duration = 12.0
        try await VideoTestSupport.writeFakeRecording(to: url, size: size, seconds: duration, fps: 60)

        let (samples, clicks) = VideoTestSupport.scriptedPointer(duration: duration)
        var shapes: [VideoCursorShape] = []
        var events: [VideoCursorShapeEvent] = []
        await MainActor.run {
            func shape(_ cursor: NSCursor, id: String) -> VideoCursorShape? {
                let reps = cursor.image.representations.compactMap { $0 as? NSBitmapImageRep }
                guard let largest = reps.max(by: { $0.pixelsWide < $1.pixelsWide }),
                      let png = largest.representation(using: .png, properties: [:]),
                      cursor.image.size.width > 0 else { return nil }
                return VideoCursorShape(id: id, hotSpotX: cursor.hotSpot.x, hotSpotY: cursor.hotSpot.y, width: cursor.image.size.width, height: cursor.image.size.height, pngData: png)
            }
            let arrow = shape(NSCursor.arrow, id: "arrow") ?? VideoTestSupport.currentCursorShape()
            let hand = shape(NSCursor.pointingHand, id: "hand")
            let beam = shape(NSCursor.iBeam, id: "ibeam")
            shapes = [arrow, hand, beam].compactMap { $0 }
            if let arrow { events.append(VideoCursorShapeEvent(time: 0, shapeID: arrow.id)) }
            for click in clicks {
                if let hand, click.x > 0.1 {
                    let isField = abs(click.y - 0.69) < 0.03
                    let over = isField ? (beam ?? hand) : hand
                    events.append(VideoCursorShapeEvent(time: max(click.time - 0.45, 0), shapeID: over.id))
                    if let arrow {
                        events.append(VideoCursorShapeEvent(time: click.time + (isField ? 2.2 : 0.5), shapeID: arrow.id))
                    }
                }
            }
            events.sort { $0.time < $1.time }
        }

        let metadata = VideoDemoRecordingMetadata(
            videoURLPath: url.path,
            createdAt: Date(),
            duration: duration,
            sourceWidth: size.width,
            sourceHeight: size.height,
            fps: 60,
            nativeCursorVisible: false,
            cursorSamples: samples,
            clickEvents: clicks,
            pointPixelScale: 2,
            cursorShapes: shapes.isEmpty ? nil : shapes,
            cursorShapeEvents: events.isEmpty ? nil : events,
            renderCursor: true
        )
        XCTAssertTrue(VideoDemoSidecarStore.save(metadata, for: url))
        VideoDemoDraftStore.delete(for: url)
        print("QA-SAMPLE: \(url.path) shapes=\(shapes.map(\.id))")
    }
}
