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
}
