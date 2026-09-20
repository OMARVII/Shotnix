import AppKit
import XCTest
@testable import ShotnixCore

/// Visual harness: renders the timed-capture countdown to a PNG (printed as
/// SNAPSHOT-COUNTDOWN: <path>) so its layout can be inspected without
/// driving a real timed capture.
@MainActor
final class CountdownSnapshotRender: XCTestCase {

    func testRenderCountdownSnapshot() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("no screen") }
        let window = CountdownWindow(seconds: 5, on: screen) { _ in }
        window.start()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))

        let host = try XCTUnwrap(window.contentView)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-countdown-snapshot.png")
        try png.write(to: out)
        print("SNAPSHOT-COUNTDOWN: \(out.path) — \(rep.pixelsWide)x\(rep.pixelsHigh)")

        window.orderOut(nil)
    }
}
