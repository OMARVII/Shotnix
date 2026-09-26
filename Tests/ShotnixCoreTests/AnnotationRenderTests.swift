import AppKit
import XCTest
@testable import ShotnixCore

/// Pixel-level tests of what the annotation editor exports: redactions that
/// can't leak, resolution that follows the screenshot (not the monitor), no
/// editing chrome, and the newer tools.
@MainActor
final class AnnotationRenderTests: XCTestCase {

    private var settings: AnnotationSettingsSandbox!

    override func setUp() async throws {
        settings = AnnotationSettingsSandbox()
    }

    override func tearDown() async throws {
        settings.tearDown()
        settings = nil
    }

    private func makeCanvas(_ image: NSImage) -> AnnotationCanvas {
        let canvas = AnnotationCanvas(frame: NSRect(origin: .zero, size: image.size))
        canvas.backgroundImage = image
        return canvas
    }

    private func pixelRect(_ rect: CGRect, density: CGFloat) -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        (Int((rect.minX * density).rounded(.down)), Int((rect.minY * density).rounded(.down)),
         Int((rect.maxX * density).rounded(.up)), Int((rect.maxY * density).rounded(.up)))
    }

    // MARK: – Item 1: blur and pixelate can't leak the original

    func testBlurHidesTheOriginalEverywhereInsideItsRegionAt1xAnd2x() throws {
        for density in [CGFloat(1), 2] {
            let size = CGSize(width: 200, height: 120)
            let source = AnnotationPixels(AnnotationTestImages.checkerboard(pointSize: size, density: density))
            let canvas = makeCanvas(AnnotationTestImages.checkerboard(pointSize: size, density: density))
            // The 24 pt box from the audit (default strength) and a large, weak one
            let small = BlurAnnotation(rect: CGRect(x: 40, y: 30, width: 24, height: 24))
            let large = BlurAnnotation(rect: CGRect(x: 100, y: 20, width: 80, height: 60))
            large.strength = AnnotationRedaction.strengthRange.lowerBound
            canvas.objects = [small, large]

            let output = AnnotationPixels(canvas.flatten())
            XCTAssertEqual(output.width, Int(size.width * density))

            for region in [small.rect, large.rect] {
                let px = pixelRect(region, density: density)
                var minAlpha = 255
                var maxNeighborDelta = 0
                var darkest = 255
                var lightest = 0
                for y in px.minY..<px.maxY {
                    for x in px.minX..<px.maxX {
                        let value = output.luminance(x, y)
                        minAlpha = min(minAlpha, output.pixel(x, y).a)
                        darkest = min(darkest, value)
                        lightest = max(lightest, value)
                        if x + 1 < px.maxX { maxNeighborDelta = max(maxNeighborDelta, abs(value - output.luminance(x + 1, y))) }
                        if y + 1 < px.maxY { maxNeighborDelta = max(maxNeighborDelta, abs(value - output.luminance(x, y + 1))) }
                    }
                }
                // The checkerboard differs by 255 between neighbors; any
                // leak (semi-transparent edges, a faint copy mid-box) shows
                // up as neighbor differences.
                XCTAssertEqual(minAlpha, 255, "blur must be opaque at \(density)x, \(region)")
                XCTAssertLessThanOrEqual(maxNeighborDelta, 6, "original shows through the blur at \(density)x, \(region)")
                // Core Image blurs in linear light, so the gray is light;
                // edge clamping shades the corners a little. No black or
                // white checker pixel survives anywhere.
                XCTAssertLessThanOrEqual(lightest - darkest, 64, "blur of a checkerboard is a soft gray at \(density)x")
                XCTAssertGreaterThan(darkest, 60)
                XCTAssertLessThan(lightest, 240)
            }

            // Outside the regions the screenshot is untouched
            let outside = pixelRect(CGRect(x: 10, y: 100, width: 20, height: 10), density: density)
            for y in outside.minY..<outside.maxY {
                for x in outside.minX..<outside.maxX {
                    XCTAssertTrue(output.pixel(x, y) == source.pixel(x, y), "untouched pixels must stay exact")
                }
            }
        }
    }

    func testPixelateTurnsEveryPixelInsideIntoWholeBlocksAt1xAnd2x() throws {
        for density in [CGFloat(1), 2] {
            let size = CGSize(width: 200, height: 120)
            let source = AnnotationPixels(AnnotationTestImages.noise(pointSize: size, density: density))
            let canvas = makeCanvas(AnnotationTestImages.noise(pointSize: size, density: density))
            let strength: CGFloat = 6
            let small = PixelateAnnotation(rect: CGRect(x: 40, y: 30, width: 24, height: 24))
            let large = PixelateAnnotation(rect: CGRect(x: 100, y: 20, width: 80, height: 61))
            small.strength = strength
            large.strength = strength
            canvas.objects = [small, large]

            let output = AnnotationPixels(canvas.flatten())
            let block = Int(strength * density)

            for region in [small.rect, large.rect] {
                let px = pixelRect(region, density: density)
                var unchangedPixels = 0
                var total = 0
                // Blocks start at the region's top-left; every pixel of a
                // block — edge blocks included — has the block's color.
                for by in stride(from: px.minY, to: px.maxY, by: block) {
                    for bx in stride(from: px.minX, to: px.maxX, by: block) {
                        for y in by..<min(by + block, px.maxY) {
                            for x in bx..<min(bx + block, px.maxX) {
                                XCTAssertEqual(output.pixel(x, y).a, 255, "pixelate must be opaque at \(density)x")
                                if !output.sameRGBA(x, y, bx, by) {
                                    XCTFail("unpixelated pixel at (\(x), \(y)) in block (\(bx), \(by)) at \(density)x, \(region)")
                                    return
                                }
                                if output.pixel(x, y) == source.pixel(x, y) { unchangedPixels += 1 }
                                total += 1
                            }
                        }
                    }
                }
                XCTAssertLessThan(Double(unchangedPixels) / Double(total), 0.2, "most pixels must differ from the original")
            }
        }
    }

    func testRedactionStrengthIsInPointsSoRetinaIsAsStrongAs1x() throws {
        func spreadInPoints(density: CGFloat) -> CGFloat {
            let size = CGSize(width: 200, height: 120)
            let image = AnnotationTestImages.make(pointSize: size, density: density) { ctx, pixelSize in
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(origin: .zero, size: pixelSize))
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fill(CGRect(x: 100 * density, y: 0, width: 2 * density, height: pixelSize.height))
            }
            let canvas = makeCanvas(image)
            let blur = BlurAnnotation(rect: CGRect(x: 40, y: 20, width: 120, height: 80))
            blur.strength = 8
            canvas.objects = [blur]
            let output = AnnotationPixels(canvas.flatten())
            let row = Int(60 * density)
            var darkened = 0
            for x in Int(40 * density)..<Int(160 * density) where output.luminance(x, row) < 250 {
                darkened += 1
            }
            return CGFloat(darkened) / density
        }
        let spread1x = spreadInPoints(density: 1)
        let spread2x = spreadInPoints(density: 2)
        XCTAssertGreaterThan(spread1x, 10, "blur must actually spread the line")
        XCTAssertEqual(spread2x / spread1x, 1, accuracy: 0.2, "same blur in points at 1x (\(spread1x)) and 2x (\(spread2x))")
    }

    func testRedactionOfRealTextAt2xIsUnreadableAndOpaque() throws {
        let size = CGSize(width: 320, height: 100)
        let image = AnnotationTestImages.document(pointSize: size, density: 2)
        let source = AnnotationPixels(image)
        let canvas = makeCanvas(image)
        let blur = BlurAnnotation(rect: CGRect(x: 8, y: 8, width: 150, height: 40))
        let pixelate = PixelateAnnotation(rect: CGRect(x: 160, y: 8, width: 150, height: 40))
        canvas.objects = [blur, pixelate]
        let flat = canvas.flatten()
        let output = AnnotationPixels(flat)
        try AnnotationSnapshots.write(flat.bestCGImage!, name: "redaction-text-2x")

        for region in [blur.rect, pixelate.rect] {
            let px = pixelRect(region, density: 2)
            var darkest = 255
            var sourceDarkest = 255
            for y in px.minY..<px.maxY {
                for x in px.minX..<px.maxX {
                    XCTAssertEqual(output.pixel(x, y).a, 255)
                    darkest = min(darkest, output.luminance(x, y))
                    sourceDarkest = min(sourceDarkest, source.luminance(x, y))
                }
            }
            // Blur spreads glyphs out and each mosaic block averages what it
            // covers, so no glyph-black pixel survives either.
            XCTAssertLessThan(sourceDarkest, 60, "the source has black glyphs here")
            XCTAssertGreaterThan(darkest, 110, "no glyph-dark pixels survive the redaction in \(region)")
        }
    }

    // MARK: – Item 3: export resolution follows the screenshot, not the monitor

    func testExportKeepsEveryPixelOfARetinaCaptureWhateverTheWindowAndZoom() throws {
        let image = AnnotationTestImages.checkerboard(pointSize: CGSize(width: 100, height: 80), density: 2)
        let source = AnnotationPixels(image)

        // Offscreen, no window
        let bare = makeCanvas(image)
        let bareExport = bare.flatten()
        XCTAssertEqual(bareExport.size, NSSize(width: 100, height: 80))
        XCTAssertEqual(AnnotationPixels(bareExport), source, "a 2x capture exports all 200×160 pixels, exactly")

        // In a window, inside a zoomed-out scroll view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let hosted = makeCanvas(image)
        scrollView.documentView = hosted
        scrollView.allowsMagnification = true
        scrollView.magnification = 0.5
        window.contentView = scrollView
        XCTAssertEqual(AnnotationPixels(hosted.flatten()), source, "window backing scale and zoom must not matter")
    }

    func testExportDoesNotUpscaleA1xCapture() throws {
        let image = AnnotationTestImages.checkerboard(pointSize: CGSize(width: 100, height: 80), density: 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        let canvas = makeCanvas(image)
        window.contentView = canvas
        let export = AnnotationPixels(canvas.flatten())
        XCTAssertEqual(export.width, 100)
        XCTAssertEqual(export.height, 80)
        XCTAssertEqual(export, AnnotationPixels(image), "a 1x capture exports its own crisp pixels, not an upscale")
    }

    func testAnnotationsExportAtTheScreenshotsDensity() throws {
        let image = AnnotationTestImages.solid(.white, pointSize: CGSize(width: 100, height: 80), density: 2)
        let canvas = makeCanvas(image)
        let line = LineAnnotation(start: CGPoint(x: 10, y: 40.5), end: CGPoint(x: 90, y: 40.5))
        line.lineWidth = 1
        line.color = .black
        canvas.objects = [line]
        let output = AnnotationPixels(canvas.flatten())
        // A 1 pt line at 2x covers two full pixel rows: crisp, not a blurry 1x upscale.
        XCTAssertLessThan(output.luminance(100, 80), 30)
        XCTAssertLessThan(output.luminance(100, 81), 30)
        XCTAssertGreaterThan(output.luminance(100, 78), 225)
        XCTAssertGreaterThan(output.luminance(100, 83), 225)
    }

    func testCroppedExportIsAnExactSubImageAtFullResolution() throws {
        let image = AnnotationTestImages.noise(pointSize: CGSize(width: 120, height: 90), density: 2)
        let source = AnnotationPixels(image)
        let canvas = makeCanvas(image)
        canvas.activeTool = .crop
        drag(canvas, from: CGPoint(x: 20, y: 10), to: CGPoint(x: 80, y: 50))
        canvas.applyCrop()

        let export = AnnotationPixels(canvas.flatten())
        XCTAssertEqual(export.width, 120)
        XCTAssertEqual(export.height, 80)
        for y in 0..<export.height {
            for x in 0..<export.width where export.pixel(x, y) != source.pixel(x + 40, y + 20) {
                XCTFail("cropped pixel (\(x), \(y)) differs from the source")
                return
            }
        }
    }

    func testBackdropExportIsAtTheScreenshotsDensity() throws {
        let image = AnnotationTestImages.solid(.systemTeal, pointSize: CGSize(width: 100, height: 60), density: 2)
        let canvas = makeCanvas(image)
        var options = ScreenshotBackgroundOptions.editorDefault
        options.isEnabled = true
        options.padding = 20
        canvas.setBackgroundOptions(options)
        let export = canvas.flatten()
        XCTAssertEqual(export.size, NSSize(width: 140, height: 100))
        XCTAssertEqual(export.bestCGImage?.width, 280)
        XCTAssertEqual(export.bestCGImage?.height, 200)
    }

    // MARK: – Item 5: editing chrome never reaches an export

    func testHoverSelectionAndCropOverlayNeverReachTheExport() throws {
        let image = AnnotationTestImages.solid(NSColor(white: 0.9, alpha: 1), pointSize: CGSize(width: 240, height: 160), density: 2)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        let canvas = makeCanvas(image)
        window.contentView = canvas
        let rect = RectangleAnnotation(rect: CGRect(x: 20, y: 20, width: 80, height: 60))
        let arrow = ArrowAnnotation(start: CGPoint(x: 140, y: 120), end: CGPoint(x: 210, y: 40))
        canvas.objects = [rect, arrow]
        let reference = AnnotationPixels(canvas.flatten())
        let plainView = viewPixels(canvas)

        // Select the rectangle, then release a drag and hover the arrow —
        // the release is what used to re-enable the hover outline.
        canvas.activeTool = .select
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 21, y: 50), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 21, y: 50), in: canvas))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 175, y: 80), in: canvas))
        XCTAssertEqual(canvas.selectedObjects.first?.id, rect.id)
        XCTAssertEqual(canvas.hoveredObjectID, arrow.id, "precondition: the arrow shows its hover outline")
        XCTAssertNotEqual(viewPixels(canvas), plainView, "precondition: the editor view shows the chrome")

        XCTAssertEqual(AnnotationPixels(canvas.flatten()), reference, "hover outline and selection handles must not be exported")

        // The crop overlay (dimming, handles) while cropping
        canvas.activeTool = .crop
        drag(canvas, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 150, y: 120))
        XCTAssertNotNil(canvas.pendingCrop)
        XCTAssertEqual(AnnotationPixels(canvas.flatten()), reference, "an unapplied crop overlay must not be exported")
    }

    // MARK: – Item 12: new tools in the export

    func testSpotlightDimsOutsideAndLeavesInsideUntouched() throws {
        let image = AnnotationTestImages.solid(.white, pointSize: CGSize(width: 200, height: 120), density: 2)
        let canvas = makeCanvas(image)
        let spotlight = SpotlightAnnotation(rect: CGRect(x: 60, y: 30, width: 80, height: 60))
        let second = SpotlightAnnotation(rect: CGRect(x: 150, y: 10, width: 40, height: 40), isEllipse: true)
        canvas.objects = [spotlight, second]
        let output = AnnotationPixels(canvas.flatten())

        XCTAssertEqual(output.luminance(200, 120), 255, "inside the spotlight stays bright")
        XCTAssertEqual(output.luminance(340, 60), 255, "a second spotlight doesn't dim the first's neighbor opening")
        let dimmed = output.luminance(20, 200)
        XCTAssertLessThan(dimmed, 140, "outside is dimmed")
        XCTAssertGreaterThan(dimmed, 90)
        XCTAssertEqual(output.luminance(302, 22), dimmed, "the ellipse's corner is outside its opening")
    }

    func testCalloutBubbleTailAndTextAreInTheExport() throws {
        let image = AnnotationTestImages.solid(.white, pointSize: CGSize(width: 240, height: 160), density: 2)
        let canvas = makeCanvas(image)
        let callout = CalloutAnnotation(origin: CGPoint(x: 100, y: 20), tail: CGPoint(x: 40, y: 140))
        callout.text = "Click here"
        callout.color = .systemBlue
        canvas.objects = [callout]
        let output = AnnotationPixels(canvas.flatten())

        let bubble = callout.bubbleRect
        let corner = output.pixel(Int((bubble.minX + 6) * 2), Int((bubble.midY) * 2))
        XCTAssertGreaterThan(corner.b, 200, "bubble is filled with its color")
        XCTAssertLessThan(corner.r, 60)
        // Along the tail, halfway to the tip
        let mid = CGPoint(x: (bubble.midX + callout.tail.x) / 2 + 2, y: (bubble.midY + callout.tail.y) / 2)
        XCTAssertGreaterThan(output.pixel(Int(mid.x * 2), Int(mid.y * 2)).b, 150, "tail is drawn")
        XCTAssertEqual(output.luminance(460, 300), 255, "outside the callout is untouched")
        // White text inside the blue bubble
        var whiteTextPixels = 0
        let text = CGRect(origin: callout.textOrigin, size: callout.textSize)
        for y in Int(text.minY * 2)..<Int(text.maxY * 2) {
            for x in Int(text.minX * 2)..<Int(text.maxX * 2) where output.luminance(x, y) > 200 {
                whiteTextPixels += 1
            }
        }
        XCTAssertGreaterThan(whiteTextPixels, 40, "callout text is rendered in a contrasting color")
    }

    func testFreehandHighlighterTintsLightPixelsAndKeepsDarkTextDark() throws {
        let image = AnnotationTestImages.make(pointSize: CGSize(width: 200, height: 80), density: 2) { ctx, size in
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(x: 180, y: 0, width: 40, height: size.height)) // "text"
        }
        let canvas = makeCanvas(image)
        let stroke = FreehandAnnotation()
        stroke.isHighlighter = true
        stroke.color = .systemYellow
        stroke.lineWidth = 16
        stroke.points = [CGPoint(x: 20, y: 40), CGPoint(x: 100, y: 40), CGPoint(x: 180, y: 40)]
        canvas.objects = [stroke]
        let output = AnnotationPixels(canvas.flatten())

        let onWhite = output.pixel(80, 80)
        XCTAssertGreaterThan(onWhite.r, 200)
        XCTAssertLessThan(onWhite.b, 150, "white turns yellow under the marker")
        XCTAssertLessThan(output.luminance(200, 80), 20, "black text stays black (multiply)")
        XCTAssertEqual(output.luminance(80, 40), 255, "outside the 16 pt stroke is untouched")
        // Butt caps: nothing before the first point
        XCTAssertEqual(output.luminance(Int(16 * 2), 80), 255)
    }

    func testRoundedRectangleLeavesItsCornersOpen() throws {
        let image = AnnotationTestImages.solid(.white, pointSize: CGSize(width: 200, height: 120), density: 2)
        let canvas = makeCanvas(image)
        let sharp = RectangleAnnotation(rect: CGRect(x: 20, y: 20, width: 60, height: 60))
        let rounded = RectangleAnnotation(rect: CGRect(x: 110, y: 20, width: 60, height: 60))
        rounded.cornerRadius = RectangleAnnotation.roundedCornerRadius
        for rect in [sharp, rounded] {
            rect.lineWidth = 3
            rect.color = .black
        }
        canvas.objects = [sharp, rounded]
        let output = AnnotationPixels(canvas.flatten())

        XCTAssertLessThan(output.luminance(40, 40), 30, "square corner is stroked")
        XCTAssertEqual(output.luminance(220, 40), 255, "rounded corner leaves the square corner empty")
        XCTAssertLessThan(output.luminance(280, 40), 30, "rounded rectangle's straight edge is stroked")
    }

    // MARK: – Snapshots to look at

    func testRenderAnnotationShowcaseSnapshot() throws {
        let image = AnnotationTestImages.document(pointSize: CGSize(width: 520, height: 300), density: 2)
        let canvas = makeCanvas(image)
        let spotlight = SpotlightAnnotation(rect: CGRect(x: 20, y: 150, width: 230, height: 110), isEllipse: false)
        let blur = BlurAnnotation(rect: CGRect(x: 8, y: 8, width: 240, height: 36))
        let pixelate = PixelateAnnotation(rect: CGRect(x: 268, y: 8, width: 240, height: 36))
        let rounded = RectangleAnnotation(rect: CGRect(x: 30, y: 160, width: 210, height: 90))
        rounded.cornerRadius = RectangleAnnotation.roundedCornerRadius
        rounded.lineWidth = 3
        let marker = FreehandAnnotation()
        marker.isHighlighter = true
        marker.color = .systemYellow
        marker.lineWidth = 16
        marker.points = stride(from: 280, through: 480, by: 10).map { CGPoint(x: CGFloat($0), y: 78 + sin(CGFloat($0) / 18) * 3) }
        let callout = CalloutAnnotation(origin: CGPoint(x: 300, y: 170), tail: CGPoint(x: 240, y: 210))
        callout.text = "Spotlight + callout\nsecond line"
        callout.color = .systemBlue
        let text = TextAnnotation(origin: CGPoint(x: 290, y: 120))
        text.text = "Regular 22 pt\ntwo lines"
        text.isBold = false
        text.fontSize = 22
        canvas.objects = [spotlight, blur, pixelate, rounded, marker, callout, text]
        try AnnotationSnapshots.write(canvas.flatten().bestCGImage!, name: "annotation-showcase-2x")
    }

    // MARK: – Helpers

    private func viewPixels(_ view: NSView) -> AnnotationPixels {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return AnnotationPixels(rep.cgImage!)
    }

    private func drag(_ canvas: AnnotationCanvas, from start: CGPoint, to end: CGPoint) {
        canvas.mouseDown(with: mouse(.leftMouseDown, at: start, in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), in: canvas))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: end, in: canvas))
    }

    private func mouse(_ type: NSEvent.EventType, at viewPoint: CGPoint, in canvas: AnnotationCanvas) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: canvas.convert(viewPoint, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: canvas.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}
