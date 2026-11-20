import AppKit
import SwiftUI
import XCTest
@testable import ShotnixCore

/// A window that's open when the appearance changes turns as a whole: it
/// ends up looking exactly like one opened in the new appearance. Nothing
/// in it (a layer's color, a drawn lane, a cached picture) keeps the old one.
@MainActor
final class AppearanceLiveSwitchTests: XCTestCase {

    private let light = NSAppearance(named: .aqua)!
    private let dark = NSAppearance(named: .darkAqua)!

    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    override func tearDown() {
        NSApplication.shared.appearance = NSAppearance(named: TestAppearance.name)
        super.tearDown()
    }

    // MARK: Rendering

    /// Shows `view` in a window in `first`, then (if given) turns the window
    /// to `second`, and returns what it looks like at the end.
    private func picture(of view: NSView, first: NSAppearance, then second: NSAppearance?) throws -> NSBitmapImageRep {
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = first
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        view.layoutSubtreeIfNeeded()
        // Drawn once in the first appearance, as an open window is.
        let warmUp = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: warmUp)
        if let second {
            window.appearance = second
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            view.layoutSubtreeIfNeeded()
        }
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        window.contentView = nil
        return rep
    }

    private func host<V: View>(_ view: V, size: CGSize) -> NSView {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        return host
    }

    /// The share of pixels that differ visibly between two pictures.
    private func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) throws -> Double {
        XCTAssertEqual(a.pixelsWide, b.pixelsWide)
        XCTAssertEqual(a.pixelsHigh, b.pixelsHigh)
        let x = try XCTUnwrap(a.bitmapData), y = try XCTUnwrap(b.bitmapData)
        let samples = a.samplesPerPixel
        var different = 0
        for row in 0..<a.pixelsHigh {
            for column in 0..<a.pixelsWide {
                let i = row * a.bytesPerRow + column * samples
                let j = row * b.bytesPerRow + column * samples
                var most = 0
                for channel in 0..<min(samples, 3) { most = max(most, abs(Int(x[i + channel]) - Int(y[j + channel]))) }
                if most > 12 { different += 1 }
            }
        }
        return Double(different) / Double(a.pixelsWide * a.pixelsHigh)
    }

    private func brightness(_ rep: NSBitmapImageRep) throws -> Double {
        let data = try XCTUnwrap(rep.bitmapData)
        var total = 0.0
        var count = 0.0
        for row in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for column in stride(from: 0, to: rep.pixelsWide, by: 4) {
                let i = row * rep.bytesPerRow + column * rep.samplesPerPixel
                total += (0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2])) / 255
                count += 1
            }
        }
        return total / count
    }

    /// Turned from one appearance to the other, both ways, a view matches
    /// one opened in the appearance it ends in.
    private func assertTurnsCompletely(_ name: String, tolerance: Double = 0.002, file: StaticString = #filePath, line: UInt = #line, _ make: () -> NSView) throws {
        let openedLight = try picture(of: make(), first: light, then: nil)
        let openedDark = try picture(of: make(), first: dark, then: nil)
        XCTAssertGreaterThan(try brightness(openedLight), try brightness(openedDark) + 0.3, "\(name) is light in the light and dark in the dark", file: file, line: line)

        let turnedLight = try picture(of: make(), first: dark, then: light)
        XCTAssertLessThanOrEqual(try difference(turnedLight, openedLight), tolerance, "\(name), turned light while open, kept something dark", file: file, line: line)

        let turnedDark = try picture(of: make(), first: light, then: dark)
        XCTAssertLessThanOrEqual(try difference(turnedDark, openedDark), tolerance, "\(name), turned dark while open, kept something light", file: file, line: line)
    }

    // MARK: Windows

    func testSettingsTurnCompletely() throws {
        try assertTurnsCompletely("Settings") {
            host(ZStack { ShotnixHUDBackground(); GeneralSettingsView() }, size: CGSize(width: 560, height: 900))
        }
    }

    func testTheScreenshotEditorsToolbarTurnsCompletely() throws {
        try assertTurnsCompletely("the screenshot editor's toolbar") {
            let stage = NSView(frame: NSRect(x: 0, y: 0, width: AnnotationToolbar.requiredWidth + 40, height: AnnotationToolbar.height + 40))
            let toolbar = AnnotationToolbar(frame: NSRect(x: 20, y: 20, width: AnnotationToolbar.requiredWidth, height: AnnotationToolbar.height))
            stage.addSubview(toolbar)
            return stage
        }
    }

    func testTheVideoEditorTurnsCompletely() async throws {
        let model = try await demoModel()
        model.seek(to: 4)
        model.addOverlay(.highlight)
        model.seek(to: 4.5)
        model.addOverlay(.text)
        model.seek(to: 8)
        model.addOverlay(.blur)
        model.selection = .none
        let timelineHeight = 44 + 1 + VideoTimelineMetrics.contentHeight(model.project) + 10
        try assertTurnsCompletely("the timeline") {
            host(VideoTimelineView(model: model), size: CGSize(width: 1400, height: timelineHeight))
        }
        try assertTurnsCompletely("the inspector") {
            host(VideoInspectorView(model: model), size: CGSize(width: 318, height: 900))
        }
        model.isExportPresented = true
        try assertTurnsCompletely("the export sheet") {
            host(VideoExportSheet(model: model), size: CGSize(width: 900, height: 760))
        }
        model.isExportPresented = false
    }

    private func demoModel() async throws -> VideoEditorModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-appearance", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("appearance.mp4")
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
}
