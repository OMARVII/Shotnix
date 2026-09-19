import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Visual harness + render smoke test: draws the timeline with realistic
/// content into a PNG (printed as SNAPSHOT: <path>) so design changes can be
/// inspected without launching the app. It caught a real bug once — lanes
/// being centered instead of leading-aligned — so it stays.
@MainActor
final class TimelineSnapshotRender: XCTestCase {

    func testRenderTimelineSnapshot() throws {
        var project = VideoDemoProject.make(
            sourceURL: URL(fileURLWithPath: "/tmp/demo.mp4"),
            duration: 30,
            sourceSize: CGSize(width: 1920, height: 1080)
        )
        project.zoomKeyframes = [
            VideoDemoZoomKeyframe(time: 2, scale: 1.8, focusX: 0.3, focusY: 0.4),
            VideoDemoZoomKeyframe(time: 6, scale: 1, focusX: 0.5, focusY: 0.5),
            VideoDemoZoomKeyframe(time: 9, scale: 2.2, focusX: 0.7, focusY: 0.6),
            VideoDemoZoomKeyframe(time: 14, scale: 1, focusX: 0.5, focusY: 0.5),
        ]
        project.clickEvents = [
            VideoDemoClickEvent(time: 2.1, x: 0.3, y: 0.4, button: .left),
            VideoDemoClickEvent(time: 5.0, x: 0.5, y: 0.5, button: .left),
            VideoDemoClickEvent(time: 9.2, x: 0.7, y: 0.6, button: .left),
            VideoDemoClickEvent(time: 15.0, x: 0.4, y: 0.3, button: .left),
            VideoDemoClickEvent(time: 21.0, x: 0.6, y: 0.7, button: .left),
        ]
        project.overlayEffects = VideoDemoProject.normalizedEffectLayers([
            VideoDemoOverlayEffect(kind: .highlight, time: 4, duration: 3),
            VideoDemoOverlayEffect(kind: .text, time: 5, duration: 3.5),   // overlaps highlight → lane 2
            VideoDemoOverlayEffect(kind: .arrow, time: 6, duration: 1.5),  // overlaps both → lane 3
            VideoDemoOverlayEffect(kind: .blur, time: 18, duration: 3),    // free → back on lane 1
        ])

        let model = VideoDemoEditorViewModel(project: project)
        model.duration = 30
        model.selectEffect(project.overlayEffects[0].id)

        let height = VideoDemoTimelineView.preferredHeight(for: project)
        let view = VideoDemoTimelineView(model: model, clock: model.playbackClock)
            .frame(width: 1240, height: height)
            .padding(20)
            .background(Color(red: 0.10, green: 0.10, blue: 0.12))

        let host = NSHostingView(rootView: view)
        let frame = NSRect(x: 0, y: 0, width: 1280, height: height + 40)
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI attach and lay out its hierarchy.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.4))
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-timeline-snapshot.png")
        try png.write(to: out)
        print("SNAPSHOT: \(out.path) — \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
}
