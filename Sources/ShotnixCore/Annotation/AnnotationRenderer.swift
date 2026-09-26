import AppKit
import CoreImage

/// Where the screenshot sits in the canvas. Annotations are stored in image
/// coordinates (points from the screenshot's top-left corner), so neither
/// the backdrop padding nor the crop ever moves them.
struct AnnotationCanvasLayout: Equatable {
    var imageSize: CGSize
    /// Visible part of the screenshot in image points; nil shows all of it.
    var crop: CGRect?
    /// Backdrop margin around the screenshot (0 while the backdrop is off).
    var padding: CGFloat

    var visibleImageRect: CGRect { crop ?? CGRect(origin: .zero, size: imageSize) }

    var canvasSize: CGSize {
        CGSize(width: visibleImageRect.width + padding * 2, height: visibleImageRect.height + padding * 2)
    }

    /// Canvas position of the image's top-left corner: the image→canvas translation.
    var imageOrigin: CGPoint {
        CGPoint(x: padding - visibleImageRect.minX, y: padding - visibleImageRect.minY)
    }

    /// The visible screenshot in canvas coordinates.
    var screenshotRectInCanvas: CGRect {
        CGRect(x: padding, y: padding, width: visibleImageRect.width, height: visibleImageRect.height)
    }
}

/// Draws an annotated screenshot into any top-left-origin context, in canvas
/// points. The editor view and every export go through here, so exports
/// match the editor exactly and never depend on the display.
@MainActor
final class AnnotationRenderer {

    struct Scene {
        var image: NSImage?
        var layout: AnnotationCanvasLayout
        var backgroundOptions: ScreenshotBackgroundOptions
        var objects: [any AnnotationObject]
        /// Canvas size to export when there's no image to size it by.
        var fallbackSize: CGSize = .zero
    }

    /// The screenshot's pixels and how many of them make a point.
    struct Source {
        let cgImage: CGImage
        let pointSize: CGSize
        let density: CGFloat

        var pixelBounds: CGRect { CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height) }

        /// Image-point rect → the whole source pixels covering it (top-left origin).
        func pixelRect(covering rect: CGRect) -> CGRect {
            let minX = floor(rect.minX * density + 0.001)
            let minY = floor(rect.minY * density + 0.001)
            let maxX = ceil(rect.maxX * density - 0.001)
            let maxY = ceil(rect.maxY * density - 0.001)
            return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
                .intersection(pixelBounds)
        }

        func pointRect(forPixels rect: CGRect) -> CGRect {
            CGRect(x: rect.minX / density, y: rect.minY / density,
                   width: rect.width / density, height: rect.height / density)
        }
    }

    private enum RedactionKind: Hashable { case blur, pixelate }

    private struct RedactionKey: Hashable {
        let kind: RedactionKind
        let pixelRect: CGRect
        let strength: CGFloat

        func hash(into hasher: inout Hasher) {
            hasher.combine(kind)
            hasher.combine(pixelRect.minX); hasher.combine(pixelRect.minY)
            hasher.combine(pixelRect.width); hasher.combine(pixelRect.height)
            hasher.combine(strength)
        }
    }

    private struct RedactionTile {
        let image: CGImage
        /// Opaque average color painted under the tile.
        let fill: CGColor
    }

    private struct PresentationKey: Equatable {
        let image: ObjectIdentifier
        let crop: CGRect?
        let options: ScreenshotBackgroundOptions
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private var redactionCache: [RedactionKey: RedactionTile] = [:]
    private var usedRedactionKeys: Set<RedactionKey> = []
    // Holding the image keeps its ObjectIdentifier from being reused.
    private var presentationCache: (key: PresentationKey, image: NSImage, cgImage: CGImage)?

    // MARK: – Source

    static func source(for image: NSImage?) -> Source? {
        guard let image, let cg = image.bestCGImage else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let density = max(CGFloat(cg.width) / size.width, CGFloat(cg.height) / size.height)
        return Source(cgImage: cg, pointSize: size, density: max(density, 0.25))
    }

    /// Snaps an image-point rect to the screenshot's pixel grid, so a crop
    /// exports whole pixels without resampling.
    static func pixelAligned(_ rect: CGRect, density: CGFloat) -> CGRect {
        guard density > 0 else { return rect }
        let minX = (rect.minX * density).rounded() / density
        let minY = (rect.minY * density).rounded() / density
        let maxX = (rect.maxX * density).rounded() / density
        let maxY = (rect.maxY * density).rounded() / density
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: – Drawing

    /// Draws the whole document (no editing chrome). `ctx` must have a
    /// top-left origin in canvas points; `scale` is its pixels per point.
    func draw(_ scene: Scene, in ctx: CGContext, scale: CGFloat) {
        let layout = scene.layout
        let source = Self.source(for: scene.image)
        usedRedactionKeys.removeAll(keepingCapacity: true)

        // 1. The screenshot, inside its backdrop when one is on
        if let source, let image = scene.image {
            if scene.backgroundOptions.isEnabled,
               let backdrop = presentationImage(source: source, image: image, layout: layout, options: scene.backgroundOptions) {
                Self.drawUpright(backdrop, in: CGRect(origin: .zero, size: layout.canvasSize), context: ctx)
            } else if let visible = source.cgImage.cropping(to: source.pixelRect(covering: layout.visibleImageRect)) {
                Self.drawUpright(visible, in: layout.screenshotRectInCanvas, context: ctx)
            }
        }

        let effects = scene.objects.filter(Self.isScreenshotEffect)
        if let source, !effects.isEmpty {
            // 2. Redactions and spotlights change the screenshot itself, so
            // they stay inside it (and its rounded corners).
            ctx.saveGState()
            ctx.addPath(Self.screenshotClipPath(layout: layout, options: scene.backgroundOptions))
            ctx.clip()
            ctx.translateBy(x: layout.imageOrigin.x, y: layout.imageOrigin.y)
            for object in effects {
                if let blur = object as? BlurAnnotation {
                    drawRedaction(.blur, rect: blur.rect, strength: blur.strength, source: source, in: ctx)
                } else if let pixelate = object as? PixelateAnnotation {
                    drawRedaction(.pixelate, rect: pixelate.rect, strength: pixelate.strength, source: source, in: ctx)
                }
            }
            drawSpotlights(effects.compactMap { $0 as? SpotlightAnnotation }, layout: layout, in: ctx)
            ctx.restoreGState()
        }
        pruneRedactionCache()

        // 3. Annotations
        ctx.saveGState()
        ctx.translateBy(x: layout.imageOrigin.x, y: layout.imageOrigin.y)
        for object in scene.objects where !Self.isScreenshotEffect(object) {
            object.draw(in: ctx, scale: scale)
        }
        ctx.restoreGState()
    }

    static func isScreenshotEffect(_ object: any AnnotationObject) -> Bool {
        object is BlurAnnotation || object is PixelateAnnotation || object is SpotlightAnnotation
    }

    /// The visible screenshot's outline in canvas coordinates — rounded like
    /// the backdrop draws it.
    static func screenshotClipPath(layout: AnnotationCanvasLayout, options: ScreenshotBackgroundOptions) -> CGPath {
        let rect = layout.screenshotRectInCanvas
        guard options.isEnabled else { return CGPath(rect: rect, transform: nil) }
        let radius = min(min(max(options.cornerRadius, 0), 36), min(rect.width, rect.height) / 2)
        guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Draws a CGImage right side up in a top-left-origin context.
    static func drawUpright(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    // MARK: – Export

    /// Renders the document offscreen at the screenshot's own pixel density
    /// — never the display's — so a Retina capture exports every pixel and a
    /// 1x capture isn't upscaled, whichever monitor the editor is on.
    func export(_ scene: Scene) -> NSImage? {
        let source = Self.source(for: scene.image)
        let density = source?.density ?? 1
        let size = source == nil ? scene.fallbackSize : scene.layout.canvasSize
        guard size.width > 0, size.height > 0 else { return nil }
        let pixelWidth = max(1, Int((size.width * density).rounded()))
        let pixelHeight = max(1, Int((size.height * density).rounded()))

        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let preferredSpace = source?.cgImage.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        func makeContext(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = makeContext(preferredSpace) ?? makeContext(sRGB) else { return nil }

        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: CGFloat(pixelWidth) / size.width, y: -CGFloat(pixelHeight) / size.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(scene, in: ctx, scale: density)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: – Backdrop

    private func presentationImage(source: Source, image: NSImage, layout: AnnotationCanvasLayout, options: ScreenshotBackgroundOptions) -> CGImage? {
        let key = PresentationKey(image: ObjectIdentifier(image), crop: layout.crop, options: options)
        if let cached = presentationCache, cached.key == key, cached.image === image {
            return cached.cgImage
        }

        var visible = image
        if let crop = layout.crop,
           let cropped = source.cgImage.cropping(to: source.pixelRect(covering: crop)) {
            visible = CaptureEngine.nsImage(from: cropped, logicalSize: crop.size)
        }
        guard let composed = ScreenshotBackgroundComposer.composeIfNeeded(visible, options: options).bestCGImage else {
            return nil
        }
        presentationCache = (key, image, composed)
        return composed
    }

    // MARK: – Redaction

    /// Blur/pixelate the screenshot's own pixels under `rect`. The filter
    /// runs on an edge-clamped copy (no transparent fringe to see the
    /// original through), the strength is scaled to pixel density, and an
    /// opaque fill goes underneath so nothing can show through regardless.
    private func drawRedaction(_ kind: RedactionKind, rect: CGRect, strength: CGFloat, source: Source, in ctx: CGContext) {
        let imageBounds = CGRect(origin: .zero, size: source.pointSize)
        let clipped = rect.standardized.intersection(imageBounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return }
        let pixelRect = source.pixelRect(covering: clipped)
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return }
        let tileRect = source.pointRect(forPixels: pixelRect)

        let key = RedactionKey(kind: kind, pixelRect: pixelRect, strength: strength)
        usedRedactionKeys.insert(key)
        let tile: RedactionTile
        if let cached = redactionCache[key] {
            tile = cached
        } else if let rendered = renderTile(kind, pixelRect: pixelRect, strength: strength, source: source) {
            redactionCache[key] = rendered
            tile = rendered
        } else {
            // Never fall back to showing the original
            ctx.setFillColor(NSColor.gray.cgColor)
            ctx.fill(tileRect)
            return
        }

        ctx.setFillColor(tile.fill)
        ctx.fill(tileRect)
        Self.drawUpright(tile.image, in: tileRect, context: ctx)
    }

    private func renderTile(_ kind: RedactionKind, pixelRect: CGRect, strength: CGFloat, source: Source) -> RedactionTile? {
        guard let cropped = source.cgImage.cropping(to: pixelRect) else { return nil }
        let input = CIImage(cgImage: cropped)
        let extent = input.extent
        let amount = max(strength, 1) * source.density
        let clamped = input.clampedToExtent()

        let output: CIImage
        switch kind {
        case .blur:
            output = clamped
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: amount])
                .cropped(to: extent)
        case .pixelate:
            // CIPixellate samples one pixel per block; box-averaging first
            // makes each block the average of what it covers — a proper
            // mosaic. Blocks start at the region's top-left corner (Core
            // Image's origin is bottom-left).
            let block = max(amount, 2)
            output = clamped
                .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: max(block / 2, 1)])
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: block,
                    kCIInputCenterKey: CIVector(x: extent.minX, y: extent.maxY)
                ])
                .cropped(to: extent)
        }

        let colorSpace = cropped.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let image = Self.ciContext.createCGImage(output, from: extent, format: .RGBA8, colorSpace: colorSpace) else {
            return nil
        }
        return RedactionTile(image: image, fill: averageColor(of: clamped.cropped(to: extent), colorSpace: colorSpace))
    }

    private func averageColor(of image: CIImage, colorSpace: CGColorSpace) -> CGColor {
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        Self.ciContext.render(average, toBitmap: &pixel, rowBytes: 4,
                              bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                              format: .RGBA8, colorSpace: colorSpace)
        let alpha = CGFloat(pixel[3]) / 255
        guard alpha > 0 else { return NSColor.gray.cgColor }
        // Un-premultiply, then force opaque: the fill must hide everything.
        let components = [CGFloat(pixel[0]) / 255 / alpha, CGFloat(pixel[1]) / 255 / alpha, CGFloat(pixel[2]) / 255 / alpha, 1]
            .map { min($0, 1) }
        return CGColor(colorSpace: colorSpace, components: components) ?? NSColor.gray.cgColor
    }

    private func pruneRedactionCache() {
        guard redactionCache.count > usedRedactionKeys.count else { return }
        redactionCache = redactionCache.filter { usedRedactionKeys.contains($0.key) }
    }

    // MARK: – Spotlight

    private func drawSpotlights(_ spotlights: [SpotlightAnnotation], layout: AnnotationCanvasLayout, in ctx: CGContext) {
        guard !spotlights.isEmpty else { return }
        let dimRect = layout.visibleImageRect.insetBy(dx: -1, dy: -1)
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(SpotlightAnnotation.dimAlpha).cgColor)
        ctx.fill(dimRect)
        ctx.setBlendMode(.clear)
        for spotlight in spotlights {
            ctx.addPath(spotlight.holePath)
            ctx.fillPath()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
