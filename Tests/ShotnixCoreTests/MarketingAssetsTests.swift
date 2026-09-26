import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import ShotnixCore

/// Renders shotnix.com's product visuals with the real app: a demo video
/// exported by the real exporter and editor screenshots drawn by the real
/// UI and renderer. Opt-in:
/// SHOTNIX_MARKETING_DIR=/path swift test --filter MarketingAssetsTests
@MainActor
final class MarketingAssetsTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        // The website is in English: "14.6 MB", not the Mac's own locale.
        UserDefaults.standard.setVolatileDomain(["AppleLocale": "en_US", "AppleLanguages": ["en-US"]], forName: UserDefaults.argumentDomain)
        VideoTestStorage.isolate()
        VideoStageView.drawsStills = true
    }

    override class func tearDown() {
        VideoStageView.drawsStills = false
        super.tearDown()
    }

    private var output: URL!
    private var work: URL!

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["SHOTNIX_MARKETING_DIR"] else {
            throw XCTSkip("Set SHOTNIX_MARKETING_DIR to render the website visuals")
        }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        work = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-marketing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        UserDefaults.standard.set(true, forKey: "videoEditorTipsDismissed")
        // Never publish this Mac's own desktop pictures (or its wallpaper).
        VideoSwatchCache.shared.systemWallpapers = []
    }

    override func tearDown() async throws {
        if let work { try? FileManager.default.removeItem(at: work) }
    }

    // MARK: The demo "app": an analytics dashboard

    /// Layout in a 1440×900 design space.
    private enum Layout {
        static let window = CGRect(x: 90, y: 60, width: 1260, height: 790)
        static let sidebarWidth: CGFloat = 212
        static var content: CGRect { CGRect(x: window.minX + sidebarWidth + 36, y: window.minY + 70, width: window.width - sidebarWidth - 72, height: window.height - 100) }
        static func card(_ index: Int) -> CGRect {
            let gap: CGFloat = 18
            let width = (content.width - gap * 3) / 4
            return CGRect(x: content.minX + CGFloat(index) * (width + gap), y: content.minY + 64, width: width, height: 108)
        }
        static var chart: CGRect { CGRect(x: content.minX, y: content.minY + 192, width: content.width, height: 290) }
        static var plot: CGRect { chart.insetBy(dx: 34, dy: 0).offsetBy(dx: 0, dy: 0).divided(atDistance: 62, from: .minYEdge).remainder.divided(atDistance: 40, from: .maxYEdge).remainder }
        static let values: [CGFloat] = [5.1, 6.4, 5.8, 8.24, 7.1, 7.9, 7.6]
        static let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        static func point(_ index: Int) -> CGPoint {
            let x = plot.minX + plot.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = plot.maxY - plot.height * (values[index] - 4) / 5
            return CGPoint(x: x, y: y)
        }
        static var table: CGRect { CGRect(x: content.minX, y: chart.maxY + 20, width: content.width, height: 168) }
        static var palette: CGRect { CGRect(x: window.midX - 230, y: window.minY + 150, width: 460, height: 238) }
        static func paletteRow(_ index: Int) -> CGRect { CGRect(x: palette.minX + 10, y: palette.minY + 62 + CGFloat(index) * 42, width: palette.width - 20, height: 38) }
        /// Design point → video-normalized (the recording is the window).
        static func normalized(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - window.minX) / window.width, y: (point.y - window.minY) / window.height) }
    }

    private struct ScreenState: Hashable {
        var selectedCard: Int?
        var tooltip = false
        var palette = false
        var paletteHover = false
        var toast = false
    }

    private func state(at t: Double) -> ScreenState {
        var state = ScreenState()
        if t >= 2.2 { state.selectedCard = 0 }
        if t >= 4.8 { state.tooltip = true }
        if t >= 8.15 && t < 9.75 { state.palette = true }
        if t >= 9.15 && t < 9.75 { state.paletteHover = true }
        if t >= 9.8 { state.toast = true }
        return state
    }

    private func dashboard(size: CGSize, state: ScreenState) -> CGImage {
        let width = Int(size.width)
        let height = Int(size.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let unit = size.width / Layout.window.width
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: unit, y: unit)
        context.translateBy(x: -Layout.window.minX, y: -Layout.window.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let ink = NSColor(srgbRed: 0.09, green: 0.1, blue: 0.13, alpha: 1)
        let muted = NSColor(srgbRed: 0.45, green: 0.47, blue: 0.53, alpha: 1)
        let line = NSColor(srgbRed: 0.9, green: 0.91, blue: 0.93, alpha: 1)
        let brand = NSColor(srgbRed: 0.33, green: 0.36, blue: 0.95, alpha: 1)
        let good = NSColor(srgbRed: 0.1, green: 0.62, blue: 0.4, alpha: 1)

        // A window recording: the window is the whole frame.
        let window = Layout.window
        NSColor.white.setFill()
        window.fill()
        NSGraphicsContext.saveGraphicsState()

        // Sidebar.
        let sidebar = CGRect(x: window.minX, y: window.minY, width: Layout.sidebarWidth, height: window.height)
        NSColor(srgbRed: 0.965, green: 0.968, blue: 0.978, alpha: 1).setFill()
        sidebar.fill()
        line.setFill()
        CGRect(x: sidebar.maxX - 1, y: sidebar.minY, width: 1, height: sidebar.height).fill()
        for (index, color) in [NSColor.systemRed, NSColor.systemYellow, NSColor.systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: window.minX + 18 + CGFloat(index) * 20, y: window.minY + 18, width: 12, height: 12)).fill()
        }
        brand.setFill()
        NSBezierPath(roundedRect: CGRect(x: sidebar.minX + 20, y: sidebar.minY + 56, width: 26, height: 26), xRadius: 7, yRadius: 7).fill()
        draw("Northwind", at: CGPoint(x: sidebar.minX + 56, y: sidebar.minY + 59), size: 16, weight: .bold, color: ink)
        let nav = ["Overview", "Revenue", "Customers", "Orders", "Reports", "Settings"]
        for (index, item) in nav.enumerated() {
            let y = sidebar.minY + 112 + CGFloat(index) * 40
            if index == 0 {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: CGRect(x: sidebar.minX + 12, y: y - 8, width: sidebar.width - 24, height: 34), xRadius: 8, yRadius: 8).fill()
            }
            (index == 0 ? brand : NSColor(srgbRed: 0.7, green: 0.72, blue: 0.78, alpha: 1)).setFill()
            NSBezierPath(roundedRect: CGRect(x: sidebar.minX + 26, y: y + 1, width: 16, height: 16), xRadius: 4, yRadius: 4).fill()
            draw(item, at: CGPoint(x: sidebar.minX + 54, y: y), size: 14, weight: index == 0 ? .semibold : .medium, color: index == 0 ? ink : muted)
        }

        // Header.
        let content = Layout.content
        draw("Overview", at: CGPoint(x: content.minX, y: content.minY - 6), size: 28, weight: .bold, color: ink)
        let pill = CGRect(x: content.maxX - 132, y: content.minY - 2, width: 132, height: 34)
        line.setStroke()
        let pillPath = NSBezierPath(roundedRect: pill, xRadius: 17, yRadius: 17)
        pillPath.lineWidth = 1
        pillPath.stroke()
        draw("Last 7 days", at: CGPoint(x: pill.minX + 26, y: pill.minY + 8), size: 13.5, weight: .semibold, color: ink)
        let search = CGRect(x: pill.minX - 256, y: content.minY - 2, width: 240, height: 34)
        NSColor(srgbRed: 0.965, green: 0.968, blue: 0.978, alpha: 1).setFill()
        NSBezierPath(roundedRect: search, xRadius: 9, yRadius: 9).fill()
        draw("Search   ⌘K", at: CGPoint(x: search.minX + 14, y: search.minY + 8), size: 13.5, weight: .medium, color: muted)

        // KPI cards.
        let cards: [(String, String, String)] = [("Revenue", "$48,290", "+12.4%"), ("Active users", "3,815", "+5.1%"), ("Conversion", "4.7%", "+0.6 pt"), ("Refunds", "0.9%", "−0.3 pt")]
        for (index, card) in cards.enumerated() {
            let rect = Layout.card(index)
            let selected = state.selectedCard == index
            (selected ? brand.withAlphaComponent(0.06) : NSColor.white).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            (selected ? brand : line).setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            border.lineWidth = selected ? 2 : 1
            border.stroke()
            draw(card.0, at: CGPoint(x: rect.minX + 18, y: rect.minY + 16), size: 13.5, weight: .medium, color: muted)
            draw(card.1, at: CGPoint(x: rect.minX + 18, y: rect.minY + 40), size: 27, weight: .bold, color: ink)
            draw(card.2, at: CGPoint(x: rect.minX + 18, y: rect.minY + 78), size: 13, weight: .semibold, color: good)
        }

        // Chart.
        let chart = Layout.chart
        NSColor.white.setFill()
        NSBezierPath(roundedRect: chart, xRadius: 12, yRadius: 12).fill()
        line.setStroke()
        let chartBorder = NSBezierPath(roundedRect: chart.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        chartBorder.lineWidth = 1
        chartBorder.stroke()
        draw("Revenue this week", at: CGPoint(x: chart.minX + 20, y: chart.minY + 18), size: 16, weight: .bold, color: ink)
        draw("Daily revenue, in thousands of dollars", at: CGPoint(x: chart.minX + 20, y: chart.minY + 40), size: 12.5, weight: .medium, color: muted)
        let plot = Layout.plot
        for step in 0...4 {
            let y = plot.minY + plot.height * CGFloat(step) / 4
            line.setFill()
            CGRect(x: plot.minX, y: y, width: plot.width, height: 1).fill()
        }
        let area = NSBezierPath()
        area.move(to: CGPoint(x: Layout.point(0).x, y: plot.maxY))
        for index in Layout.values.indices { area.line(to: Layout.point(index)) }
        area.line(to: CGPoint(x: Layout.point(Layout.values.count - 1).x, y: plot.maxY))
        area.close()
        NSGradient(colors: [brand.withAlphaComponent(0.28), brand.withAlphaComponent(0.02)])!.draw(in: area, angle: -90)
        let stroke = NSBezierPath()
        for index in Layout.values.indices {
            index == 0 ? stroke.move(to: Layout.point(index)) : stroke.line(to: Layout.point(index))
        }
        brand.setStroke()
        stroke.lineWidth = 3
        stroke.lineJoinStyle = .round
        stroke.stroke()
        for (index, day) in Layout.days.enumerated() {
            let p = Layout.point(index)
            draw(day, at: CGPoint(x: p.x - 14, y: plot.maxY + 14), size: 12.5, weight: .medium, color: muted)
            NSColor.white.setFill()
            let dot = NSBezierPath(ovalIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
            dot.fill()
            brand.setStroke()
            dot.lineWidth = 2.5
            dot.stroke()
        }
        if state.tooltip {
            let p = Layout.point(3)
            NSColor(srgbRed: 0.33, green: 0.36, blue: 0.95, alpha: 0.22).setFill()
            CGRect(x: p.x - 1, y: plot.minY, width: 2, height: plot.height).fill()
            let bubble = CGRect(x: p.x - 78, y: p.y - 88, width: 156, height: 64)
            ink.setFill()
            NSBezierPath(roundedRect: bubble, xRadius: 10, yRadius: 10).fill()
            draw("Thursday", at: CGPoint(x: bubble.minX + 14, y: bubble.minY + 10), size: 12, weight: .semibold, color: NSColor.white.withAlphaComponent(0.7))
            draw("$8,240  ·  +18%", at: CGPoint(x: bubble.minX + 14, y: bubble.minY + 30), size: 16, weight: .bold, color: .white)
        }

        // Table.
        let table = Layout.table
        NSColor.white.setFill()
        NSBezierPath(roundedRect: table, xRadius: 12, yRadius: 12).fill()
        line.setStroke()
        let tableBorder = NSBezierPath(roundedRect: table.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        tableBorder.lineWidth = 1
        tableBorder.stroke()
        draw("Recent orders", at: CGPoint(x: table.minX + 20, y: table.minY + 16), size: 15, weight: .bold, color: ink)
        let rows: [(String, String, String, String)] = [("Maya Chen", "Team plan", "$1,240", "Paid"), ("Lucas Moreau", "Pro plan", "$480", "Paid"), ("Aiko Tanaka", "Team plan", "$1,240", "Pending")]
        for (index, row) in rows.enumerated() {
            let y = table.minY + 52 + CGFloat(index) * 36
            line.setFill()
            CGRect(x: table.minX + 20, y: y - 6, width: table.width - 40, height: 1).fill()
            draw(row.0, at: CGPoint(x: table.minX + 20, y: y + 4), size: 13.5, weight: .semibold, color: ink)
            draw(row.1, at: CGPoint(x: table.minX + 300, y: y + 4), size: 13.5, weight: .medium, color: muted)
            draw(row.2, at: CGPoint(x: table.minX + 520, y: y + 4), size: 13.5, weight: .semibold, color: ink)
            let paid = row.3 == "Paid"
            let status = CGRect(x: table.maxX - 104, y: y + 1, width: 72, height: 24)
            (paid ? good.withAlphaComponent(0.12) : NSColor.systemOrange.withAlphaComponent(0.14)).setFill()
            NSBezierPath(roundedRect: status, xRadius: 12, yRadius: 12).fill()
            draw(row.3, at: CGPoint(x: status.minX + (paid ? 20 : 12), y: status.minY + 4), size: 12.5, weight: .semibold, color: paid ? good : NSColor.systemOrange)
        }

        // Command palette.
        if state.palette {
            NSColor.black.withAlphaComponent(0.18).setFill()
            window.fill()
            let palette = Layout.palette
            NSGraphicsContext.saveGraphicsState()
            let paletteShadow = NSShadow()
            paletteShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            paletteShadow.shadowBlurRadius = 24
            paletteShadow.shadowOffset = NSSize(width: 0, height: -8)
            paletteShadow.set()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: palette, xRadius: 14, yRadius: 14).fill()
            NSGraphicsContext.restoreGraphicsState()
            draw("Export", at: CGPoint(x: palette.minX + 20, y: palette.minY + 20), size: 17, weight: .semibold, color: ink)
            line.setFill()
            CGRect(x: palette.minX, y: palette.minY + 54, width: palette.width, height: 1).fill()
            let items = ["Export weekly report (PDF)", "Export orders (CSV)", "Export chart as image", "Schedule a weekly email"]
            for (index, item) in items.enumerated() {
                let row = Layout.paletteRow(index)
                if index == 0 {
                    (state.paletteHover ? brand : brand.withAlphaComponent(0.1)).setFill()
                    NSBezierPath(roundedRect: row, xRadius: 8, yRadius: 8).fill()
                }
                draw(item, at: CGPoint(x: row.minX + 14, y: row.minY + 10), size: 14, weight: .medium, color: index == 0 && state.paletteHover ? .white : ink)
            }
        }

        // "Exported" toast.
        if state.toast {
            let toast = CGRect(x: window.midX - 132, y: window.minY + 14, width: 264, height: 42)
            ink.setFill()
            NSBezierPath(roundedRect: toast, xRadius: 21, yRadius: 21).fill()
            good.setFill()
            NSBezierPath(ovalIn: CGRect(x: toast.minX + 14, y: toast.minY + 11, width: 20, height: 20)).fill()
            let check = NSBezierPath()
            check.move(to: CGPoint(x: toast.minX + 19, y: toast.minY + 21))
            check.line(to: CGPoint(x: toast.minX + 23, y: toast.minY + 25))
            check.line(to: CGPoint(x: toast.minX + 29.5, y: toast.minY + 17))
            NSColor.white.setStroke()
            check.lineWidth = 2.2
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()
            draw("Weekly report exported", at: CGPoint(x: toast.minX + 44, y: toast.minY + 11), size: 14.5, weight: .semibold, color: .white)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    private func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]).draw(at: point)
    }

    // MARK: Recording

    private let seconds = 12.8
    private let size = CGSize(width: 2520, height: 1580)

    /// Where the pointer is at each moment (video-normalized); it rests
    /// between keys at the same spot and glides between different ones.
    private func pointerKeys() -> [(time: Double, point: CGPoint)] {
        let start = CGPoint(x: 0.64, y: 0.72)
        let card = Layout.normalized(CGPoint(x: Layout.card(0).midX + 10, y: Layout.card(0).midY + 6))
        let thursday = Layout.normalized(Layout.point(3))
        let rest = CGPoint(x: thursday.x + 0.02, y: thursday.y + 0.07)
        let row = Layout.normalized(CGPoint(x: Layout.paletteRow(0).midX - 40, y: Layout.paletteRow(0).midY))
        let end = CGPoint(x: 0.57, y: 0.53)
        return [(0, start), (0.6, start), (2.0, card), (2.5, card), (4.6, thursday), (5.1, thursday), (5.7, rest), (8.4, rest), (9.3, row), (9.9, row), (11.0, end), (seconds, end)]
    }

    private let clickTimes = [2.12, 4.72, 9.42]

    private func pointer() -> ([VideoDemoCursorSample], [VideoDemoClickEvent]) {
        let keys = pointerKeys()
        func position(at t: Double) -> CGPoint {
            guard let index = keys.lastIndex(where: { $0.time <= t }), index + 1 < keys.count else { return keys.last!.point }
            let (a, b) = (keys[index], keys[index + 1])
            guard a.point != b.point else { return a.point }
            let u = (t - a.time) / (b.time - a.time)
            let eased = u * u * (3 - 2 * u)
            let distance = hypot(b.point.x - a.point.x, b.point.y - a.point.y)
            // A slight arc, like a real hand.
            let arc = sin(u * .pi) * distance * 0.12
            return CGPoint(x: a.point.x + (b.point.x - a.point.x) * eased, y: a.point.y + (b.point.y - a.point.y) * eased - arc)
        }
        var samples: [VideoDemoCursorSample] = []
        for index in 0...Int(seconds * 60) {
            let t = Double(index) / 60
            var point = position(at: t)
            point.x += sin(t * 37) * 0.0004
            point.y += cos(t * 29) * 0.0004
            samples.append(VideoDemoCursorSample(time: t, x: point.x, y: point.y))
        }
        let clicks = clickTimes.map { time -> VideoDemoClickEvent in
            let point = position(at: time)
            return VideoDemoClickEvent(time: time, x: point.x, y: point.y, button: .left, endTime: time + 0.1)
        }
        return (samples, clicks)
    }

    private func writeRecording(to url: URL) async throws -> VideoDemoRecordingMetadata {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 30_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let fps = 30
        var cache: [ScreenState: CGImage] = [:]
        for frame in 0..<Int(seconds * Double(fps)) {
            let t = Double(frame) / Double(fps)
            let screen = state(at: t)
            let image = cache[screen] ?? dashboard(size: size, state: screen)
            cache[screen] = image
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            context?.draw(image, in: CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")

        let (samples, clicks) = pointer()
        func shape(_ cursor: NSCursor, id: String) -> VideoCursorShape? {
            let reps = cursor.image.representations.compactMap { $0 as? NSBitmapImageRep }
            guard let largest = reps.max(by: { $0.pixelsWide < $1.pixelsWide }), let png = largest.representation(using: .png, properties: [:]) else { return nil }
            return VideoCursorShape(id: id, hotSpotX: cursor.hotSpot.x, hotSpotY: cursor.hotSpot.y, width: cursor.image.size.width, height: cursor.image.size.height, pngData: png)
        }
        let shapes = [shape(.arrow, id: "arrow"), shape(.pointingHand, id: "hand")].compactMap { $0 }
        // The hand over things you can click.
        let events = [(0, "arrow"), (1.85, "hand"), (2.55, "arrow"), (4.45, "hand"), (5.15, "arrow"), (9.15, "hand"), (9.85, "arrow")]
            .map { VideoCursorShapeEvent(time: $0.0, shapeID: $0.1) }
        var metadata = VideoDemoRecordingMetadata(
            videoURLPath: url.path, createdAt: Date(), duration: seconds, sourceWidth: Double(size.width), sourceHeight: Double(size.height), fps: fps,
            nativeCursorVisible: false, cursorSamples: samples, clickEvents: clicks, pointPixelScale: 2,
            cursorShapes: shapes, cursorShapeEvents: events, renderCursor: true
        )
        metadata.keystrokes = [VideoKeystrokeEvent(time: 8.1, keys: ["⌘", "K"])]
        XCTAssertTrue(VideoDemoSidecarStore.save(metadata, for: url))
        return metadata
    }

    private func captions() -> [VideoCaptionLine] {
        func line(_ text: String, from start: Double, to end: Double) -> [VideoCaptionWord] {
            let parts = text.split(separator: " ").map(String.init)
            let step = (end - start) / Double(parts.count)
            return parts.enumerated().map { VideoCaptionWord(text: $0.element, start: start + Double($0.offset) * step, end: start + Double($0.offset + 1) * step - 0.04) }
        }
        let thursday = [("Thursday", 5.75, 6.1), ("was", 6.12, 6.3), ("um", 6.4, 6.68), ("our", 6.8, 6.98), ("best", 7.0, 7.25), ("day.", 7.27, 7.55)]
            .map { VideoCaptionWord(text: $0.0, start: $0.1, end: $0.2) }
        let words = line("Here's the whole week at a glance.", from: 0.25, to: 2.1)
            + line("Click any day to see what drove revenue.", from: 2.7, to: 5.1)
            + thursday
            + line("Export the report in two keystrokes.", from: 8.2, to: 10.0)
        return VideoCaptionBuilder.lines(from: words)
    }

    private func model(for url: URL) async throws -> VideoEditorModel {
        VideoDemoDraftStore.delete(for: url)
        let model = VideoEditorModel(videoURL: url)
        await model.load()
        XCTAssertTrue(model.isReady, model.loadError ?? "")
        XCTAssertFalse(model.project.zoomRegions.isEmpty, "auto zoom planned the camera")
        let palette = Layout.normalized(CGPoint(x: Layout.palette.midX, y: Layout.palette.midY - 30))
        model.mutate { project in
            project.captions = self.captions()
            project.transcriptLanguage = "en-US"
            project.captionStyle.visible = true
            // Wide, in on the clicks, wide again, then aimed at the menu.
            project.zoomRegions = [
                VideoZoomRegion(start: 0.75, end: 6.2, scale: 2, followsCursor: true),
                VideoZoomRegion(start: 8.5, end: 11.6, scale: 1.6, followsCursor: false, focusX: palette.x, focusY: palette.y),
            ]
        }
        model.endGesture()
        XCTAssertEqual(model.fillerCount, 1)
        model.removeFillers()
        XCTAssertEqual(model.fillerCount, 0)
        model.notice = nil
        return model
    }

    // MARK: Renders

    private func render<V: View>(_ view: V, size: CGSize, name: String, scale: CGFloat = 2) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 600_000_000)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = output.appendingPathComponent("\(name).png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("MARKETING: \(url.path)")
    }

    private func exportFrames(of video: URL, at times: [(Double, String)]) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for (time, name) in times {
            let image = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
            let rep = NSBitmapImageRep(cgImage: image)
            let url = output.appendingPathComponent("\(name).jpg")
            try XCTUnwrap(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86])).write(to: url)
            print("MARKETING: \(url.path)")
        }
    }

    func testRenderWebsiteVisuals() async throws {
        let recording = work.appendingPathComponent("Northwind demo.mp4")
        let metadata = try await writeRecording(to: recording)
        let model = try await model(for: recording)
        func at(_ source: Double) throws -> Double { try XCTUnwrap(model.timelineTime(forSource: source)) }

        // The demo video, through the real exporter.
        var settings = VideoExportSettings()
        settings.format = .mp4
        settings.resolution = .p1080
        settings.fps = 30
        settings.codec = .h264
        settings.endCard = false
        let demo = output.appendingPathComponent("shotnix-editor-demo.mp4")
        try await VideoDemoExporter.export(project: model.project, recording: metadata, destinationURL: demo, settings: settings)
        print("MARKETING: \(demo.path)")
        try await exportFrames(of: demo, at: [(0.1, "shotnix-editor-demo-poster"), (try at(4.95), "shotnix-output-zoom-captions"), (try at(7.3), "shotnix-output-wide"), (try at(8.35), "shotnix-output-keycaps"), (try at(10.1), "shotnix-output-aimed-zoom")])

        // Vertical: the same take, 9:16, the camera panning after the cursor.
        var vertical = model.project
        vertical.aspectPreset = .vertical
        vertical.reframe = true
        vertical.zoomRegions = []
        var verticalSettings = settings
        verticalSettings.resolution = .p720
        let verticalURL = output.appendingPathComponent("shotnix-vertical-demo.mp4")
        try await VideoDemoExporter.export(project: vertical, recording: metadata, destinationURL: verticalURL, settings: verticalSettings)
        print("MARKETING: \(verticalURL.path)")
        try await exportFrames(of: verticalURL, at: [(try at(4.95), "shotnix-vertical-frame"), (try at(8.35), "shotnix-vertical-frame-2")])

        // The editor itself.
        let full = CGSize(width: 1512, height: 944)
        model.inspectorTab = .background
        model.seek(to: try at(7.3))
        try await Task.sleep(nanoseconds: 400_000_000)
        try await render(VideoEditorRootView(model: model), size: full, name: "shotnix-video-editor")

        model.inspectorTab = .captions
        UserDefaults.standard.set("transcript", forKey: "videoScriptMode")
        model.seek(to: 3.6)
        try await Task.sleep(nanoseconds: 400_000_000)
        try await render(VideoEditorRootView(model: model), size: full, name: "shotnix-edit-by-text")

        model.inspectorTab = .zoom
        if let zoom = model.project.zoomRegions.last {
            model.selection = .zoom(zoom.id)
        }
        model.seek(to: try at(9.3))
        try await Task.sleep(nanoseconds: 400_000_000)
        try await render(VideoEditorRootView(model: model), size: full, name: "shotnix-auto-zoom")
        model.selection = .none

        model.inspectorTab = .background
        model.seek(to: try at(7.3))
        model.isExportPresented = true
        try await render(VideoEditorRootView(model: model), size: full, name: "shotnix-export")
        model.isExportPresented = false
        VideoDemoDraftStore.delete(for: recording)
    }
}
