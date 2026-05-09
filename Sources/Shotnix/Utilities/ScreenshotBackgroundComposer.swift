import AppKit

struct ScreenshotBackgroundOptions: Equatable {
    enum Style: String {
        case solid
        case gradient
    }

    var isEnabled: Bool
    var style: Style
    var presetName: String
    var colorHex: String
    var gradientStartHex: String
    var gradientEndHex: String
    var accentHexes: [String]
    var padding: CGFloat
    var cornerRadius: CGFloat
    var shadow: CGFloat

    static let editorDefault = ScreenshotBackgroundOptions(
        isEnabled: false,
        style: .gradient,
        presetName: "Neo Pop",
        colorHex: "#f4eadb",
        gradientStartHex: "#6a2cff",
        gradientEndHex: "#ffd36a",
        accentHexes: ["#ff7ac8", "#6af7ff", "#fff6b0"],
        padding: 72,
        cornerRadius: 18,
        shadow: 0.32
    )
}

enum ScreenshotBackgroundComposer {

    static func composeIfNeeded(_ image: NSImage, options: ScreenshotBackgroundOptions) -> NSImage {
        guard options.isEnabled else { return image }
        guard let source = image.bestCGImage else { return image }

        let sourcePointSize = image.size
        guard sourcePointSize.width > 0, sourcePointSize.height > 0 else { return image }

        let scale = max(
            CGFloat(source.width) / sourcePointSize.width,
            CGFloat(source.height) / sourcePointSize.height,
            1
        )
        let padding = clamped(options.padding, min: 0, max: 240)
        let outputPointSize = NSSize(
            width: sourcePointSize.width + padding * 2,
            height: sourcePointSize.height + padding * 2
        )
        let pixelWidth = max(1, Int(ceil(outputPointSize.width * scale)))
        let pixelHeight = max(1, Int(ceil(outputPointSize.height * scale)))

        let colorSpace = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)

        let outputRect = CGRect(origin: .zero, size: outputPointSize)
        drawBackground(in: context, rect: outputRect, options: options)

        let imageRect = pixelAligned(CGRect(origin: CGPoint(x: padding, y: padding), size: sourcePointSize), scale: scale)
        let radius = cornerRadius(for: imageRect, options: options)
        drawShadow(in: context, container: outputRect, rect: imageRect, radius: radius, intensity: clamped(options.shadow, min: 0, max: 1))

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.addPath(roundedPath(for: imageRect, radius: radius))
        context.clip()
        context.draw(source, in: imageRect)
        context.restoreGState()
        drawEdgeStroke(in: context, rect: imageRect, radius: radius, scale: scale)

        guard let composed = context.makeImage() else { return image }
        let rep = NSBitmapImageRep(cgImage: composed)
        rep.size = outputPointSize
        let output = NSImage(size: outputPointSize)
        output.addRepresentation(rep)
        return output
    }

    private static func drawBackground(in context: CGContext, rect: CGRect, options: ScreenshotBackgroundOptions) {
        if options.style == .gradient {
            let start = color(from: options.gradientStartHex)
            let end = color(from: options.gradientEndHex)
            let colors = [start.cgColor, end.cgColor] as CFArray
            let colorSpace = start.cgColor.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: rect.minX, y: rect.minY),
                    end: CGPoint(x: rect.maxX, y: rect.maxY),
                    options: []
                )
                drawProceduralBlooms(in: context, rect: rect, options: options, start: start, end: end)
                drawVignette(in: context, rect: rect)
                return
            }
        }

        context.setFillColor(color(from: options.colorHex).cgColor)
        context.fill(rect)
        drawVignette(in: context, rect: rect)
    }

    private static func drawProceduralBlooms(in context: CGContext, rect: CGRect, options: ScreenshotBackgroundOptions, start: NSColor, end: NSColor) {
        let fallback = [end, start]
        let accents = options.accentHexes.isEmpty ? fallback : options.accentHexes.map(color(from:))
        let centers = [
            CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.78),
            CGPoint(x: rect.minX + rect.width * 0.84, y: rect.minY + rect.height * 0.22),
            CGPoint(x: rect.minX + rect.width * 0.58, y: rect.minY + rect.height * 0.92),
            CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.18)
        ]

        for (index, color) in accents.prefix(4).enumerated() {
            let radius = max(rect.width, rect.height) * (index == 0 ? 0.68 : 0.48)
            drawGradientGlow(in: context, rect: rect, color: color, center: centers[index], radius: radius, alpha: index == 0 ? 0.34 : 0.24)
        }
    }

    private static func drawGradientGlow(in context: CGContext, rect: CGRect, color: NSColor, center: CGPoint, radius: CGFloat, alpha: CGFloat) {
        let colors = [
            color.withAlphaComponent(alpha).cgColor,
            color.withAlphaComponent(0).cgColor
        ] as CFArray
        let colorSpace = color.cgColor.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return }
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: .drawsAfterEndLocation
        )
    }

    private static func drawVignette(in context: CGContext, rect: CGRect) {
        let colors = [
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(0.12).cgColor
        ] as CFArray
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.52, 1]) else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: min(rect.width, rect.height) * 0.14,
            endCenter: center,
            endRadius: max(rect.width, rect.height) * 0.72,
            options: .drawsAfterEndLocation
        )
    }

    private static func drawShadow(in context: CGContext, container: CGRect, rect: CGRect, radius: CGFloat, intensity: CGFloat) {
        guard intensity > 0 else { return }

        let path = roundedPath(for: rect, radius: radius)
        let outerRect = container.insetBy(dx: -120, dy: -120)
        let shadowClip = CGMutablePath()
        shadowClip.addRect(outerRect)
        shadowClip.addPath(path)

        context.saveGState()
        context.addPath(shadowClip)
        context.clip(using: .evenOdd)
        context.setShadow(
            offset: CGSize(width: 0, height: -18 * intensity),
            blur: 42 * intensity,
            color: NSColor.black.withAlphaComponent(0.45 * intensity).cgColor
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    private static func drawEdgeStroke(in context: CGContext, rect: CGRect, radius: CGFloat, scale: CGFloat) {
        let lineWidth = CGFloat(1) / max(scale, 1)
        let strokeRect = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let strokeRadius = max(0, radius - lineWidth / 2)

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setLineWidth(lineWidth)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        context.addPath(roundedPath(for: strokeRect, radius: strokeRadius))
        context.strokePath()
        context.restoreGState()
    }

    private static func color(from hex: String) -> NSColor {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
            return NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.14, alpha: 1)
        }
        let red = CGFloat((value >> 16) & 0xff) / 255
        let green = CGFloat((value >> 8) & 0xff) / 255
        let blue = CGFloat(value & 0xff) / 255
        return NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func clamped(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, min), max)
    }

    private static func cornerRadius(for rect: CGRect, options: ScreenshotBackgroundOptions) -> CGFloat {
        min(clamped(options.cornerRadius, min: 0, max: 36), min(rect.width, rect.height) / 2)
    }

    private static func roundedPath(for rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: (rect.origin.x * scale).rounded() / scale,
            y: (rect.origin.y * scale).rounded() / scale,
            width: (rect.width * scale).rounded() / scale,
            height: (rect.height * scale).rounded() / scale
        )
    }
}
