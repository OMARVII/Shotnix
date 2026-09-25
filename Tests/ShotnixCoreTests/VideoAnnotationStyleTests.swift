import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import ShotnixCore

@MainActor
final class VideoAnnotationStyleTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        VideoTestStorage.isolate()
    }

    override func tearDown() {
        for kind in VideoDemoOverlayEffectKind.allCases {
            VideoOverlayStyleMemory.setColor(nil, for: kind)
            UserDefaults.standard.removeObject(forKey: "videoOverlayThickness.\(kind.rawValue)")
        }
        super.tearDown()
    }

    private func average(_ image: CIImage, in rect: CGRect) -> (r: Double, g: Double, b: Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)]), toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    private func minimum(_ image: CIImage, in rect: CGRect) -> (r: Double, g: Double, b: Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(image.applyingFilter("CIAreaMinimum", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)]), toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    private func project(_ effects: [VideoDemoOverlayEffect]) -> VideoDemoProject {
        var project = VideoDemoProject.make(sourceURL: URL(fileURLWithPath: "/tmp/style.mp4"), duration: 5, sourceSize: CGSize(width: 1920, height: 1080))
        project.cursor.visible = false
        project.padding = 0
        project.overlayEffects = effects
        return project
    }

    func testOldProjectsStillLoad() throws {
        let json = #"{"id":"6A1D2E3F-0000-4000-8000-000000000001","kind":"arrow","time":1,"duration":2,"x":0.5,"y":0.5,"width":0.2,"height":0.2,"text":"Arrow","layer":0}"#
        let effect = try JSONDecoder().decode(VideoDemoOverlayEffect.self, from: Data(json.utf8))
        XCTAssertNil(effect.color)
        XCTAssertEqual(effect.thickness, .regular)
        XCTAssertEqual(effect.resolvedColor, VideoDemoOverlayEffectKind.arrow.defaultColor)
        // And the new fields survive a round trip.
        var colored = effect
        colored.color = VideoRGBA(hex: 0xFF453A)
        colored.thickness = .bold
        let again = try JSONDecoder().decode(VideoDemoOverlayEffect.self, from: JSONEncoder().encode(colored))
        XCTAssertEqual(again.color, VideoRGBA(hex: 0xFF453A))
        XCTAssertEqual(again.thickness, .bold)
    }

    func testArrowUsesItsColorAndThickness() {
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        func render(_ color: VideoRGBA?, _ thickness: VideoOverlayThickness) -> CIImage {
            let effect = VideoDemoOverlayEffect(kind: .arrow, time: 0, duration: 5, x: 0.5, y: 0.5, width: 0.4, height: 0.4, color: color, thickness: thickness)
            let plan = VideoDemoExporter.makePlan(project: project([effect]), sourceDuration: 5, recording: nil)
            return VideoFrameRenderer().render(source: white, timelineTime: 2, plan: plan, outputSize: CGSize(width: 1920, height: 1080))
        }
        // The shaft runs through the middle of the box: its most saturated
        // pixel there is the ink.
        let probe = CGRect(x: 940, y: 520, width: 40, height: 40)
        let red = minimum(render(VideoRGBA(hex: 0xFF453A), .regular), in: probe)
        XCTAssertLessThan(red.g, 0.45, "red, not the default yellow")
        let yellow = minimum(render(nil, .regular), in: probe)
        XCTAssertGreaterThan(yellow.g, 0.75, "default stays yellow")
        XCTAssertLessThan(yellow.b, 0.3)
        // Bold covers more of a wider probe than thin.
        let wide = CGRect(x: 900, y: 480, width: 120, height: 120)
        let bold = average(render(VideoRGBA(hex: 0x0A84FF), .bold), in: wide)
        let thin = average(render(VideoRGBA(hex: 0x0A84FF), .thin), in: wide)
        XCTAssertLessThan(bold.r, thin.r, "more blue ink when bold")
    }

    func testTextTagColorsAndNoBackground() throws {
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        func render(_ color: VideoRGBA?) -> CIImage {
            let effect = VideoDemoOverlayEffect(kind: .text, time: 0, duration: 5, x: 0.5, y: 0.5, width: 0.5, height: 0.12, text: "Hi", color: color)
            let plan = VideoDemoExporter.makePlan(project: project([effect]), sourceDuration: 5, recording: nil)
            return VideoFrameRenderer().render(source: gray, timelineTime: 2, plan: plan, outputSize: CGSize(width: 1920, height: 1080))
        }
        // Inside the tag, beside the short word: tag color or the video.
        let beside = CGRect(x: 1020, y: 530, width: 12, height: 12)
        let blueTag = average(render(VideoRGBA(hex: 0x0A84FF)), in: beside)
        XCTAssertGreaterThan(blueTag.b, 0.8)
        let none = average(render(VideoRGBA(0, 0, 0, 0)), in: beside)
        XCTAssertEqual(none.r, 0.5, accuracy: 0.08, "no tag: the video shows through")
        let defaultTag = average(render(nil), in: beside)
        XCTAssertLessThan(defaultTag.r, 0.3, "default dark tag")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-render-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let screen = CIImage(cgImage: VideoTestSupport.fakeScreen(size: CGSize(width: 2880, height: 1800), progress: 0.4, typed: "Hello"))
        let effects = [
            VideoDemoOverlayEffect(kind: .arrow, time: 0, duration: 5, x: 0.3, y: 0.35, width: 0.16, height: 0.2, color: VideoRGBA(hex: 0xFF453A), thickness: .bold),
            VideoDemoOverlayEffect(kind: .highlight, time: 0, duration: 5, x: 0.7, y: 0.4, width: 0.3, height: 0.12, color: VideoRGBA(hex: 0x30D158)),
            VideoDemoOverlayEffect(kind: .text, time: 0, duration: 5, x: 0.5, y: 0.8, width: 0.5, height: 0.09, text: "Blue tag, light text", color: VideoRGBA(hex: 0x0A84FF)),
            VideoDemoOverlayEffect(kind: .text, time: 0, duration: 5, x: 0.5, y: 0.9, width: 0.5, height: 0.08, text: "Text with no background", color: VideoRGBA(0, 0, 0, 0)),
            VideoDemoOverlayEffect(kind: .text, time: 0, duration: 5, x: 0.5, y: 0.12, width: 0.4, height: 0.08, text: "Yellow tag, dark text", color: VideoRGBA(hex: 0xFFD60A)),
        ]
        var styled = project(effects)
        styled.sourceWidth = 2880
        styled.sourceHeight = 1800
        let plan = VideoDemoExporter.makePlan(project: styled, sourceDuration: 5, recording: nil)
        let image = VideoFrameRenderer().render(source: screen, timelineTime: 2, plan: plan, outputSize: CGSize(width: 1920, height: 1200))
        let url = dir.appendingPathComponent("annotation-colors.png")
        try VideoTestSupport.writePNG(image, size: CGSize(width: 1920, height: 1200), to: url)
        print("SNAPSHOT: \(url.path)")
    }

    func testNewAnnotationsLandWhereTheyCanBeSeen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-place-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rec.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 1280, height: 800), seconds: 6, fps: 30)
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        // A 2.5× zoom aimed at the top-left corner.
        model.mutate { project in
            project.zoomRegions = [VideoZoomRegion(start: 0, end: 6, scale: 2.5, followsCursor: false, focusX: 0.2, focusY: 0.2)]
        }
        model.seek(to: 3)
        let visible = model.visibleRegion(at: 3)
        XCTAssertLessThan(visible.width, 0.6, "only part of the frame shows")
        for kind in [VideoDemoOverlayEffectKind.text, .arrow, .highlight, .blur] {
            model.addOverlay(kind)
            let effect = try XCTUnwrap(model.selectedOverlay)
            let box = CGRect(x: effect.x - effect.width / 2, y: effect.y - effect.height / 2, width: effect.width, height: effect.height)
            XCTAssertTrue(visible.insetBy(dx: -0.001, dy: -0.001).contains(box), "\(kind) lands on screen: \(box) in \(visible)")
        }
        // Without a zoom, the defaults are unchanged.
        model.mutate { $0.zoomRegions = [] }
        XCTAssertEqual(model.visibleRegion(at: 3), CGRect(x: 0, y: 0, width: 1, height: 1))
        model.addOverlay(.text)
        XCTAssertEqual(model.selectedOverlay?.y ?? 0, 0.14, accuracy: 0.001, "text goes near the top, clear of captions and keycaps")
        XCTAssertEqual(model.selectedOverlay?.width ?? 0, 0.5, accuracy: 0.001)
        VideoDemoDraftStore.delete(for: url)
    }

    func testTheEditedAnnotationShowsAtItsFirstFrame() {
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let effect = VideoDemoOverlayEffect(kind: .highlight, time: 2, duration: 3, x: 0.5, y: 0.5, width: 0.4, height: 0.4, color: VideoRGBA(hex: 0xFF453A))
        let plan = VideoDemoExporter.makePlan(project: project([effect]), sourceDuration: 5, recording: nil)
        let edge = CGRect(x: 574, y: 530, width: 12, height: 20)
        var options = VideoFrameRenderer.Options()
        let faded = minimum(VideoFrameRenderer().render(source: white, timelineTime: 2, plan: plan, outputSize: CGSize(width: 1920, height: 1080), options: options), in: edge)
        XCTAssertGreaterThan(faded.g, 0.9, "exports still fade in")
        options.solidOverlay = effect.id
        let solid = minimum(VideoFrameRenderer().render(source: white, timelineTime: 2, plan: plan, outputSize: CGSize(width: 1920, height: 1080), options: options), in: edge)
        XCTAssertLessThan(solid.g, 0.5, "the one being edited shows right away")
    }

    func testHalfwayThroughAFadeIsHalfVisible() {
        let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let effect = VideoDemoOverlayEffect(kind: .arrow, time: 1, duration: 3, x: 0.5, y: 0.5, width: 0.4, height: 0.4, color: VideoRGBA(hex: 0xFFFFFF), thickness: .bold)
        let plan = VideoDemoExporter.makePlan(project: project([effect]), sourceDuration: 5, recording: nil)
        func brightest(at time: Double) -> Double {
            let image = VideoFrameRenderer().render(source: black, timelineTime: time, plan: plan, outputSize: CGSize(width: 1920, height: 1080))
            var pixel = [UInt8](repeating: 0, count: 4)
            CIContext().render(image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: 900, y: 480, width: 120, height: 120))]), toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return Double(pixel[0]) / 255
        }
        XCTAssertGreaterThan(brightest(at: 2.5), 0.95)
        // Half opacity over black: linear 0.5 is sRGB 0.735 (not 0.54, which
        // is what applying the opacity twice gives).
        XCTAssertEqual(brightest(at: 1.09), 0.735, accuracy: 0.05)
    }

    func testPickedColorBecomesTheDefault() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-style-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rec.mp4")
        try await VideoTestSupport.writeFakeRecording(to: url, size: CGSize(width: 640, height: 400), seconds: 4, fps: 30)
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        model.addOverlay(.arrow)
        let first = try XCTUnwrap(model.selectedOverlay)
        XCTAssertNil(first.color)
        model.setOverlayColor(first.id, VideoRGBA(hex: 0x0A84FF))
        model.setOverlayThickness(first.id, .bold)
        model.seek(to: 2)
        model.addOverlay(.arrow)
        let second = try XCTUnwrap(model.selectedOverlay)
        XCTAssertEqual(second.color, VideoRGBA(hex: 0x0A84FF), "new arrows start with the last color")
        XCTAssertEqual(second.thickness, .bold)
        // Other kinds keep their own defaults.
        model.addOverlay(.highlight)
        XCTAssertNil(model.selectedOverlay?.color)
        // Undo restores the old color in one step.
        model.selection = .overlay(first.id)
        model.setOverlayColor(first.id, VideoRGBA(hex: 0xFF453A))
        model.undo()
        XCTAssertEqual(model.project.overlayEffects.first { $0.id == first.id }?.color, VideoRGBA(hex: 0x0A84FF))

        // The color panel recolors the selected annotation, one undo step
        // for a whole drag, and stops once it's deselected.
        model.selection = .overlay(first.id)
        var forwarded: [VideoRGBA] = []
        VideoColorPanel.shared.open(color: NSColor.systemBlue, showsAlpha: false) { forwarded.append($0) }
        XCTAssertTrue(forwarded.isEmpty, "opening doesn't recolor")
        NSColorPanel.shared.color = NSColor(srgbRed: 0.2, green: 0.8, blue: 0.4, alpha: 1)
        XCTAssertEqual(forwarded.count, 1)
        XCTAssertEqual(forwarded.first?.g ?? 0, 0.8, accuracy: 0.01)
        NSColorPanel.shared.close()

        // The inspector with the color picker.
        model.selection = .overlay(first.id)
        let host = NSHostingView(rootView: VideoInspectorView(model: model).frame(width: 318, height: 520).environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 318, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-inspector-annotation-color.png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: snapshot)
        print("SNAPSHOT: \(snapshot.path)")
        VideoDemoDraftStore.delete(for: url)
    }
}
