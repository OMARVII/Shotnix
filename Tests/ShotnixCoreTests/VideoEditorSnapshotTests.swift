import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Renders editor surfaces offscreen into PNGs (printed as SNAPSHOT: …) so
/// layout changes can be inspected without launching the app.
@MainActor
final class VideoEditorSnapshotTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private func render<V: View>(_ view: V, size: CGSize, name: String) throws -> URL {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT: \(url.path)")
        return url
    }

    private func demoModel() async throws -> VideoEditorModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-snap", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("snap.mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 1440, height: 900), seconds: 12, fps: 30)
        }
        let (samples, clicks) = VideoTestSupport.scriptedPointer(duration: 12)
        let metadata = VideoDemoRecordingMetadata(videoURLPath: url.path, createdAt: Date(), duration: 12, sourceWidth: 1440, sourceHeight: 900, fps: 30, nativeCursorVisible: false, cursorSamples: samples, clickEvents: clicks, pointPixelScale: 2, renderCursor: true)
        VideoDemoSidecarStore.save(metadata, for: url)
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        try? await Task.sleep(nanoseconds: 600_000_000)
        return model
    }

    func testTimelineLayering() async throws {
        let model = try await demoModel()
        model.seek(to: 4)
        model.addOverlay(.highlight)
        model.seek(to: 4.5)
        model.addOverlay(.text)
        model.seek(to: 8)
        model.addOverlay(.blur)
        model.seek(to: 7)
        model.splitAtPlayhead()
        model.selection = .none
        let height = 44 + 1 + VideoTimelineMetrics.contentHeight(model.project) + 10
        _ = try render(VideoTimelineView(model: model), size: CGSize(width: 1400, height: height), name: "timeline")
    }

    func testEditorLayout() async throws {
        let model = try await demoModel()
        _ = try render(VideoEditorRootView(model: model), size: CGSize(width: 1512, height: 944), name: "editor")
        model.selection = .zoom(model.project.zoomRegions[0].id)
        _ = try render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 900), name: "inspector-zoom")
        model.selection = .none
        model.inspectorTab = .cursor
        _ = try render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 900), name: "inspector-cursor")
        model.inspectorTab = .zoom
        _ = try render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 900), name: "inspector-zoomtab")
        model.isExportPresented = true
        _ = try render(VideoExportSheet(model: model), size: CGSize(width: 900, height: 760), name: "export")
    }

    func testCaptionsKeysAndCameraSurfaces() async throws {
        let model = try await demoModel()
        model.isExportPresented = false
        // Empty states first.
        model.inspectorTab = .captions
        _ = try render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 700), name: "inspector-captions-empty")
        model.inspectorTab = .camera
        _ = try render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 500), name: "inspector-camera-empty")

        let words: [(String, Double)] = [("Open", 1.0), ("the", 1.3), ("settings", 1.45), ("panel.", 1.9), ("Then", 3.0), ("pick", 3.3), ("a", 3.5), ("theme", 3.6), ("and", 4.1), ("save.", 4.3)]
        let timed = words.map { VideoCaptionWord(text: $0.0, start: $0.1, end: $0.1 + 0.3) }
        model.mutate { project in
            project.captions = VideoCaptionBuilder.lines(from: timed)
            project.keystrokes = [
                VideoKeystrokeEvent(time: 2.0, keys: ["⌘", ","]),
                VideoKeystrokeEvent(time: 5.2, keys: ["⇧", "⌘", "S"]),
                VideoKeystrokeEvent(time: 8.0, keys: ["⌘", "Z"]),
            ]
        }
        model.seek(to: 1.6)
        try? await Task.sleep(nanoseconds: 300_000_000)
        model.inspectorTab = .captions
        _ = try render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 900), name: "inspector-captions")
        model.inspectorTab = .cursor
        _ = try render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 1100), name: "inspector-cursor-keys")
        model.selection = .caption(model.project.captions[0].id)
        _ = try render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 600), name: "inspector-caption-selected")
        model.selection = .none
        model.seek(to: 4)
        model.addOverlay(.text)
        model.selection = .none
        let height = 44 + 1 + VideoTimelineMetrics.contentHeight(model.project) + 10
        _ = try render(VideoTimelineView(model: model), size: CGSize(width: 1400, height: height), name: "timeline-text-lanes")
        _ = try render(VideoEditorRootView(model: model), size: CGSize(width: 1512, height: 944), name: "editor-features")
    }
}
