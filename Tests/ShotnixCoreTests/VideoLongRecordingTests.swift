import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Long recordings (opt-in: SHOTNIX_LONG_TEST=1). A 30-minute take with a
/// realistic amount of pointer data, clicks, zooms, captions, shortcuts,
/// and cuts: every interactive edit must stay well inside a frame budget.
@MainActor
final class VideoLongRecordingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    private func time<T>(_ label: String, _ work: () throws -> T) rethrows -> (T, Double) {
        let start = CFAbsoluteTimeGetCurrent()
        let value = try work()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "LONG: %@ %.1f ms", label, ms))
        return (value, ms)
    }

    /// A pointer that wanders, pauses, and clicks like a real 30-minute demo.
    private func longPointer(duration: Double) -> ([VideoDemoCursorSample], [VideoDemoClickEvent]) {
        var samples: [VideoDemoCursorSample] = []
        var clicks: [VideoDemoClickEvent] = []
        var generator = SystemRandomNumberGenerator()
        var t = 0.0
        var x = 0.5, y = 0.5
        while t < duration {
            let targetX = Double.random(in: 0.1...0.9, using: &generator)
            let targetY = Double.random(in: 0.1...0.9, using: &generator)
            let move = Double.random(in: 0.4...1.5, using: &generator)
            let steps = Int(move * 60)
            for step in 0..<steps {
                let p = Double(step) / Double(steps)
                let eased = p * p * (3 - 2 * p)
                samples.append(VideoDemoCursorSample(time: t + Double(step) / 60, x: x + (targetX - x) * eased, y: y + (targetY - y) * eased))
            }
            t += move
            x = targetX
            y = targetY
            if Bool.random(using: &generator) {
                clicks.append(VideoDemoClickEvent(time: t, x: x, y: y, button: .left, endTime: t + 0.1))
            }
            // Idle: stationary samples every 0.25 s.
            let idle = Double.random(in: 0.5...4, using: &generator)
            var idleT = 0.25
            while idleT < idle {
                samples.append(VideoDemoCursorSample(time: t + idleT, x: x, y: y))
                idleT += 0.25
            }
            t += idle
        }
        return (samples.filter { $0.time <= duration }, clicks.filter { $0.time < duration })
    }

    func testThirtyMinuteRecordingStaysResponsive() async throws {
        guard ProcessInfo.processInfo.environment["SHOTNIX_LONG_TEST"] == "1" else {
            throw XCTSkip("Set SHOTNIX_LONG_TEST=1 to run the 30-minute recording test")
        }
        let duration = 1800.0
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-long", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("long.mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            let (_, ms) = try await timeAsync("write 30-minute recording") {
                try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 640, height: 400), seconds: duration, fps: 10, audioSeconds: duration)
            }
            _ = ms
        }
        let (samples, clicks) = longPointer(duration: duration)
        print("LONG: \(samples.count) pointer samples, \(clicks.count) clicks")
        var keystrokes: [VideoKeystrokeEvent] = []
        for index in 0..<400 { keystrokes.append(VideoKeystrokeEvent(time: Double(index) * 4.3, keys: ["⌘", index % 2 == 0 ? "C" : "V"])) }
        let metadata = VideoDemoRecordingMetadata(
            videoURLPath: url.path, createdAt: Date(), duration: duration, sourceWidth: 640, sourceHeight: 400,
            fps: 10, nativeCursorVisible: false, cursorSamples: samples, clickEvents: clicks,
            pointPixelScale: 2, renderCursor: true, keystrokes: keystrokes
        )
        VideoDemoSidecarStore.save(metadata, for: url)
        VideoDemoDraftStore.delete(for: url)

        let model = VideoEditorModel(videoURL: url)
        let loadStart = CFAbsoluteTimeGetCurrent()
        await model.load()
        print(String(format: "LONG: open (model load, auto zoom) %.0f ms", (CFAbsoluteTimeGetCurrent() - loadStart) * 1000))
        XCTAssertTrue(model.isReady)
        print("LONG: \(model.project.zoomRegions.count) auto zooms")

        // Captions for the whole take and a few dozen cuts.
        var words: [VideoCaptionWord] = []
        var t = 1.0
        while t < duration - 2 {
            words.append(VideoCaptionWord(text: "word", start: t, end: t + 0.3))
            t += Double.random(in: 0.35...0.9)
        }
        model.mutate { project in
            project.captions = VideoCaptionBuilder.lines(from: words)
        }
        for index in 1...30 {
            let cut = Double(index) * 55
            model.deleteRange(VideoDemoTimelineRange(start: cut, end: cut + 3))
        }
        print("LONG: \(model.project.captions.count) caption lines, \(model.segments.count) clips")

        // Interactive edits: each must fit comfortably in one 60 Hz frame
        // budget (plus AVFoundation's own work, which is async).
        var slider: [Double] = []
        for step in 0..<20 {
            let (_, ms) = time("padding drag step") {
                model.setStyle(coalesce: "padding") { $0.padding = 0.05 + Double(step) * 0.002 }
            }
            slider.append(ms)
        }
        model.endGesture()
        let sliderAverage = slider.reduce(0, +) / Double(slider.count)
        print(String(format: "LONG: padding drag average %.1f ms, worst %.1f ms", sliderAverage, slider.max() ?? 0))

        var zoomDrag: [Double] = []
        if let region = model.project.zoomRegions.first, let range = model.zoomTimelineRange(region) {
            for step in 0..<20 {
                let (_, ms) = time("zoom drag step") {
                    model.setZoomWindow(region.id, start: range.lowerBound + Double(step) * 0.05, end: range.upperBound + Double(step) * 0.05, coalesce: "zoom-move")
                }
                zoomDrag.append(ms)
            }
        }
        model.endGesture()
        let zoomAverage = zoomDrag.reduce(0, +) / Double(max(zoomDrag.count, 1))
        print(String(format: "LONG: zoom drag average %.1f ms, worst %.1f ms", zoomAverage, zoomDrag.max() ?? 0))

        let (_, captionMs) = time("caption edit") {
            if let id = model.project.captions.first?.id { model.updateCaption(id, text: "Edited words here") }
        }
        let (_, autosaveMs) = time("autosave") { model.saveDraftNow() }

        // Timeline layout with everything on it.
        let height = 44 + 1 + VideoTimelineMetrics.contentHeight(model.project) + 10
        let host = NSHostingView(rootView: VideoTimelineView(model: model).equatable().frame(width: 1400, height: height))
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        let (_, firstLayout) = time("timeline first layout") {
            host.layoutSubtreeIfNeeded()
            host.display()
        }
        model.setStyle(coalesce: "padding") { $0.padding = 0.08 }
        let (_, relayout) = time("timeline relayout after an edit") {
            host.layoutSubtreeIfNeeded()
            host.display()
        }

        // Which lanes cost the most?
        let saved = model.project
        for (label, strip) in [
            ("no captions", { (p: inout VideoDemoProject) in p.captions = [] }),
            ("no shortcuts", { (p: inout VideoDemoProject) in p.keystrokes = [] }),
            ("no clicks", { (p: inout VideoDemoProject) in p.clickEvents = [] }),
            ("no zooms", { (p: inout VideoDemoProject) in p.zoomRegions = [] }),
        ] as [(String, (inout VideoDemoProject) -> Void)] {
            model.mutate { project in strip(&project) }
            host.layoutSubtreeIfNeeded(); host.display()
            model.setStyle(coalesce: "padding") { $0.padding += 0.001 }
            _ = time("timeline relayout, \(label)") { host.layoutSubtreeIfNeeded(); host.display() }
            model.mutate { $0 = saved }
        }

        XCTAssertLessThan(sliderAverage, 8, "style drags stay under half a frame")
        XCTAssertLessThan(zoomAverage, 8, "zoom drags stay under half a frame")
        XCTAssertLessThan(captionMs, 16)
        XCTAssertLessThan(autosaveMs, 50)
        XCTAssertLessThan(relayout, 50, "timeline redraw after an edit")
        _ = firstLayout
        VideoDemoDraftStore.delete(for: url)
    }

    private func timeAsync<T>(_ label: String, _ work: () async throws -> T) async rethrows -> (T, Double) {
        let start = CFAbsoluteTimeGetCurrent()
        let value = try await work()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "LONG: %@ %.0f ms", label, ms))
        return (value, ms)
    }
}
