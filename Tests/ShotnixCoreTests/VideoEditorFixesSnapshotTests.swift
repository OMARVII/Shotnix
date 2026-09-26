import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Offscreen renders of the editor states these fixes change (printed as
/// SNAPSHOT: …, written to shotnix-ux-fixes/).
@MainActor
final class VideoEditorFixesSnapshotTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
        VideoStageView.drawsStills = true
    }

    override class func tearDown() {
        VideoStageView.drawsStills = false
        super.tearDown()
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-fixes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let directory {
            VideoDemoDraftStore.delete(for: directory.appendingPathComponent("rec.mp4"))
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private typealias T = VideoEditorTestModel
    private let full = CGSize(width: 1512, height: 944)

    @discardableResult
    static func render<V: View>(_ view: V, size: CGSize, name: String) async throws -> URL {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 350_000_000)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-ux-fixes", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = out.appendingPathComponent("\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT: \(url.path)")
        return url
    }

    func testMessagesShowOnTheExportSheetAndSilentExportsWarn() async throws {
        var options = T.Options(seconds: 6, size: CGSize(width: 1440, height: 900))
        options.audio = true
        let model = try await T.make(in: directory, options)
        model.setStyle { $0.audio.muted = true }
        model.isExportPresented = true
        model.showNotice("Copied — paste it anywhere", symbol: "doc.on.doc", duration: 30)
        try await Self.render(VideoEditorRootView(model: model), size: full, name: "fix-06-notice-over-export-muted")
        model.isExportPresented = false
        model.previewMuted = true
        try await Self.render(VideoEditorRootView(model: model), size: full, name: "fix-01-preview-muted")
    }

    func testAnnotationToolsOnThePreviewAndInspector() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 6, size: CGSize(width: 1440, height: 900)))
        model.mutate { $0.zoomRegions = [] }
        model.seek(to: 2)
        model.addOverlay(.arrow)
        let id = try XCTUnwrap(model.selectedOverlay?.id)
        model.updateOverlay(id) { $0.setArrow(tail: CGPoint(x: 0.75, y: 0.3), head: CGPoint(x: 0.45, y: 0.62)) }
        try await Self.render(VideoEditorRootView(model: model), size: full, name: "fix-12-arrow-selected")
        model.addOverlay(.text)
        try await Self.render(VideoEditorRootView(model: model), size: full, name: "fix-12-text-size-control")
        model.addOverlay(.spotlight)
        if let spot = model.selectedOverlay?.id { model.setOverlayShape(spot, .ellipse) }
        try await Self.render(VideoEditorRootView(model: model), size: full, name: "fix-12-spotlight-selected")
        VideoOverlayStyleMemory.shape = .rectangle
    }

    func testSeveralSelectedAndARangeSelected() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 12, size: CGSize(width: 1440, height: 900)))
        model.seek(to: 3)
        model.addOverlay(.text)
        let text = try XCTUnwrap(model.selectedOverlay?.id)
        model.seek(to: 7)
        model.addOverlay(.highlight)
        let highlight = try XCTUnwrap(model.selectedOverlay?.id)
        model.selection = .overlay(text)
        model.toggleSelection(.overlay(highlight))
        if let zoom = model.project.zoomRegions.first { model.toggleSelection(.zoom(zoom.id)) }
        try await Self.render(VideoEditorRootView(model: model), size: full, name: "fix-13-several-selected")
        model.selection = .range(VideoDemoTimelineRange(start: 8, end: 10))
        try await Self.render(VideoEditorRootView(model: model), size: full, name: "fix-13-range-actions")
    }

    func testCrowdedCutsShareOneMarker() async throws {
        let model = try await T.make(in: directory, T.Options(seconds: 12, size: CGSize(width: 1440, height: 900)))
        let ranges: [ClosedRange<Double>] = [2.0...2.2, 2.4...2.6, 2.8...3.0, 3.2...3.4, 3.6...3.8, 8.0...8.5]
        model.mutate { _ = $0.removeSourceRanges(ranges, totalDuration: 12) }
        model.endGesture()
        model.selection = .none
        let height = 44 + 1 + VideoTimelineMetrics.contentHeight(model.project) + 10
        try await Self.render(VideoTimelineView(model: model), size: CGSize(width: 1200, height: height), name: "fix-10-grouped-restore-markers")
    }

    func testTranscriptionShowsItIsWorking() async throws {
        var options = T.Options(seconds: 4, size: CGSize(width: 1440, height: 900))
        options.audio = true
        let model = try await T.make(in: directory, options)
        model.inspectorTab = .captions
        // Older Macs: no fraction yet — a moving bar and the time spent.
        model.captionJob = VideoCaptionJob(stage: .transcribing(0), started: Date().addingTimeInterval(-42))
        try await Self.render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 560), name: "fix-08-transcribing-indeterminate")
        model.captionJob = VideoCaptionJob(stage: .transcribing(0.4), started: Date().addingTimeInterval(-65))
        try await Self.render(VideoInspectorView(model: model), size: CGSize(width: 318, height: 560), name: "fix-08-transcribing-progress")
        model.captionJob = nil
    }
}
