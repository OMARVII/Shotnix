import AppKit
import XCTest
@testable import ShotnixCore

/// Scrolling capture: a synthetic tall "page" is sliced into overlapping,
/// slightly noisy frames — the way a user scrolling produces them — and the
/// stitched result must be the page again, with no repeated bands.
@MainActor
final class ScrollingCaptureTests: XCTestCase {

    // MARK: Stitching

    func testOverlappingFramesStitchBackIntoThePage() throws {
        let page = Self.makePage(width: 400, height: 3000, seed: 7)
        // Uneven steps, a pause (same offset twice), and a small scroll back up.
        let offsets = [0, 0, 137, 311, 480, 700, 905, 1030, 1260, 1500, 1400, 1720, 1905, 2100, 2290, 2400]
        let stitcher = FrameStitcher()
        for (index, offset) in offsets.enumerated() {
            _ = stitcher.add(Self.frame(of: page, top: offset, height: 600, noise: 3, seed: UInt64(index + 1)))
        }
        let result = try XCTUnwrap(stitcher.makeImage())

        XCTAssertEqual(result.width, page.width)
        XCTAssertEqual(result.height, page.height, "a repeated or missing band changes the height")
        try Self.assertMatches(result, page)
    }

    func testStickyHeaderAndFooterAppearOnlyOnce() throws {
        let page = Self.makePage(width: 360, height: 2400, seed: 11)
        let header = Self.makeBar(width: 360, height: 48, hue: 0.6)
        let footer = Self.makeBar(width: 360, height: 36, hue: 0.05)
        let contentHeight = 460
        let offsets = [0, 120, 260, 420, 600, 810, 1000, 1190, 1400, 1600, 1800, 1940]
        let stitcher = FrameStitcher()
        for (index, offset) in offsets.enumerated() {
            let content = Self.crop(page, top: offset, height: contentHeight)
            let composed = Self.stack([header, content, footer])
            _ = stitcher.add(Self.addingNoise(to: composed, amount: 2, seed: UInt64(100 + index)))
        }
        let result = try XCTUnwrap(stitcher.makeImage())

        let expected = Self.stack([header, Self.crop(page, top: 0, height: offsets.last! + contentHeight), footer])
        XCTAssertEqual(result.height, expected.height)
        try Self.assertMatches(result, expected)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-capture-snapshots/scrolling-stitched-sticky.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(ImageExporter.pngData(from: result)).write(to: url)
        print("SNAPSHOT-STITCHED: \(url.path) — \(result.width)x\(result.height)")
    }

    func testStaticSidebarDoesNotBreakMatching() throws {
        let page = Self.makePage(width: 300, height: 2000, seed: 5)
        let sidebar = Self.makePage(width: 100, height: 500, seed: 99)
        let offsets = [0, 150, 330, 520, 700, 910, 1100, 1300, 1500]
        let stitcher = FrameStitcher()
        for (index, offset) in offsets.enumerated() {
            let content = Self.crop(page, top: offset, height: 500)
            let frame = Self.sideBySide(sidebar, content)
            _ = stitcher.add(Self.addingNoise(to: frame, amount: 2, seed: UInt64(index + 40)))
        }
        let result = try XCTUnwrap(stitcher.makeImage())
        // Content column must be the page, top to bottom (the sidebar repeats).
        XCTAssertEqual(result.height, 2000)
        let contentColumn = try XCTUnwrap(result.cropping(to: CGRect(x: 100, y: 0, width: 300, height: 2000)))
        try Self.assertMatches(contentColumn, page)
    }

    func testIdenticalFramesAreNotStacked() throws {
        let page = Self.makePage(width: 320, height: 800, seed: 3)
        let stitcher = FrameStitcher()
        for index in 0..<6 {
            let result = stitcher.add(Self.frame(of: page, top: 100, height: 500, noise: 3, seed: UInt64(index + 1)))
            XCTAssertEqual(result, index == 0 ? .first : .unchanged)
        }
        XCTAssertEqual(stitcher.makeImage()?.height, 500)
    }

    func testHeightCapStopsTheCaptureAndSaysSo() throws {
        let page = Self.makePage(width: 300, height: 4000, seed: 13)
        let stitcher = FrameStitcher(limits: FrameStitcher.Limits(maxHeight: 1500, maxPixels: .max))
        var results: [FrameStitcher.FrameResult] = []
        for (index, offset) in stride(from: 0, through: 3400, by: 200).enumerated() {
            results.append(stitcher.add(Self.frame(of: page, top: offset, height: 600, noise: 2, seed: UInt64(index + 1))))
        }
        XCTAssertTrue(stitcher.reachedLimit)
        XCTAssertTrue(results.contains(.limitReached))
        XCTAssertEqual(results.last, .limitReached, "frames after the cap are refused")
        let result = try XCTUnwrap(stitcher.makeImage())
        XCTAssertEqual(result.height, 1500)
        try Self.assertMatches(result, Self.crop(page, top: 0, height: 1500))
    }

    func testStitchedImageKeepsTheDisplayColorSpace() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let page = Self.makePage(width: 300, height: 1200, seed: 21, colorSpace: p3)
        let stitcher = FrameStitcher()
        for (index, offset) in [0, 200, 420, 700].enumerated() {
            _ = stitcher.add(Self.frame(of: page, top: offset, height: 500, noise: 1, seed: UInt64(index + 1)))
        }
        let result = try XCTUnwrap(stitcher.makeImage())
        XCTAssertEqual(result.colorSpace?.name, CGColorSpace.displayP3)
    }

    func testScrollingFarPastTheLastFrameLosesTrackInsteadOfGuessing() throws {
        let page = Self.makePage(width: 300, height: 3000, seed: 17)
        let stitcher = FrameStitcher()
        XCTAssertEqual(stitcher.add(Self.frame(of: page, top: 0, height: 500, noise: 2, seed: 1)), .first)
        // A jump with no overlap at all: nothing to match, nothing appended.
        XCTAssertEqual(stitcher.add(Self.frame(of: page, top: 1500, height: 500, noise: 2, seed: 2)), .lostTrack)
        XCTAssertEqual(stitcher.makeImage()?.height, 500)
        // Scrolling back into overlap resumes the capture.
        if case .appended = stitcher.add(Self.frame(of: page, top: 200, height: 500, noise: 2, seed: 3)) {} else {
            XCTFail("expected the capture to resume")
        }
        XCTAssertEqual(stitcher.makeImage()?.height, 700)
    }

    /// Frames drawn by a real NSScrollView at the Mac's backing scale,
    /// scrolled in uneven steps, stitch back into the document as AppKit
    /// draws it.
    func testAppKitScrollViewFramesStitchBackIntoTheDocument() throws {
        let page = Self.makePage(width: 320, height: 1800, seed: 41)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 360))
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        let document = PageView(frame: NSRect(x: 0, y: 0, width: 320, height: 1800), page: page)
        scroll.documentView = document
        window.contentView = scroll

        let stitcher = FrameStitcher()
        for offset in [0, 90, 210, 330, 505, 640, 800, 1000, 1170, 1320, 1440] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            let rep = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
            scroll.cacheDisplay(in: scroll.bounds, to: rep)
            _ = stitcher.add(try XCTUnwrap(rep.cgImage))
        }
        let result = try XCTUnwrap(stitcher.makeImage())

        let full = try XCTUnwrap(document.bitmapImageRepForCachingDisplay(in: document.bounds))
        document.cacheDisplay(in: document.bounds, to: full)
        let expected = try XCTUnwrap(full.cgImage)
        XCTAssertEqual(result.height, expected.height, "the whole document, once")
        try Self.assertMatches(result, expected)
    }

    // MARK: HUD

    func testHUDSitsAboveTheSelectionWhenThereIsRoom() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let selection = CGRect(x: 400, y: 200, width: 600, height: 400)
        let frame = ScrollingCaptureHUD.frame(selection: selection, visibleFrame: visible)
        XCTAssertTrue(visible.contains(frame))
        XCTAssertGreaterThanOrEqual(frame.minY, selection.maxY)
    }

    func testHUDNearTheTopOfTheScreenStaysBelowTheMenuBar() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        // Selection touching the top of the usable area — the old placement
        // (selection.maxY + 20) put Done under the menu bar.
        let selection = CGRect(x: 300, y: 300, width: 700, height: 575)
        let frame = ScrollingCaptureHUD.frame(selection: selection, visibleFrame: visible)
        XCTAssertTrue(visible.contains(frame), "\(frame) must be inside \(visible)")
        XCTAssertLessThanOrEqual(frame.maxY, selection.minY, "falls back to just below the selection")
    }

    func testHUDForAFullScreenSelectionIsPinnedInsideTheVisibleFrame() {
        let visible = CGRect(x: 0, y: 40, width: 1512, height: 905)
        let frame = ScrollingCaptureHUD.frame(selection: visible, visibleFrame: visible)
        XCTAssertTrue(visible.contains(frame))
        XCTAssertEqual(frame.maxY, visible.maxY - 8, accuracy: 1, "pinned near the top")
    }

    func testHUDIsClampedHorizontallyOnSecondaryDisplays() {
        let visible = CGRect(x: -1920, y: 100, width: 1920, height: 1055)
        let selection = CGRect(x: -1910, y: 300, width: 120, height: 300)
        let frame = ScrollingCaptureHUD.frame(selection: selection, visibleFrame: visible)
        XCTAssertTrue(visible.contains(frame))
    }

    // MARK: Controller

    func testShortcutAgainFinishesWithAPointSizedCapture() async throws {
        guard let screen = NSScreen.main else { throw XCTSkip("no screen") }
        let page = Self.makePage(width: 400, height: 1600, seed: 29)
        let offsets = [0, 160, 330, 520, 700, 880, 1000]
        let frames = offsets.enumerated().map { index, offset in
            let cg = Self.frame(of: page, top: offset, height: 600, noise: 2, seed: UInt64(index + 1))
            // Retina: 2 pixels per point.
            return CaptureEngine.nsImage(from: cg, logicalSize: NSSize(width: 200, height: 300))
        }
        var served = 0
        var outcome: ScrollingCaptureController.Outcome?
        let finished = expectation(description: "scrolling capture finished")
        let controller = ScrollingCaptureController(frameProvider: { _, _ in
            let image = frames[min(served, frames.count - 1)]
            served += 1
            return image
        }) { result in
            outcome = result
            finished.fulfill()
        }
        let visible = screen.visibleFrame
        let selection = CGRect(x: visible.midX - 100, y: visible.maxY - 300, width: 200, height: 300)
        controller.beginScrolling(rect: selection, on: screen)
        let hud = try XCTUnwrap(controller.hud)
        XCTAssertTrue(visible.contains(hud.frame), "HUD \(hud.frame) outside \(visible)")
        XCTAssertTrue(hud.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(hud.collectionBehavior.contains(.canJoinAllSpaces))

        let deadline = Date().addingTimeInterval(8)
        while served <= frames.count, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        controller.finishFromShortcut()
        await fulfillment(of: [finished], timeout: 5)

        guard case .captured(let image, let rect, _, _) = outcome else {
            return XCTFail("expected a capture, got \(String(describing: outcome))")
        }
        XCTAssertEqual(rect, selection)
        XCTAssertEqual(image.size.width, 200, accuracy: 0.5)
        XCTAssertEqual(image.size.height, 800, accuracy: 0.5, "1,600 px at 2× is 800 points")
        XCTAssertNil(controller.hud, "HUD closes when the capture finishes")
    }

    func testRenderHUDSnapshot() throws {
        let hud = ScrollingCaptureHUD()
        hud.update(heightPixels: 12480, status: "Scroll down to capture", isWarning: false)
        let view = try XCTUnwrap(hud.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotnix-capture-snapshots/scrolling-hud.png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT-SCROLLING-HUD: \(url.path)")
    }

    // MARK: - Synthetic pages

    /// Deterministic "document": lines of word-like blocks with uneven
    /// spacing, plus the odd colored picture — textured and non-periodic.
    static func makePage(width: Int, height: Int, seed: UInt64, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
        var rng = SeededGenerator(seed: seed)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Top-down y; CG draws bottom-up.
        func fill(_ rect: CGRect, _ color: CGColor) {
            context.setFillColor(color)
            context.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        }
        var y = 8
        while y < height - 24 {
            if Int.random(in: 0..<9, using: &rng) == 0 {
                let blockHeight = Int.random(in: 30...90, using: &rng)
                let hue = CGFloat.random(in: 0...1, using: &rng)
                let color = NSColor(calibratedHue: hue, saturation: 0.6, brightness: 0.8, alpha: 1).cgColor
                fill(CGRect(x: 10, y: y, width: width / 2, height: blockHeight), color)
                y += blockHeight + Int.random(in: 8...16, using: &rng)
                continue
            }
            let lineHeight = Int.random(in: 9...16, using: &rng)
            var x = 10
            while x < width - 24 {
                let wordWidth = min(Int.random(in: 10...56, using: &rng), width - 12 - x)
                let gray = CGFloat.random(in: 0.05...0.55, using: &rng)
                fill(CGRect(x: x, y: y, width: wordWidth, height: lineHeight), CGColor(gray: gray, alpha: 1))
                x += wordWidth + Int.random(in: 5...14, using: &rng)
            }
            y += lineHeight + Int.random(in: 5...22, using: &rng)
        }
        return context.makeImage()!
    }

    static func makeBar(width: Int, height: Int, hue: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor(calibratedHue: hue, saturation: 0.5, brightness: 0.35, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 12, y: height / 3, width: 80, height: height / 3))
        context.fill(CGRect(x: width - 60, y: height / 3, width: 40, height: height / 3))
        return context.makeImage()!
    }

    static func crop(_ image: CGImage, top: Int, height: Int) -> CGImage {
        image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: height))!
    }

    static func frame(of page: CGImage, top: Int, height: Int, noise: Int, seed: UInt64) -> CGImage {
        addingNoise(to: crop(page, top: top, height: height), amount: noise, seed: seed)
    }

    /// Stacks images top to bottom.
    static func stack(_ images: [CGImage]) -> CGImage {
        let width = images[0].width
        let height = images.reduce(0) { $0 + $1.height }
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: images[0].colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var y = height
        for image in images {
            y -= image.height
            context.draw(image, in: CGRect(x: 0, y: y, width: width, height: image.height))
        }
        return context.makeImage()!
    }

    static func sideBySide(_ left: CGImage, _ right: CGImage) -> CGImage {
        let height = max(left.height, right.height)
        let context = CGContext(data: nil, width: left.width + right.width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(left, in: CGRect(x: 0, y: height - left.height, width: left.width, height: left.height))
        context.draw(right, in: CGRect(x: left.width, y: height - right.height, width: right.width, height: right.height))
        return context.makeImage()!
    }

    /// ±amount of independent noise per channel — the jitter real frames
    /// never have, so matching has to tolerate it.
    static func addingNoise(to image: CGImage, amount: Int, seed: UInt64) -> CGImage {
        var rng = SeededGenerator(seed: seed)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        for index in 0..<(image.width * image.height * 4) where index % 4 != 3 {
            let value = Int(pixels[index]) + Int.random(in: -amount...amount, using: &rng)
            pixels[index] = UInt8(max(0, min(255, value)))
        }
        return context.makeImage()!
    }

    static func rgba(_ image: CGImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return buffer
    }

    /// Row-by-row comparison: noise stays small everywhere; a misplaced or
    /// repeated band shows up as rows that differ wildly.
    static func assertMatches(_ result: CGImage, _ expected: CGImage, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(result.width, expected.width, file: file, line: line)
        XCTAssertEqual(result.height, expected.height, file: file, line: line)
        guard result.width == expected.width, result.height == expected.height else { return }
        let a = rgba(result)
        let b = rgba(expected)
        let rowBytes = result.width * 4
        var worstRow = 0.0
        var worstRowIndex = 0
        var total = 0.0
        for row in 0..<result.height {
            var sum = 0
            for index in (row * rowBytes)..<((row + 1) * rowBytes) where index % 4 != 3 {
                sum += abs(Int(a[index]) - Int(b[index]))
            }
            let mean = Double(sum) / Double(result.width * 3)
            total += mean
            if mean > worstRow {
                worstRow = mean
                worstRowIndex = row
            }
        }
        XCTAssertLessThan(total / Double(result.height), 2.5, "overall difference", file: file, line: line)
        XCTAssertLessThan(worstRow, 4.0, "row \(worstRowIndex) doesn't match — a band is repeated or missing", file: file, line: line)
    }
}

/// Draws a page image top-down, pixel-exact at any backing scale.
private final class PageView: NSView {
    private let page: CGImage

    init(frame: NSRect, page: CGImage) {
        self.page = page
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        // Flipped view: undo the flip for CGImage drawing.
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(page, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }
}

/// SplitMix64 — reproducible test content.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
